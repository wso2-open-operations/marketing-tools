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

isolated function insertEngagement(postgresql:Client db, string id, string action, string? activityUrn)
        returns sql:ExecutionResult|sql:Error {
    return db->execute(`
        INSERT INTO sharing_engagement (id, provider, provider_api, origin, target_resource_urn, actor_member_urn,
            employee_id, action, activity_urn, occurred_at)
        VALUES (CAST(${id} AS uuid), 'linkedin', 'COMMUNITY_MANAGEMENT', 'API_SYNC', 'urn:li:share:2501',
            'urn:li:person:v025', 'v025-employee', ${action}, ${activityUrn}, now())`);
}

isolated function insertOrgConnection(postgresql:Client db, string orgUrn, string? accessId, string? accessDay,
        string? revokedAt) returns sql:ExecutionResult|sql:Error {
    return db->execute(`
        INSERT INTO connection_org_connection (provider, org_urn, provider_api, scopes, connected_by, access_token_id,
            access_token_issued_on, access_expires_at, connected_at, revoked_at)
        VALUES ('linkedin', ${orgUrn}, 'COMMUNITY_MANAGEMENT', '{r_organization_social_feed,rw_organization_admin}',
            'v025-admin', CAST(${accessId} AS uuid), CAST(${accessDay} AS date), now() + interval '60 days', now(),
            CAST(${revokedAt} AS timestamptz))`);
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV025EngagementSync() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version IN ('V025__engagement_sync', 'S013__engagement_sync_settings')`);
    test:assertEquals(applied, 2);

    // Settings: off, every two hours, 450 calls a day.
    record {|string enabled; string schedule; string budget;|} settings = check admin->queryRow(`
        SELECT (SELECT value::text FROM config_app_setting WHERE key = 'engagement.sync_enabled') AS enabled,
               (SELECT value #>> '{}' FROM config_app_setting WHERE key = 'engagement.schedule') AS schedule,
               (SELECT value::text FROM config_app_setting WHERE key = 'engagement.daily_call_budget') AS budget`);
    test:assertEquals(settings, {enabled: "false", schedule: "0 */2 * * *", budget: "450"});

    // The widened action check: the sync's reactions and comments, nothing else.
    _ = check insertEngagement(jobs, "0192f0e0-0000-7000-8000-000000002501", "REACTION", ());
    _ = check insertEngagement(jobs, "0192f0e0-0000-7000-8000-000000002502", "COMMENT",
            "urn:li:comment:(urn:li:share:2501,1)");
    test:assertTrue(insertEngagement(jobs, "0192f0e0-0000-7000-8000-000000002503", "LIKE", ()) is sql:Error,
            "an unknown action is refused");
    test:assertTrue(insertEngagement(jobs, "0192f0e0-0000-7000-8000-000000002504", "REACTION", ()) is sql:Error,
            "one reaction per post per person (engagement_once_uk)");

    // Org connection: token pointers whole or absent; a revoked page keeps no token; one row per page.
    _ = check insertOrgConnection(jobs, "urn:li:organization:2501", "0192f0e0-0000-7000-8000-000000002511",
            "2026-11-25", ());
    test:assertTrue(insertOrgConnection(jobs, "urn:li:organization:2502", "0192f0e0-0000-7000-8000-000000002512", (),
            ()) is sql:Error, "half a token pointer");
    test:assertTrue(insertOrgConnection(jobs, "urn:li:organization:2503", "0192f0e0-0000-7000-8000-000000002513",
            "2026-11-25", "2026-11-25T00:00:00Z") is sql:Error, "revoked with a token");
    _ = check insertOrgConnection(jobs, "urn:li:organization:2504", (), (), "2026-11-25T00:00:00Z");
    test:assertTrue(insertOrgConnection(jobs, "urn:li:person:2505", (), (), ()) is sql:Error, "a page URN only");
    test:assertTrue(insertOrgConnection(jobs, "urn:li:organization:2501", (), (), ()) is sql:Error, "one row per page");

    // Cursor, usage and intent tables: their keys and checks.
    _ = check jobs->execute(`
        INSERT INTO sharing_sync_cursor (provider, provider_api, resource_urn, endpoint, cursor, last_run_at)
        VALUES ('linkedin', 'COMMUNITY_MANAGEMENT', 'urn:li:share:2501', 'REACTIONS', '12', now())`);
    sql:ExecutionResult|sql:Error badEndpoint = jobs->execute(`
        INSERT INTO sharing_sync_cursor (provider, provider_api, resource_urn, endpoint, cursor, last_run_at)
        VALUES ('linkedin', 'COMMUNITY_MANAGEMENT', 'urn:li:share:2501', 'LIKES', '0', now())`);
    test:assertTrue(badEndpoint is sql:Error, "unknown endpoint");
    int calls = check jobs->queryRow(`
        INSERT INTO sharing_api_usage (provider_api, day, calls) VALUES ('COMMUNITY_MANAGEMENT', CURRENT_DATE, 1)
        ON CONFLICT (provider_api, day) DO UPDATE SET calls = sharing_api_usage.calls + 1
        RETURNING calls`);
    test:assertEquals(calls, 1);
    int again = check jobs->queryRow(`
        INSERT INTO sharing_api_usage (provider_api, day, calls) VALUES ('COMMUNITY_MANAGEMENT', CURRENT_DATE, 1)
        ON CONFLICT (provider_api, day) DO UPDATE SET calls = sharing_api_usage.calls + 1
        RETURNING calls`);
    test:assertEquals(again, 2);
    _ = check jobs->execute(`
        INSERT INTO sharing_native_intent (employee_id, campaign_id, opened_at)
        VALUES ('v025-employee', '0192f0e0-0000-7000-8000-000000002521', now())`);
    sql:ExecutionResult|sql:Error secondIntent = jobs->execute(`
        INSERT INTO sharing_native_intent (employee_id, campaign_id, opened_at)
        VALUES ('v025-employee', '0192f0e0-0000-7000-8000-000000002521', now())`);
    test:assertTrue(secondIntent is sql:Error, "one intent per campaign per employee");

    // Erasure is unchanged and still clears the synced engagement's member URN.
    string result = check jobs->queryRow(`SELECT identity_erase_employee('v025-employee', 'system', 'leaver sweep')::text`);
    test:assertTrue(result.includes("\"engagements\": 2"), result);
    int intents = check admin->queryRow(`SELECT count(*)::int FROM sharing_native_intent WHERE employee_id = 'v025-employee'`);
    test:assertEquals(intents, 1, "the intent stays: pseudonymous, like the ledger");

    check jobs.close();
    check admin.close();
}
