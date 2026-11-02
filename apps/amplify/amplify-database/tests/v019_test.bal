// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// V019: a campaign's post link may be https, or the local stack's one http dev origin (http://localhost:19091).
// Any other plain http link is still refused by the check.

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

isolated function insertCampaignWithLink(postgresql:Client db, string urnId, string link) returns sql:ExecutionResult|sql:Error {
    return db->execute(`INSERT INTO campaign.campaign (provider, resource_urn, resource_type, owner_urn, resource_url, title,
            category_code, opens_at, closes_at, created_by)
        VALUES ('linkedin', ${"urn:li:share:v019-" + urnId}, 'SHARE', 'urn:li:organization:1', ${link}, 'T', 'PRODUCT',
                now(), now() + interval '1 day', 'po-1')`);
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV019PostLinkAllowsHttpsAndTheDevOriginOnly() returns error? {
    postgresql:Client api = check apiClient();
    postgresql:Client admin = check adminClient(itDbName);
    int applied = check admin->queryRow(`SELECT count(*)::int FROM public.schema_version
                                         WHERE version = 'V019__dev_post_link_http'`);
    test:assertEquals(applied, 1);
    check admin.close();
    _ = check insertCampaignWithLink(api, "https", "https://www.linkedin.com/feed/update/urn:li:share:1/");
    _ = check insertCampaignWithLink(api, "dev", "http://localhost:19091/feed/update/urn:li:share:1/");
    foreach string bad in ["http://www.linkedin.com/feed/update/urn:li:share:1", "http://localhost:19091.evil.example/p",
            "http://localhost:9091/p", "http://127.0.0.1:19091/p", "ftp://localhost:19091/p"] {
        sql:ExecutionResult|sql:Error r = insertCampaignWithLink(api, "bad" + bad.length().toString(), bad);
        test:assertTrue(r is sql:Error, bad);
        if r is sql:Error {
            test:assertTrue(r.message().includes("campaign_resource_url_check"), bad + ": " + r.message());
        }
    }
    check api.close();
}
