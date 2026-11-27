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


import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

isolated function insertReachToken(postgresql:Client db, string id, string ownerType, string owner)
        returns sql:ExecutionResult|sql:Error {
    return db->execute(`INSERT INTO connection_provider_token (token_id, issued_on, owner_type, owner_id, provider,
            token_kind, ciphertext, nonce, key_id, expires_at)
        VALUES (CAST(${id} AS uuid), CURRENT_DATE, ${ownerType}, ${owner}, 'linkedin', 'ACCESS', decode('00ff', 'hex'),
            decode('000000000000000000000000', 'hex'), 'k1', now() + interval '1 day')`);
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV028MemberPostReach() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version IN ('V028__member_post_reach', 'S016__reach_settings')`);
    test:assertEquals(applied, 2);
    record {|string enabled; string schedule; string window; string minGroup;|} settings = check admin->queryRow(`
        SELECT (SELECT value::text FROM config_app_setting WHERE key = 'reach.enabled') AS enabled,
               (SELECT value #>> '{}' FROM config_app_setting WHERE key = 'reach.schedule') AS schedule,
               (SELECT value::text FROM config_app_setting WHERE key = 'reach.window_days') AS "window",
               (SELECT value::text FROM config_app_setting WHERE key = 'dashboards.min_group_size') AS "minGroup"`);
    test:assertEquals(settings, {enabled: "false", schedule: "30 3 * * *", window: "30", minGroup: "5"});

    // OAuth states carry their flow; an unknown one is refused.
    _ = check jobs->execute(`INSERT INTO connection_oauth_state (state, employee_id, provider, provider_api, nonce,
            expires_at, purpose)
        VALUES ('reach-v028-0123456789abcdef0123456789', 'v028-a', 'linkedin', 'COMMUNITY_MANAGEMENT', 'n',
            now() + interval '10 minutes', 'REACH')`);
    string purpose = check admin->queryRow(`SELECT purpose FROM connection_oauth_state
                                            WHERE state = 'reach-v028-0123456789abcdef0123456789'`);
    test:assertEquals(purpose, "REACH");
    sql:ExecutionResult|sql:Error badPurpose = jobs->execute(`INSERT INTO connection_oauth_state (state, employee_id,
            provider, provider_api, nonce, expires_at, purpose)
        VALUES ('bad-v028-0123456789abcdef0123456789', 'v028-a', 'linkedin', 'SHARE_ON_LINKEDIN', 'n',
            now() + interval '10 minutes', 'OTHER')`);
    test:assertTrue(badPurpose is sql:Error);

    // The new token owner type, the Reach connection and its pointer checks.
    _ = check insertReachToken(jobs, "0192f0e0-0000-7000-8000-000000002801", "MEMBER_ANALYTICS", "v028-a");
    test:assertTrue(insertReachToken(jobs, "0192f0e0-0000-7000-8000-000000002802", "SOMEONE", "v028-a") is sql:Error);
    _ = check jobs->execute(`INSERT INTO connection_member_analytics (employee_id, provider, provider_api, scopes,
            access_token_id, access_token_issued_on, access_expires_at, connected_at)
        VALUES ('v028-a', 'linkedin', 'COMMUNITY_MANAGEMENT', '{r_member_postAnalytics}',
            '0192f0e0-0000-7000-8000-000000002801', CURRENT_DATE, now() + interval '60 days', now())`);
    sql:ExecutionResult|sql:Error halfRefresh = jobs->execute(`INSERT INTO connection_member_analytics (employee_id,
            provider, provider_api, access_token_id, access_token_issued_on, refresh_token_id, access_expires_at,
            connected_at)
        VALUES ('v028-b', 'linkedin', 'COMMUNITY_MANAGEMENT', '0192f0e0-0000-7000-8000-000000002803', CURRENT_DATE,
            '0192f0e0-0000-7000-8000-000000002804', now() + interval '60 days', now())`);
    test:assertTrue(halfRefresh is sql:Error, "half a refresh pointer");

    // A reading per engagement per day; a second reading the same day is an upsert, never a second row.
    _ = check jobs->execute(`INSERT INTO sharing_engagement (id, provider, provider_api, origin, target_resource_urn,
            actor_member_urn, employee_id, action, activity_urn, occurred_at)
        VALUES ('0192f0e0-0000-7000-8000-000000002811', 'linkedin', 'SHARE_ON_LINKEDIN', 'IN_APP', 'urn:li:share:2801',
            'urn:li:person:v028', 'v028-a', 'REPOST', 'urn:li:share:2899', now())`);
    _ = check jobs->execute(`INSERT INTO sharing_engagement_metric (engagement_id, captured_on, provider_api, post_urn,
            impressions, members_reached, fetched_at)
        VALUES ('0192f0e0-0000-7000-8000-000000002811', CURRENT_DATE, 'COMMUNITY_MANAGEMENT', 'urn:li:share:2899', 10, 5,
            now())`);
    sql:ExecutionResult|sql:Error twice = jobs->execute(`INSERT INTO sharing_engagement_metric (engagement_id,
            captured_on, provider_api, post_urn, impressions, members_reached, fetched_at)
        VALUES ('0192f0e0-0000-7000-8000-000000002811', CURRENT_DATE, 'COMMUNITY_MANAGEMENT', 'urn:li:share:2899', 12, 6,
            now())`);
    test:assertTrue(twice is sql:Error, "one reading per post per day");
    sql:ExecutionResult|sql:Error negative = jobs->execute(`INSERT INTO sharing_engagement_metric (engagement_id,
            captured_on, provider_api, post_urn, impressions, members_reached, fetched_at)
        VALUES ('0192f0e0-0000-7000-8000-000000002811', CURRENT_DATE - 1, 'COMMUNITY_MANAGEMENT', 'urn:li:share:2899',
            -1, 0, now())`);
    test:assertTrue(negative is sql:Error);

    // Erasure deletes the Reach connection and its tokens; the readings stay.
    string result = check jobs->queryRow(`SELECT identity_erase_employee('v028-a', 'system', 'leaver sweep')::text`);
    test:assertTrue(result.includes("\"reachConnections\": 1"), result);
    test:assertTrue(result.includes("\"tokens\": 1"), result);
    test:assertTrue(result.includes("\"coinWallets\": 0"), "V026's erasure is kept: " + result);
    int tokens = check admin->queryRow(`SELECT count(*)::int FROM connection_provider_token WHERE owner_id = 'v028-a'`);
    test:assertEquals(tokens, 0);
    int readings = check admin->queryRow(`SELECT count(*)::int FROM sharing_engagement_metric
                                          WHERE engagement_id = '0192f0e0-0000-7000-8000-000000002811'`);
    test:assertEquals(readings, 1, "readings stay");
    string again = check jobs->queryRow(`SELECT identity_erase_employee('v028-a', 'system', 'again')::text`);
    test:assertTrue(again.includes("\"reachConnections\": 0"), again);

    check jobs.close();
    check admin.close();
}
