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


// V029 housekeeping: each prune deletes only what its rule says, never more than the batch, guards its inputs, and is
// private to the login (not executable by PUBLIC). S017 seeds the settings.

import ballerina/test;
import ballerinax/postgresql;

function v029Count(postgresql:Client db, string employeeOrUrn) returns int|error {
    return db->queryRow(`SELECT (SELECT count(*) FROM sharing_native_intent WHERE employee_id = ${employeeOrUrn})::int
                              + (SELECT count(*) FROM sharing_sync_cursor WHERE resource_urn = ${employeeOrUrn})::int`);
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV029HousekeepingPrunes() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version IN ('V029__housekeeping', 'S017__housekeeping_settings')`);
    test:assertEquals(applied, 2);
    record {|string intents; string usage; string cursors; string batch;|} settings = check admin->queryRow(`
        SELECT (SELECT value::text FROM config_app_setting WHERE key = 'housekeeping.native_intent_days') AS intents,
               (SELECT value::text FROM config_app_setting WHERE key = 'housekeeping.api_usage_days') AS usage,
               (SELECT value::text FROM config_app_setting WHERE key = 'housekeeping.sync_cursor_days') AS cursors,
               (SELECT value::text FROM config_app_setting WHERE key = 'housekeeping.batch_rows') AS batch`);
    test:assertEquals(settings, {intents: "7", usage: "90", cursors: "180", batch: "5000"});

    // Native intents: detected 8 days ago (pruned), opened 8 days ago and never seen (pruned, NOT_FOUND long since),
    // opened 8 days ago but detected yesterday (kept), opened an hour ago (kept, still LOOKING).
    _ = check jobs->execute(`
        INSERT INTO sharing_native_intent (employee_id, campaign_id, opened_at, detected_at) VALUES
            ('v029-old-detected', '0192f0e0-0000-7000-8000-000000002901', now() - interval '9 days', now() - interval '8 days'),
            ('v029-old-missed',   '0192f0e0-0000-7000-8000-000000002902', now() - interval '8 days', NULL),
            ('v029-old-missed',   '0192f0e0-0000-7000-8000-000000002903', now() - interval '8 days', NULL),
            ('v029-recent-found', '0192f0e0-0000-7000-8000-000000002904', now() - interval '8 days', now() - interval '1 day'),
            ('v029-looking',      '0192f0e0-0000-7000-8000-000000002905', now() - interval '1 hour', NULL)`);
    int first = check jobs->queryRow(`SELECT sharing_prune_native_intent(7, 2)`);
    test:assertEquals(first, 2, "never more than the batch");
    int second = check jobs->queryRow(`SELECT sharing_prune_native_intent(7, 2)`);
    test:assertTrue(second >= 1);
    test:assertEquals(check v029Count(admin, "v029-old-detected") + check v029Count(admin, "v029-old-missed"), 0);
    test:assertEquals(check v029Count(admin, "v029-recent-found"), 1, "detected recently: kept");
    test:assertEquals(check v029Count(admin, "v029-looking"), 1, "still looking: kept");

    // API usage: a day past the age goes, today stays.
    _ = check jobs->execute(`
        INSERT INTO sharing_api_usage (provider_api, day, calls)
        VALUES ('COMMUNITY_MANAGEMENT', (now() AT TIME ZONE 'UTC')::date - 91, 7)
        ON CONFLICT DO NOTHING`);
    int usage = check jobs->queryRow(`SELECT sharing_prune_api_usage(90, 5000)`);
    test:assertTrue(usage >= 1);
    int oldDays = check admin->queryRow(`SELECT count(*)::int FROM sharing_api_usage
                                         WHERE day < (now() AT TIME ZONE 'UTC')::date - 90`);
    test:assertEquals(oldDays, 0);
    _ = check jobs->execute(`
        INSERT INTO sharing_api_usage (provider_api, day, calls)
        VALUES ('COMMUNITY_MANAGEMENT', (now() AT TIME ZONE 'UTC')::date, 1)
        ON CONFLICT (provider_api, day) DO NOTHING`);
    _ = check jobs->queryRow(`SELECT sharing_prune_api_usage(90, 5000)`, int);
    int today = check admin->queryRow(`SELECT count(*)::int FROM sharing_api_usage
                                       WHERE day = (now() AT TIME ZONE 'UTC')::date`);
    test:assertEquals(today, 1, "today's counter is the budget: kept");

    // Cursors: a post not moved for 181 days goes; a recent post and the page's notification cursor stay.
    _ = check jobs->execute(`
        INSERT INTO sharing_sync_cursor (provider, provider_api, resource_urn, endpoint, cursor, last_run_at) VALUES
            ('linkedin', 'COMMUNITY_MANAGEMENT', 'urn:li:share:2901', 'REACTIONS', '40', now() - interval '181 days'),
            ('linkedin', 'COMMUNITY_MANAGEMENT', 'urn:li:share:2901', 'COMMENTS', '3', now() - interval '181 days'),
            ('linkedin', 'COMMUNITY_MANAGEMENT', 'urn:li:share:2902', 'REACTIONS', '5', now() - interval '2 days'),
            ('linkedin', 'COMMUNITY_MANAGEMENT', 'urn:li:organization:2901', 'SHARE_NOTIFICATIONS', '1', now() - interval '400 days')`);
    int cursors = check jobs->queryRow(`SELECT sharing_prune_sync_cursor(180, 5000)`);
    test:assertEquals(cursors, 2);
    test:assertEquals(check v029Count(admin, "urn:li:share:2901"), 0);
    test:assertEquals(check v029Count(admin, "urn:li:share:2902"), 1, "a recent post: kept");
    test:assertEquals(check v029Count(admin, "urn:li:organization:2901"), 1, "the page cursor is never pruned");

    // Inputs are guarded (the same ranges amplify-api validates).
    assertViolates(failure(jobs, `SELECT sharing_prune_native_intent(1, 100)`), "p_days must be 2-365");
    assertViolates(failure(jobs, `SELECT sharing_prune_api_usage(29, 100)`), "p_days must be 30-730");
    assertViolates(failure(jobs, `SELECT sharing_prune_sync_cursor(180, 0)`), "p_limit must be 1-50000");
    assertViolates(failure(jobs, `SELECT sharing_prune_sync_cursor(180, 50001)`), "p_limit must be 1-50000");

    // SECURITY DEFINER, search_path pinned, lock_timeout bounded, not executable by PUBLIC.
    int pinned = check admin->queryRow(`
        SELECT count(*)::int FROM pg_proc
        WHERE proname IN ('sharing_prune_native_intent', 'sharing_prune_api_usage', 'sharing_prune_sync_cursor')
          AND prosecdef AND proconfig::text LIKE '%search_path%' AND proconfig::text LIKE '%lock_timeout=5s%'
          AND NOT has_function_privilege('public', oid, 'EXECUTE')`);
    test:assertEquals(pinned, 3);
    check jobs.close();
    check admin.close();
}
