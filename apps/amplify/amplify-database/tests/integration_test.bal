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

// Integration tests against a real PostgreSQL 18 (group `integration`). Off unless `itEnabled = true`
// (for example `BAL_CONFIG_VAR_ITENABLED=true`), so `bal test` without a database still passes. They drop and recreate the database `itDbName`, run the
// runner fresh and again, then check partition upkeep as amplify_jobs. See docs/migrations/README.md.

import ballerina/crypto;
import ballerina/io;
import ballerina/sql;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

# Turns the integration tests on.
configurable boolean itEnabled = false;
# Throwaway database the tests own.
configurable string itDbName = "amplify_it";
# Admin database used to drop and create `itDbName`.
configurable string itAdminDb = "postgres";

# Login password the tests give `amplify_jobs`. Roles live on the server, not the database, so this only ever
# runs against a local throwaway server (see the guard in `testFreshRunThenIdempotentRerun`).
configurable string itJobsPassword = "it-jobs-password-0001";
# Login password the tests give `amplify_api`.
configurable string itApiPassword = "it-api-password-00001";

# Says so in the test output when the integration tests are off, so a green run isn't mistaken for a real one.
#
# + testName - Test that would have run
# + return - True when the test must return without running
function itSkipped(string testName) returns boolean {
    if itEnabled {
        return false;
    }
    io:println(string `SKIPPED (itEnabled=false): ${testName}`);
    return true;
}

function adminClient(string database) returns postgresql:Client|error =>
    new (host = dbHost, username = dbUser, password = dbPassword, database = database, port = dbPort,
        options = {ssl: {mode: dbSslMode}}, connectionPool = {maxOpenConnections: 2, minIdleConnections: 0});

function jobsClient() returns postgresql:Client|error =>
    new (host = dbHost, username = "amplify_jobs", password = itJobsPassword, database = itDbName, port = dbPort,
        options = {ssl: {mode: dbSslMode}}, connectionPool = {maxOpenConnections: 2, minIdleConnections: 0});

function utcDay(int offsetDays) returns string =>
    time:utcToString(time:utcAddSeconds(time:utcNow(), <decimal>offsetDays * 86400)).substring(0, 10);

function dayName(int offsetDays) returns string => "provider_token_p" + re `-`.replaceAll(utcDay(offsetDays), "");

function partitionExists(postgresql:Client db, string schema, string name) returns boolean|error {
    string qualified = schema + "." + name;
    boolean exists = check db->queryRow(`SELECT to_regclass(${qualified}) IS NOT NULL`);
    return exists;
}

@test:Config {groups: ["integration"]}
function testFreshRunThenIdempotentRerun() returns error? {
    if itSkipped("testFreshRunThenIdempotentRerun") {
        return;
    }
    // The tests reset cluster-wide role passwords (amplify_api, amplify_jobs, amplify_readonly), so they must
    // never touch a shared or managed server.
    if !isLocalHost(dbHost) {
        return error(string `integration tests reset cluster-wide role passwords; refusing to run against ${dbHost}`);
    }
    postgresql:Client admin = check adminClient(itAdminDb);
    // Constant identifiers only; nothing user-supplied reaches this DDL.
    sql:ProcedureCallResult dropped = check admin->call(scriptQuery(string `DROP DATABASE IF EXISTS ${itDbName} WITH (FORCE)`));
    check dropped.close();
    sql:ProcedureCallResult created = check admin->call(scriptQuery(string `CREATE DATABASE ${itDbName}`));
    check created.close();
    check admin.close();

    postgresql:Client db = check adminClient(itDbName);
    RunSummary first = check migrate(db, "migrations", "seed");
    string[] migrations = check listMigrations("migrations");
    string[] seeds = check listScripts("seed", SEED_FILE);
    test:assertEquals(first.applied.length(), migrations.length() + seeds.length(), "fresh run applies everything");
    test:assertEquals(first.skipped, 0);

    RunSummary second = check migrate(db, "migrations", "seed");
    test:assertEquals(second.applied.length(), 0, "rerun applies nothing");
    test:assertEquals(second.skipped, migrations.length() + seeds.length());

    int recorded = check db->queryRow(`SELECT count(*)::int FROM public.schema_version`);
    test:assertEquals(recorded, migrations.length() + seeds.length());

    // Seeds landed.
    int rules = check db->queryRow(`SELECT count(*)::int FROM scoring.point_rule`);
    test:assertEquals(rules, 16, "S001's six rules, S005's five pilot versions and S006's five (the rest of the table)");
    // The rule in force now is the pilot value (S005), not S001's.
    int repostNow = check db->queryRow(`SELECT points FROM scoring.point_rule WHERE action = 'REPOST'
        AND effective_from <= now() ORDER BY effective_from DESC LIMIT 1`);
    test:assertEquals(repostNow, 2);
    string topN = check db->queryRow(`SELECT value::text FROM config.app_setting WHERE key = 'leaderboard.top_n'`);
    test:assertEquals(topN, "3");
    string retention = check db->queryRow(`SELECT value::text FROM config.app_setting WHERE key = 'audit.retention_months'`);
    test:assertEquals(retention, "60");

    // App roles own nothing; amplify_migrate owns every table.
    int notMigrateOwned = check db->queryRow(`
        SELECT count(*)::int FROM pg_tables
        WHERE schemaname IN ('identity', 'campaign', 'connection', 'sharing', 'external_sharing', 'scoring',
                             'recognition', 'announcement', 'messaging', 'audit', 'config')
          AND tableowner <> 'amplify_migrate'`);
    test:assertEquals(notMigrateOwned, 0);

    check setRolePasswords(db, {amplify_jobs: itJobsPassword, amplify_api: itApiPassword});
    check db.close();
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun]}
function testChangedAppliedScriptStopsTheRun() returns error? {
    if itSkipped("testChangedAppliedScriptStopsTheRun") {
        return;
    }
    postgresql:Client db = check adminClient(itDbName);
    _ = check db->execute(`UPDATE public.schema_version SET checksum = 'tampered' WHERE version = 'V002__identity_campaign'`);
    RunSummary|error rerun = migrate(db, "migrations", "seed");
    test:assertTrue(rerun is error, "a changed applied script must stop the run");
    if rerun is error {
        test:assertTrue(rerun.message().includes("forward-only"));
    }
    // Put the real checksum back for the tests that follow.
    string content = check io:fileReadString("migrations/V002__identity_campaign.sql");
    string real = crypto:hashSha256(content.toBytes()).toBase16();
    _ = check db->execute(`UPDATE public.schema_version SET checksum = ${real} WHERE version = 'V002__identity_campaign'`);
    RunSummary again = check migrate(db, "migrations", "seed");
    test:assertEquals(again.applied.length(), 0);
    check db.close();
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun]}
function testPartitionsCreatedAhead() returns error? {
    if itSkipped("testPartitionsCreatedAhead") {
        return;
    }
    postgresql:Client jobs = check jobsClient();
    foreach int day in 0 ... 7 {
        test:assertTrue(check partitionExists(jobs, "connection", dayName(day)), string `token partition today+${day}`);
    }
    string month = re `-`.replaceAll(utcDay(0).substring(0, 7), "");
    test:assertTrue(check partitionExists(jobs, "audit", "audit_log_p" + month));
    // Idempotent: a second call creates nothing new.
    int created = check jobs->queryRow(`SELECT connection.create_token_partitions(7)`);
    test:assertEquals(created, 0);
    // The daily call works as amplify_jobs and reports counts.
    string result = check jobs->queryRow(`SELECT messaging.run_partition_maintenance()::text`);
    json counts = check result.fromJsonString();
    test:assertEquals(check counts.token_partitions_created, 0);
    check jobs.close();
}

@test:Config {groups: ["integration"], dependsOn: [testPartitionsCreatedAhead]}
function testTokenDayDropRuleAndAudit() returns error? {
    if itSkipped("testTokenDayDropRuleAndAudit") {
        return;
    }
    postgresql:Client jobs = check jobsClient();
    // The fixture rows are seeded as the admin: since V017 amplify_jobs no longer inserts tokens.
    postgresql:Client admin = check adminClient(itDbName);
    // Three past days: expired beyond grace, still valid (long-lived token), and empty.
    foreach int offset in [-70, -10, -20] {
        _ = check jobs->queryRow(`SELECT connection.create_token_partitions(0, CAST(${utcDay(offset)} AS date))`, int);
    }
    string expiredDay = utcDay(-70);
    string validDay = utcDay(-10);
    _ = check admin->execute(`
        INSERT INTO connection.provider_token (issued_on, owner_type, owner_id, provider, token_kind, ciphertext, nonce,
                                               key_id, expires_at)
        VALUES (CAST(${expiredDay} AS date), 'MEMBER', 'emp-old', 'linkedin', 'ACCESS', '\x00'::bytea,
                '\x000000000000000000000000'::bytea, 'k1', now() - interval '2 days'),
               (CAST(${validDay} AS date), 'MEMBER', 'emp-new', 'linkedin', 'REFRESH', '\x00'::bytea,
                '\x000000000000000000000000'::bytea, 'k1', now() + interval '300 days')`);
    // Grace boundary: a token expired 2 days ago is past a 1-day grace, so its day goes.
    int dropped = check jobs->queryRow(`SELECT connection.drop_expired_token_partitions(1)`);
    test:assertEquals(dropped, 2, "expired day and empty day dropped");
    test:assertFalse(check partitionExists(jobs, "connection", dayName(-70)));
    test:assertFalse(check partitionExists(jobs, "connection", dayName(-20)));
    test:assertTrue(check partitionExists(jobs, "connection", dayName(-10)), "a day holding a live token survives");
    test:assertTrue(check partitionExists(jobs, "connection", dayName(0)), "today is never dropped");
    int audited = check jobs->queryRow(`
        SELECT count(*)::int FROM audit.audit_log
        WHERE action = 'PARTITION_DROPPED' AND entity_type = 'connection.provider_token'`);
    test:assertEquals(audited, 2, "every drop is audited");
    check admin.close();
    check jobs.close();
}

@test:Config {groups: ["integration"], dependsOn: [testPartitionsCreatedAhead]}
function testMissingTokenMeansNeedsReconnect() returns error? {
    if itSkipped("testMissingTokenMeansNeedsReconnect") {
        return;
    }
    postgresql:Client jobs = check jobsClient();
    postgresql:Client admin = check adminClient(itDbName);
    string today = utcDay(0);
    string tokenId = check admin->queryRow(`
        INSERT INTO connection.provider_token (issued_on, owner_type, owner_id, provider, token_kind, ciphertext, nonce,
                                               key_id, expires_at)
        VALUES (CAST(${today} AS date), 'MEMBER', 'emp-view', 'linkedin', 'ACCESS', '\x00'::bytea,
                '\x000000000000000000000000'::bytea, 'k1', now() + interval '60 days')
        RETURNING token_id::text`);
    _ = check jobs->execute(`
        INSERT INTO connection.member_connection (employee_id, provider, member_urn, provider_api, scopes,
            current_token_id, current_token_issued_on, access_expires_at, connected_at)
        VALUES ('emp-view', 'linkedin', 'urn:li:person:view1', 'SHARE_ON_LINKEDIN', ARRAY['w_member_social'],
                CAST(${tokenId} AS uuid), CAST(${today} AS date), now() + interval '60 days', now())`);
    string status = check jobs->queryRow(`SELECT status FROM connection.member_connection_v WHERE employee_id = 'emp-view'`);
    test:assertEquals(status, "ACTIVE");
    _ = check jobs->execute(`DELETE FROM connection.provider_token WHERE token_id = CAST(${tokenId} AS uuid)`);
    status = check jobs->queryRow(`SELECT status FROM connection.member_connection_v WHERE employee_id = 'emp-view'`);
    test:assertEquals(status, "NEEDS_RECONNECT", "a missing token row means reconnect");
    // Expiring inside connection.reminder_days (7).
    _ = check jobs->execute(`UPDATE connection.member_connection SET current_token_id = NULL, current_token_issued_on = NULL,
                             access_expires_at = now() + interval '3 days' WHERE employee_id = 'emp-view'`);
    status = check jobs->queryRow(`SELECT status FROM connection.member_connection_v WHERE employee_id = 'emp-view'`);
    test:assertEquals(status, "NEEDS_RECONNECT", "no token pointer is reconnect even before expiry");
    check admin.close();
    check jobs.close();
}

@test:Config {groups: ["integration"], dependsOn: [testPartitionsCreatedAhead]}
function testAuditRetentionAndOutboxPurge() returns error? {
    if itSkipped("testAuditRetentionAndOutboxPurge") {
        return;
    }
    postgresql:Client jobs = check jobsClient();
    string oldMonth = time:utcToString(time:utcAddSeconds(time:utcNow(), -62d * 31d * 86400d)).substring(0, 10);
    string keptMonth = time:utcToString(time:utcAddSeconds(time:utcNow(), -58d * 31d * 86400d)).substring(0, 10);
    _ = check jobs->queryRow(`SELECT audit.create_audit_partitions(0, CAST(${oldMonth} AS date))`, int);
    _ = check jobs->queryRow(`SELECT audit.create_audit_partitions(0, CAST(${keptMonth} AS date))`, int);
    int|error tooShort = jobs->queryRow(`SELECT audit.drop_old_audit_partitions(12)`);
    test:assertTrue(tooShort is error, "retention below 60 months is refused (B17)");
    int dropped = check jobs->queryRow(`SELECT audit.drop_old_audit_partitions(60)`);
    test:assertEquals(dropped, 1);
    string oldName = "audit_log_p" + re `-`.replaceAll(oldMonth.substring(0, 7), "");
    string keptName = "audit_log_p" + re `-`.replaceAll(keptMonth.substring(0, 7), "");
    test:assertFalse(check partitionExists(jobs, "audit", oldName));
    test:assertTrue(check partitionExists(jobs, "audit", keptName));

    _ = check jobs->execute(`
        INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload, idempotency_key, status,
                                      processed_at)
        VALUES ('t', '1', 'Test', '{}', 'it:old-done', 'DONE', now() - interval '31 days'),
               ('t', '2', 'Test', '{}', 'it:new-done', 'DONE', now() - interval '1 day'),
               ('t', '3', 'Test', '{}', 'it:old-failed', 'FAILED', NULL)`);
    int purged = check jobs->queryRow(`SELECT messaging.purge_done_outbox(30)::int`);
    test:assertEquals(purged, 1, "only DONE rows older than 30 days go");
    int left = check jobs->queryRow(`SELECT count(*)::int FROM messaging.outbox WHERE idempotency_key LIKE 'it:%'`);
    test:assertEquals(left, 2);
    check jobs.close();
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun]}
function testAppRolesCannotRunDdlOrOtherUpkeep() returns error? {
    if itSkipped("testAppRolesCannotRunDdlOrOtherUpkeep") {
        return;
    }
    postgresql:Client jobs = check jobsClient();
    sql:ExecutionResult|error ddl = jobs->execute(`DROP TABLE connection.oauth_state`);
    test:assertTrue(ddl is error, "app roles can't drop tables");
    sql:ExecutionResult|error rewrite = jobs->execute(`UPDATE scoring.points_ledger SET points = 0`);
    test:assertTrue(rewrite is error, "ledger facts are immutable to app roles");
    check jobs.close();
}
