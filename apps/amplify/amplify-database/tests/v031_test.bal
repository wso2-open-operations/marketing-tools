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

// V031 and S019: a removed LinkedIn connection releases its member URN; the phase 4 sharing settings are seeded.

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

isolated function insertMemberConnection(postgresql:Client db, string employeeId, string memberUrn, boolean removed)
        returns sql:ExecutionResult|sql:Error {
    return db->execute(`INSERT INTO connection_member_connection (employee_id, provider, member_urn, provider_api,
            access_expires_at, connected_at, removed_at)
        VALUES (${employeeId}, 'linkedin', ${memberUrn}, 'SHARE_ON_LINKEDIN', now() + interval '60 days', now(),
                CASE WHEN ${removed} THEN now() END)`);
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV031ReleasedMemberAndS019Settings() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
            WHERE version IN ('V031__release_removed_member_urn', 'S019__phase4_sharing_settings')`);
    test:assertEquals(applied, 2);

    _ = check insertMemberConnection(jobs, "v031-a", "urn:li:person:v031", true);
    _ = check insertMemberConnection(jobs, "v031-b", "urn:li:person:v031", false);
    sql:ExecutionResult|sql:Error third = insertMemberConnection(jobs, "v031-c", "urn:li:person:v031", false);
    test:assertTrue(third is sql:Error && third.message().includes("member_connection_member_uk"),
            "one live connection per member, under the old name");
    sql:ExecutionResult|sql:Error back = jobs->execute(`UPDATE connection_member_connection SET removed_at = NULL
            WHERE employee_id = 'v031-a'`);
    test:assertTrue(back is sql:Error, "the old holder can't come back while another holds the member");

    record {|string native; string day; string hour; string spread; string gap;|} s = check admin->queryRow(`
        SELECT (SELECT value::text FROM config_app_setting WHERE key = 'sharing.native_repost_default') AS native,
               (SELECT value::text FROM config_app_setting WHERE key = 'sharing.max_posts_per_day') AS day,
               (SELECT value::text FROM config_app_setting WHERE key = 'sharing.max_posts_per_hour') AS hour,
               (SELECT value::text FROM config_app_setting WHERE key = 'sharing.spread_minutes') AS spread,
               (SELECT value::text FROM config_app_setting WHERE key = 'sharing.publish_gap_minutes') AS gap`);
    test:assertEquals(s, {native: "false", day: "450", hour: "60", spread: "120", gap: "10"});
    check jobs.close();
    check admin.close();
}
