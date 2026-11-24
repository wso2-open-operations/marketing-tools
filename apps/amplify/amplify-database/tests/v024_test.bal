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

import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV024LinkedInMentionsRelink() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version = 'V024__linkedin_mentions_relink'`);
    test:assertEquals(applied, 1);

    // Two rows may share a member URN when all but one are removed; two live rows may not.
    _ = check jobs->execute(`INSERT INTO connection_member_connection (employee_id, provider, member_urn, provider_api,
                                 access_expires_at, connected_at, removed_at, member_name)
                             VALUES ('v024-a', 'linkedin', 'urn:li:person:v024', 'SHARE_ON_LINKEDIN',
                                     now() + interval '1 day', now(), now(), 'Jane V')`);
    _ = check jobs->execute(`INSERT INTO connection_member_connection (employee_id, provider, member_urn, provider_api,
                                 access_expires_at, connected_at)
                             VALUES ('v024-b', 'linkedin', 'urn:li:person:v024', 'SHARE_ON_LINKEDIN',
                                     now() + interval '1 day', now())`);
    var second = jobs->execute(`INSERT INTO connection_member_connection (employee_id, provider, member_urn, provider_api,
                                    access_expires_at, connected_at)
                                VALUES ('v024-c', 'linkedin', 'urn:li:person:v024', 'SHARE_ON_LINKEDIN',
                                        now() + interval '1 day', now())`);
    test:assertTrue(second is error && second.message().includes("member_connection_member_uk"),
            "a second live holder hits the same-named unique index");
    var blankName = jobs->execute(`UPDATE connection_member_connection SET member_name = '' WHERE employee_id = 'v024-a'`);
    test:assertTrue(blankName is error, "member_name is NULL or 1-255 characters");

    int newLimit = check admin->queryRow(`SELECT count(*)::int FROM pg_constraint
                                       WHERE conname = 'share_request_commentary_length_ck'`);
    test:assertEquals(newLimit, 1);
    int oldLimit = check admin->queryRow(`SELECT count(*)::int FROM pg_constraint
                                          WHERE conname = 'sharing_share_request_commentary_check'`);
    test:assertEquals(oldLimit, 0, "the 3000 check is gone; the API checks the shown length");
    _ = check jobs->execute(`DELETE FROM connection_member_connection WHERE employee_id LIKE 'v024-%'`);
    check admin.close();
    check jobs.close();
}
