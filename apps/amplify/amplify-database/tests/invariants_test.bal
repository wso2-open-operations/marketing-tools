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

// Schema invariants against a real PostgreSQL 18 (group `integration`, deep review 2026-10-17): constraints
// reject bad rows, each role is denied what it must not do, SECURITY DEFINER functions are pinned and
// private, partition functions guard their inputs and compute bounds in UTC, and the V012 fixes
// (recognition writers serialized, upkeep lock waits bounded).

import ballerina/lang.runtime;
import ballerina/sql;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

const string IT_READONLY_PASSWORD = "it-readonly-password-1";

function roleClient(string user, string password, int poolSize = 2) returns postgresql:Client|error =>
    new (host = dbHost, username = user, password = password, database = itDbName, port = dbPort,
        options = {ssl: {mode: dbSslMode}}, connectionPool = {maxOpenConnections: poolSize, minIdleConnections: 0});

function apiClient() returns postgresql:Client|error => roleClient("amplify_api", itApiPassword);

function readonlyClient() returns postgresql:Client|error => roleClient("amplify_readonly", IT_READONLY_PASSWORD);

# Runs a statement that must fail, and returns the error text ("" when it unexpectedly succeeded).
function failure(postgresql:Client db, sql:ParameterizedQuery q) returns string {
    sql:ExecutionResult|error r = db->execute(q);
    return r is error ? r.message() : "";
}

function selectFailure(postgresql:Client db, sql:ParameterizedQuery q) returns string {
    int|error r = db->queryRow(q);
    return r is error ? r.message() : "";
}

# Plain SQL on a single-connection client, so `BEGIN` ... `COMMIT` span several calls (`call`: the driver
# doesn't append RETURNING).
function sqlText(postgresql:Client db, string text) returns error? {
    sql:ProcedureCallResult r = check db->call(scriptQuery(text));
    check r.close();
}

function assertDenied(string message, string what) {
    test:assertTrue(message.includes("permission denied"), string `${what} must be denied, got: '${message}'`);
}

function assertViolates(string message, string constraint) {
    test:assertTrue(message.includes(constraint), string `expected ${constraint}, got: '${message}'`);
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun]}
function testV012IsApplied() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client db = check adminClient(itDbName);
    int applied = check db->queryRow(`SELECT count(*)::int FROM public.schema_version
                                      WHERE version = 'V012__recognition_lock_maintenance_timeout'`);
    test:assertEquals(applied, 1);
    check setRolePasswords(db, {amplify_readonly: IT_READONLY_PASSWORD});
    check db.close();
}

// ---- constraints reject bad rows ---------------------------------------------------------------------

@test:Config {groups: ["integration"], dependsOn: [testV012IsApplied]}
function testConstraintsRejectBadRows() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client api = check apiClient();
    postgresql:Client jobs = check jobsClient();

    // C4: amplified only after approval (IS NOT DISTINCT FROM: a pending claim must not pass).
    assertViolates(failure(api, `INSERT INTO external_sharing.external_share (employee_id, action, evidence_url,
            evidence_url_submitted, evidence_host, provider, certified_at, amplified_at)
            VALUES ('e1', 'OWN_POST', 'https://x.example/p/1', 'https://x.example/p/1', 'x.example', 'linkedin',
                    now(), now())`), "external_share_amplified_ck");
    assertViolates(failure(api, `INSERT INTO external_sharing.external_share (employee_id, action, evidence_url,
            evidence_url_submitted, evidence_host, provider, certified_at, decision, decided_by, decided_at,
            decision_reason, amplified_at)
            VALUES ('e1', 'OWN_POST', 'https://x.example/p/2', 'https://x.example/p/2', 'x.example', 'linkedin',
                    now(), 'REJECTED', 'po-1', now(), 'no', now())`), "external_share_amplified_ck");
    assertViolates(failure(api, `INSERT INTO external_sharing.external_share (employee_id, action, evidence_url,
            evidence_url_submitted, evidence_host, provider, certified_at, decision, decided_by, decided_at)
            VALUES ('e1', 'OWN_POST', 'https://x.example/p/3', 'https://x.example/p/3', 'x.example', 'linkedin',
                    now(), 'APPROVED', 'e1', now())`), "external_share_self_review_ck");
    assertViolates(failure(api, `INSERT INTO external_sharing.external_share (employee_id, action, evidence_url,
            evidence_url_submitted, evidence_host, provider, certified_at, decision, decided_by, decided_at)
            VALUES ('e1', 'OWN_POST', 'https://x.example/p/4', 'https://x.example/p/4', 'x.example', 'linkedin',
                    now(), 'REJECTED', 'po-1', now())`), "external_share_reject_reason_ck");
    assertViolates(failure(api, `INSERT INTO external_sharing.external_share (employee_id, action, evidence_url,
            evidence_url_submitted, evidence_host, provider, certified_at)
            VALUES ('e1', 'OWN_POST', 'http://x.example/p/5', 'http://x.example/p/5', 'x.example', 'linkedin', now())`),
            "external_share_evidence_url_check");
    // One claim per URL per action (C5), across employees.
    _ = check api->execute(`INSERT INTO external_sharing.external_share (employee_id, action, evidence_url,
            evidence_url_submitted, evidence_host, provider, certified_at)
            VALUES ('e1', 'OWN_POST', 'https://x.example/p/once', 'https://x.example/p/once', 'x.example', 'linkedin', now())`);
    assertViolates(failure(api, `INSERT INTO external_sharing.external_share (employee_id, action, evidence_url,
            evidence_url_submitted, evidence_host, provider, certified_at)
            VALUES ('e2', 'OWN_POST', 'https://x.example/p/once', 'https://x.example/p/once', 'x.example', 'linkedin', now())`),
            "external_share_evidence_uk");

    // Sharing (B14, privacy).
    string engagementId = check api->queryRow(`INSERT INTO sharing.engagement (provider, provider_api, origin,
            target_resource_urn, actor_member_urn, employee_id, action, activity_urn, occurred_at)
            VALUES ('linkedin', 'SHARE_ON_LINKEDIN', 'IN_APP', 'urn:li:share:it-ck', 'urn:li:person:ck', 'e-ck',
                    'REPOST', 'urn:li:share:it-ck-activity', now())
            RETURNING id::text`);
    assertViolates(failure(api, `INSERT INTO sharing.share_request (campaign_id, employee_id, provider, provider_api,
            target_resource_urn, kind, published_at, failed_at, failure_reason, engagement_id)
            VALUES (uuidv7(), 'e1', 'linkedin', 'SHARE_ON_LINKEDIN', 'urn:li:share:1', 'REPOST', now(), now(),
                    'NEEDS_RECONNECT', CAST(${engagementId} AS uuid))`), "share_request_published_xor_failed_ck");
    assertViolates(failure(api, `INSERT INTO sharing.share_request (campaign_id, employee_id, provider, provider_api,
            target_resource_urn, kind, commentary, published_at, engagement_id)
            VALUES (uuidv7(), 'e1', 'linkedin', 'SHARE_ON_LINKEDIN', 'urn:li:share:1', 'REPOST_COMMENTARY', 'kept',
                    now(), CAST(${engagementId} AS uuid))`), "share_request_commentary_cleared_ck");
    assertViolates(failure(api, `INSERT INTO sharing.share_request (campaign_id, employee_id, provider, provider_api,
            target_resource_urn, kind, published_at)
            VALUES (uuidv7(), 'e1', 'linkedin', 'SHARE_ON_LINKEDIN', 'urn:li:share:1', 'REPOST', now())`),
            "share_request_engagement_ck");
    // Once per action per resource per person (the three-way filter).
    assertViolates(failure(api, `INSERT INTO sharing.engagement (provider, provider_api, origin, target_resource_urn,
            actor_member_urn, employee_id, action, occurred_at)
            VALUES ('linkedin', 'WEBHOOK', 'WEBHOOK', 'urn:li:share:it-ck', 'urn:li:person:ck', 'e-ck', 'REPOST', now())`),
            "engagement_once_uk");
    assertViolates(failure(api, `INSERT INTO sharing.share_request (campaign_id, employee_id, provider, provider_api,
            target_resource_urn, kind, failed_at)
            VALUES (uuidv7(), 'e1', 'linkedin', 'SHARE_ON_LINKEDIN', 'urn:li:share:1', 'REPOST', now())`),
            "share_request_failure_reason_ck");
    assertViolates(failure(api, `INSERT INTO sharing.share_request (campaign_id, employee_id, provider, provider_api,
            target_resource_urn, kind, attempts)
            VALUES (uuidv7(), 'e1', 'linkedin', 'SHARE_ON_LINKEDIN', 'urn:li:share:1', 'REPOST', 0)`),
            "share_request_attempts_check");

    // Ledger (C1, ADR-010, phase 1 has no PAID).
    assertViolates(failure(api, `INSERT INTO scoring.points_ledger (reference, employee_id, source_type, points, actor_id)
            VALUES ('ADJ-it-no-reason', 'e1', 'ADJUSTMENT', 5, 'po-1')`), "points_ledger_reason_ck");
    assertViolates(failure(api, `INSERT INTO scoring.points_ledger (reference, employee_id, source_type, points, actor_id)
            VALUES ('AMP-it-no-rule', 'e1', 'ENGAGEMENT', 5, 'system')`), "points_ledger_award_ck");
    assertViolates(failure(api, `INSERT INTO scoring.points_ledger (reference, employee_id, source_type, points, actor_id,
            reason, status, paid_at)
            VALUES ('ADJ-it-paid', 'e1', 'ADJUSTMENT', 5, 'po-1', 'x', 'PAID', now())`), "points_ledger_no_paid_phase1_ck");
    assertViolates(failure(api, `INSERT INTO scoring.points_ledger (reference, employee_id, source_type, points, actor_id, reason)
            VALUES ('XYZ-it', 'e1', 'ADJUSTMENT', 5, 'po-1', 'x')`), "points_ledger_reference_check");
    assertViolates(failure(api, `INSERT INTO scoring.points_ledger (reference, employee_id, source_type, points, actor_id, reason)
            VALUES ('REV-it-orphan', 'e1', 'REVERSAL', -5, 'po-1', 'x')`), "points_ledger_reversal_ck");

    // Campaign and identity.
    assertViolates(failure(api, `INSERT INTO campaign.campaign (provider, resource_urn, resource_type, owner_urn, title,
            category_code, opens_at, closes_at, created_by)
            VALUES ('linkedin', 'urn:li:share:it-window', 'SHARE', 'urn:li:organization:1', 'T', 'PRODUCT',
                    now(), now() - interval '1 day', 'po-1')`), "campaign_window_ck");
    assertViolates(failure(api, `INSERT INTO campaign.campaign (provider, resource_urn, resource_type, owner_urn, title,
            category_code, opens_at, closes_at, created_by)
            VALUES ('linkedin', 'urn:li:share:it-owner', 'SHARE', 'urn:li:person:1', 'T', 'PRODUCT',
                    now(), now() + interval '1 day', 'po-1')`), "campaign_owner_urn_check");
    _ = check api->execute(`INSERT INTO identity.employee (employee_id, email, display_name)
            VALUES ('it-citext-1', 'Case.Person@WSO2.com', 'Case Person') ON CONFLICT DO NOTHING`);
    assertViolates(failure(api, `INSERT INTO identity.employee (employee_id, email, display_name)
            VALUES ('it-citext-2', 'case.person@wso2.com', 'Case Person')`), "employee_email_key");

    // Connection (ADR-002, B13).
    assertViolates(failure(api, `INSERT INTO connection.member_connection (employee_id, provider, member_urn, provider_api,
            current_token_id, access_expires_at, connected_at)
            VALUES ('it-half', 'linkedin', 'urn:li:person:half', 'SHARE_ON_LINKEDIN', uuidv7(), now(), now())`),
            "member_connection_token_ref_ck");
    assertViolates(failure(api, `INSERT INTO connection.oauth_state (state, employee_id, provider, provider_api, nonce,
            expires_at) VALUES ('short', 'e1', 'linkedin', 'SHARE_ON_LINKEDIN', 'n', now() + interval '5 minutes')`),
            "oauth_state_state_check");
    assertViolates(failure(api, `INSERT INTO connection.provider_token (owner_type, owner_id, provider, token_kind,
            ciphertext, nonce, key_id, expires_at)
            VALUES ('MEMBER', 'e1', 'linkedin', 'ACCESS', '\x00'::bytea, '\x00'::bytea, 'k1', now())`),
            "provider_token_nonce_check");

    // Messaging and config.
    assertViolates(failure(jobs, `INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload,
            idempotency_key, status) VALUES ('t', '1', 'T', '{}', 'it:done-no-time', 'DONE')`), "outbox_done_processed_ck");
    assertViolates(failure(jobs, `INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload,
            idempotency_key, status) VALUES ('t', '1', 'T', '{}', 'it:bad-status', 'SENT')`), "outbox_status_check");
    assertViolates(failure(api, `INSERT INTO config.app_setting (key, value) VALUES ('NoDots', '1')`), "app_setting_key_check");
    assertViolates(failure(jobs, `INSERT INTO announcement.announcement (campaign_id, space, thread_key, sent_at, failed_at)
            VALUES (uuidv7(), 'club', 'k', now(), now())`), "announcement_sent_xor_failed_ck");

    // uuidv7 defaults.
    int version = check api->queryRow(`SELECT uuid_extract_version(id)::int FROM external_sharing.external_share
                                       WHERE evidence_url = 'https://x.example/p/once'`);
    test:assertEquals(version, 7, "ids default to UUIDv7");
    check api.close();
    check jobs.close();
}

// ---- grants: each role is denied what it must not do -----------------------------------------------

@test:Config {groups: ["integration"], dependsOn: [testV012IsApplied]}
function testGrantsDenyPerRole() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client ro = check readonlyClient();
    postgresql:Client api = check apiClient();
    postgresql:Client jobs = check jobsClient();

    // amplify_readonly: no tokens, connections, commentary, messaging, audit or config; no writes.
    assertDenied(selectFailure(ro, `SELECT count(*)::int FROM connection.provider_token`), "readonly tokens");
    assertDenied(selectFailure(ro, `SELECT count(*)::int FROM connection.member_connection`), "readonly connections");
    assertDenied(selectFailure(ro, `SELECT count(commentary)::int FROM sharing.share_request`), "readonly commentary");
    assertDenied(selectFailure(ro, `SELECT count(*)::int FROM messaging.outbox`), "readonly outbox");
    assertDenied(selectFailure(ro, `SELECT count(*)::int FROM audit.audit_log`), "readonly audit");
    assertDenied(selectFailure(ro, `SELECT count(*)::int FROM config.app_setting`), "readonly config");
    assertDenied(failure(ro, `INSERT INTO identity.employee (employee_id, email, display_name)
            VALUES ('ro', 'ro@wso2.com', 'ro')`), "readonly insert");
    // The reads succeeding is the check here (the grant exists); how many rows the fixture holds is not.
    int _ = check ro->queryRow(`SELECT count(*)::int FROM sharing.share_request_v`);
    int _ = check ro->queryRow(`SELECT count(*)::int FROM recognition.standing`);

    // amplify_api: no upkeep, no rebuild, no campaign delete, no ledger rewrite, no announcement writes.
    assertDenied(selectFailure(api, `SELECT 1 FROM (SELECT messaging.run_partition_maintenance()) m`), "api upkeep");
    assertDenied(selectFailure(api, `SELECT recognition.rebuild(3)::int`), "api rebuild");
    assertDenied(selectFailure(api, `SELECT connection.drop_expired_token_partitions(0)`), "api token drop");
    assertDenied(failure(api, `DELETE FROM campaign.campaign`), "api campaign delete (archive only)");
    assertDenied(failure(api, `UPDATE scoring.points_ledger SET points = 0`), "api ledger rewrite");
    assertDenied(failure(api, `DELETE FROM scoring.points_ledger`), "api ledger delete");
    assertDenied(failure(api, `INSERT INTO announcement.announcement (campaign_id, space, thread_key)
            VALUES (uuidv7(), 'club', 'k')`), "api announcement insert");
    assertDenied(failure(api, `UPDATE audit.audit_log SET reason = 'x'`), "api audit rewrite");
    assertDenied(failure(api, `DELETE FROM audit.audit_log`), "api audit delete");

    // amplify_jobs: no config writes, no campaign/identity writes, no audit rewrite, no direct audit helper.
    assertDenied(failure(jobs, `UPDATE config.app_setting SET value = 'false' WHERE key = 'sharing.enabled'`),
            "jobs settings write");
    assertDenied(failure(jobs, `INSERT INTO identity.employee (employee_id, email, display_name)
            VALUES ('j', 'j@wso2.com', 'j')`), "jobs employee insert");
    assertDenied(failure(jobs, `UPDATE campaign.campaign SET title = 'x'`), "jobs campaign update");
    assertDenied(failure(jobs, `UPDATE scoring.points_ledger SET points = 0`), "jobs ledger rewrite");
    assertDenied(failure(jobs, `DELETE FROM audit.audit_log`), "jobs audit delete");
    assertDenied(selectFailure(jobs, `SELECT 1 FROM (SELECT audit.write_system_audit('X', 'y', NULL, NULL)) a`),
            "jobs forging a system audit row");

    // Nobody but the runner sets passwords; nobody creates in public; partitions only through the parent.
    foreach postgresql:Client c in [ro, api, jobs] {
        assertDenied(selectFailure(c, `SELECT 1 FROM (SELECT public.amplify_set_login_password('amplify_api',
                'abcdefghijklmnop1')) p`), "app role setting a password");
        assertDenied(failure(c, `CREATE TABLE public.it_squat (id int)`), "app role creating in public");
    }
    string today = re `-`.replaceAll(utcDay(0), "");
    sql:ParameterizedQuery direct = `SELECT count(*)::int FROM connection.provider_token_p`;
    direct.strings = [string `SELECT count(*)::int FROM connection.provider_token_p${today}`].cloneReadOnly();
    assertDenied(selectFailure(jobs, direct), "direct partition access");
    check ro.close();
    check api.close();
    check jobs.close();
}

// ---- SECURITY DEFINER functions, views, ownership ----------------------------------------------------

@test:Config {groups: ["integration"], dependsOn: [testV012IsApplied]}
function testDefinerFunctionsArePinnedOwnedAndPrivate() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client db = check adminClient(itDbName);
    int definers = check db->queryRow(`
        SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.prosecdef AND n.nspname IN ('identity', 'campaign', 'connection', 'sharing', 'external_sharing',
              'scoring', 'recognition', 'announcement', 'messaging', 'audit', 'config', 'public')`);
    test:assertEquals(definers, 9, "the V009 upkeep functions and V018's erase_employee are the only SECURITY DEFINER functions");
    int unpinned = check db->queryRow(`
        SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.prosecdef AND NOT ('search_path=pg_catalog, pg_temp' = ANY (coalesce(p.proconfig, '{}')))`);
    test:assertEquals(unpinned, 0, "every SECURITY DEFINER function pins search_path");
    int notMigrateOwned = check db->queryRow(`
        SELECT count(*)::int FROM pg_proc p WHERE p.prosecdef AND pg_get_userbyid(p.proowner) <> 'amplify_migrate'`);
    test:assertEquals(notMigrateOwned, 0);
    int publicExecutable = check db->queryRow(`
        SELECT count(*)::int FROM pg_proc p
        WHERE p.prosecdef AND has_function_privilege('amplify_readonly', p.oid, 'EXECUTE')`);
    test:assertEquals(publicExecutable, 0, "no SECURITY DEFINER function is executable by PUBLIC");
    int apiExecutable = check db->queryRow(`
        SELECT count(*)::int FROM pg_proc p
        WHERE p.prosecdef AND has_function_privilege('amplify_api', p.oid, 'EXECUTE')`);
    test:assertEquals(apiExecutable, 0, "upkeep is amplify_jobs only");
    int timeouts = check db->queryRow(`
        SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname || '.' || p.proname IN ('messaging.run_partition_maintenance', 'connection.create_token_partitions',
              'connection.drop_expired_token_partitions', 'audit.create_audit_partitions', 'audit.drop_old_audit_partitions',
              'messaging.purge_done_outbox')
          AND 'lock_timeout=5s' = ANY (coalesce(p.proconfig, '{}'))`);
    test:assertEquals(timeouts, 6, "V012: every upkeep function bounds its lock waits");
    int invokerViolations = check db->queryRow(`
        SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'v' AND n.nspname IN ('campaign', 'connection', 'sharing', 'external_sharing', 'announcement')
          AND NOT ('security_invoker=true' = ANY (coalesce(c.reloptions, '{}')))`);
    test:assertEquals(invokerViolations, 0, "every *_v view is security_invoker");
    int appOwned = check db->queryRow(`
        SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('identity', 'campaign', 'connection', 'sharing', 'external_sharing', 'scoring',
              'recognition', 'announcement', 'messaging', 'audit', 'config')
          AND pg_get_userbyid(c.relowner) <> 'amplify_migrate'`);
    test:assertEquals(appOwned, 0, "amplify_migrate owns every relation, partitions included");
    check db.close();
}

// ---- partition functions: guards and UTC bounds -----------------------------------------------------

@test:Config {groups: ["integration"], dependsOn: [testPartitionsCreatedAhead]}
function testPartitionFunctionGuardsAndUtcBounds() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client jobs = check roleClient("amplify_jobs", itJobsPassword, 1);
    // The token fixture is inserted as the admin: since V017 amplify_jobs no longer inserts tokens.
    postgresql:Client admin = check adminClient(itDbName);
    test:assertTrue(selectFailure(jobs, `SELECT connection.create_token_partitions(-1)`).includes("0-60"));
    test:assertTrue(selectFailure(jobs, `SELECT connection.create_token_partitions(61)`).includes("0-60"));
    test:assertTrue(selectFailure(jobs, `SELECT audit.create_audit_partitions(25)`).includes("0-24"));
    test:assertTrue(selectFailure(jobs, `SELECT connection.drop_expired_token_partitions(-1)`).includes(">= 0"));
    test:assertTrue(selectFailure(jobs, `SELECT messaging.purge_done_outbox(0)::int`).includes(">= 1"));

    // Bounds are UTC whatever the session time zone: 23:30 in Chicago on Oct 31 is Nov 1 in UTC.
    check sqlText(jobs, "SET TIME ZONE 'America/Chicago'");
    _ = check jobs->queryRow(`SELECT audit.create_audit_partitions(1, DATE '2031-10-01')`, int);
    string landed = check jobs->queryRow(`
        WITH a AS (INSERT INTO audit.audit_log (at, actor_id, action, entity_type, outcome)
                   VALUES (TIMESTAMPTZ '2031-10-31 23:30:00-05', 'it', 'IT_TZ', 'it', 'SUCCESS')
                   RETURNING tableoid)
        SELECT tableoid::regclass::text FROM a`);
    test:assertEquals(landed, "audit.audit_log_p203111", "an evening in Chicago on Oct 31 is November in UTC");
    _ = check jobs->queryRow(`SELECT connection.create_token_partitions(0, DATE '2031-10-31')`, int);
    string tokenDay = check jobs->queryRow(`
        SELECT pg_get_expr(c.relpartbound, c.oid) FROM pg_class c
        WHERE c.oid = to_regclass('connection.provider_token_p20311031')`);
    test:assertEquals(tokenDay, "FOR VALUES FROM ('2031-10-31') TO ('2031-11-01')");
    check sqlText(jobs, "RESET TIME ZONE");

    // A token issued today lands in today's partition.
    string todayPart = check admin->queryRow(`
        WITH t AS (INSERT INTO connection.provider_token (owner_type, owner_id, provider, token_kind, ciphertext,
                       nonce, key_id, expires_at)
                   VALUES ('MEMBER', 'it-today', 'linkedin', 'ACCESS', '\x00'::bytea,
                           '\x000000000000000000000000'::bytea, 'k1', now() + interval '60 days')
                   RETURNING tableoid)
        SELECT tableoid::regclass::text FROM t`);
    test:assertEquals(todayPart, "connection." + dayName(0));
    // Today's partition is never dropped, even with grace 0 and nothing valid in it.
    _ = check jobs->execute(`UPDATE connection.provider_token SET expires_at = now() - interval '30 days'
                             WHERE owner_id = 'it-today'`);
    _ = check jobs->queryRow(`SELECT connection.drop_expired_token_partitions(0)`, int);
    test:assertTrue(check partitionExists(jobs, "connection", dayName(0)), "today is never dropped");
    _ = check jobs->execute(`DELETE FROM connection.provider_token WHERE owner_id = 'it-today'`);
    check admin.close();
    check jobs.close();
}

// ---- V012: recognition writers are serialized ---------------------------------------------------------

function appendAndApply(postgresql:Client db, string reference, string employeeId, int points) returns error? {
    _ = check db->execute(`INSERT INTO scoring.points_ledger (reference, employee_id, source_type, points, actor_id, reason)
                           VALUES (${reference}, ${employeeId}, 'ADJUSTMENT', ${points}, 'it', 'concurrency test')`);
    _ = check db->queryRow(`SELECT recognition.apply_ledger_entry(${reference}, 3)`, int);
}

function secondWriter(postgresql:Client db, string reference, string employeeId, int points) returns error? {
    check sqlText(db, "BEGIN");
    check appendAndApply(db, reference, employeeId, points);
    check sqlText(db, "COMMIT");
}

@test:Config {groups: ["integration"], dependsOn: [testV012IsApplied]}
function testConcurrentLedgerAppendsKeepRanksConsistent() returns error? {
    if !itEnabled {
        return;
    }
    // Two writers (as amplify_jobs and amplify_api) append top-of-board rows at the same time.
    postgresql:Client first = check roleClient("amplify_jobs", itJobsPassword, 1);
    postgresql:Client second = check roleClient("amplify_api", itApiPassword, 1);
    string tag = time:utcNow()[0].toString();
    check sqlText(first, "BEGIN");
    check appendAndApply(first, "ADJ-it-c1-" + tag, "it-conc-1-" + tag, 1000003);
    future<error?> other = start secondWriter(second, "ADJ-it-c2-" + tag, "it-conc-2-" + tag, 1000007);
    runtime:sleep(1.5);
    check sqlText(first, "COMMIT");
    check wait other;

    postgresql:Client db = check adminClient(itDbName);
    int wrong = check db->queryRow(`
        SELECT count(*)::int FROM (
            SELECT s.rank, dense_rank() OVER (ORDER BY s.total_points DESC)::int AS expected
            FROM recognition.standing s WHERE s.period_key = 'ALL') r
        WHERE r.rank IS DISTINCT FROM r.expected`);
    test:assertEquals(wrong, 0, "after two concurrent appends every rank matches the points");
    int rankOne = check db->queryRow(`SELECT count(*)::int FROM recognition.standing
                                      WHERE period_key = 'ALL' AND rank = 1`);
    test:assertEquals(rankOne, 1, "one employee at rank 1");
    check first.close();
    check second.close();
    check db.close();
}

// ---- V012: upkeep can't stall the app behind a lock -------------------------------------------------

@test:Config {groups: ["integration"], dependsOn: [testAuditRetentionAndOutboxPurge, testPartitionFunctionGuardsAndUtcBounds]}
function testUpkeepGivesUpOnALockInsteadOfQueueing() returns error? {
    if !itEnabled {
        return;
    }
    // A month past retention to drop, so the upkeep needs ACCESS EXCLUSIVE on audit.audit_log.
    postgresql:Client jobs = check roleClient("amplify_jobs", itJobsPassword, 1);
    string old = time:utcToString(time:utcAddSeconds(time:utcNow(), -64d * 31d * 86400d)).substring(0, 10);
    _ = check jobs->queryRow(`SELECT audit.create_audit_partitions(0, CAST(${old} AS date))`, int);
    // A long reader holds a lock on the audit table.
    postgresql:Client reader = check roleClient("amplify_api", itApiPassword, 1);
    check sqlText(reader, "BEGIN");
    _ = check reader->queryRow(`SELECT count(*)::int FROM audit.audit_log`, int);
    // Without the V012 lock_timeout the call would queue until statement_timeout (57014).
    check sqlText(jobs, "SET statement_timeout = '20s'");
    decimal started = time:monotonicNow();
    string|error result = jobs->queryRow(`SELECT messaging.run_partition_maintenance()::text`);
    decimal waited = time:monotonicNow() - started;
    test:assertTrue(result is error, "the upkeep must not get through a held lock");
    if result is error {
        test:assertTrue(result.message().includes("lock timeout"), string `lock_timeout, not statement_timeout: ${result.message()}`);
    }
    test:assertTrue(waited < 10d, string `gave up after the 5 s lock_timeout, waited ${waited}`);
    check sqlText(reader, "ROLLBACK");

    // Once the reader is gone the same call goes through and drops the month.
    string done = check jobs->queryRow(`SELECT messaging.run_partition_maintenance()::text`);
    json counts = check done.fromJsonString();
    int droppedNow = check (check counts.audit_partitions_dropped).ensureType();
    test:assertTrue(droppedNow >= 1);
    check sqlText(jobs, "RESET statement_timeout");
    check reader.close();
    check jobs.close();
}
