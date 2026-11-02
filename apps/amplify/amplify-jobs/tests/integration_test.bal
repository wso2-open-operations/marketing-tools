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

// M6 integration test (group `integration`, `AMPLIFY_IT=true`) against a migrated PostgreSQL 18 as
// `amplify_jobs` / `amplify_api`, with `apps/amplify/linkedin/apps/mock_linkedin` as LinkedIn and the Chat stub
// below as the Club space: register campaign → announce; connect (mock OAuth, token sealed into today's
// partition) → share → publish → engagement → points → standing; rerun safety; one run across replicas;
// stale-lock release; idempotency-key purge. Recipe: docs/migrations/README.md.

import amplify_common.googlechat;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.identity;
import amplify_domain.recognition;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/http;
import ballerina/os;
import ballerina/random;
import ballerina/sql;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

final boolean itEnabled = os:getEnv("AMPLIFY_IT") == "true";
final string itDbHost = envOr("AMPLIFY_IT_DB_HOST", "localhost");
final int itDbPort = checkpanic int:fromString(envOr("AMPLIFY_IT_DB_PORT", "5432"));
final string itDbName = envOr("AMPLIFY_IT_DB_NAME", "amplify_it");
final string itApiPassword = envOr("AMPLIFY_IT_API_PASSWORD", "it-api-password-00001");
final string itJobsPassword = envOr("AMPLIFY_IT_JOBS_PASSWORD", "it-jobs-password-0001");
final string mockApiUrl = envOr("AMPLIFY_IT_LINKEDIN_API", "http://localhost:19190");
final string mockAdminKey = envOr("AMPLIFY_IT_MOCK_ADMIN_KEY", "it-mock-admin-key-0123456789abcdef0123");
final string mockWwwUrl = envOr("AMPLIFY_IT_LINKEDIN_WWW", "http://localhost:19191");
final string mockClientId = envOr("AMPLIFY_IT_LINKEDIN_CLIENT_ID", "it-client");
final string mockClientSecret = envOr("AMPLIFY_IT_LINKEDIN_CLIENT_SECRET", "it-secret");
final string mockRedirectUri = envOr("AMPLIFY_IT_LINKEDIN_REDIRECT", "http://localhost:3000/auth/linkedin/callback");

const int CHAT_STUB_PORT = 9298;

type ChatLog record {|
    int posts;
    string[] threadKeys;
    string[] correlationIds;
|};

isolated ChatLog chatLog = {posts: 0, threadKeys: [], correlationIds: []};

function chatSnapshot() returns ChatLog {
    lock {
        return chatLog.clone();
    }
}

# Tiny Google Chat stub: accepts the webhook POST and answers like Chat.
service /v1/spaces on new http:Listener(CHAT_STUB_PORT) {
    resource function post [string space]/messages(http:Request req, string threadKey) returns http:Ok {
        string|http:HeaderNotFoundError corr = req.getHeader("X-Correlation-ID");
        string correlationId = corr is string ? corr : "";
        int n;
        lock {
            chatLog.posts += 1;
            chatLog.threadKeys.push(threadKey);
            chatLog.correlationIds.push(correlationId);
            n = chatLog.posts;
        }
        return {body: {name: string `spaces/${space}/messages/m${n}`, thread: {name: string `spaces/${space}/threads/t1`}}};
    }
}

function envOr(string name, string fallback) returns string {
    string value = os:getEnv(name);
    return value == "" ? fallback : value;
}

function itConnect(string user, string password, int poolSize = 5) returns postgresql:Client|error =>
    store:newClient({host: itDbHost, port: itDbPort, database: itDbName, user, password, sslMode: postgresql:DISABLE,
        maxOpenConnections: poolSize, minIdleConnections: 1});

function itCount(postgresql:Client db, sql:ParameterizedQuery query) returns int|error {
    int n = check db->queryRow(query);
    return n;
}

function mockPostCount() returns int|error {
    http:Client c = check new (mockApiUrl);
    json[] posts = check c->get("/mock/posts", {"X-Amplify-Internal-Key": mockAdminKey});
    return posts.length();
}

function mockAccessToken(linkedin:LinkedInAdapter adapter) returns linkedin:TokenGrant|error {
    http:Client www = check new (mockWwwUrl, {followRedirects: {enabled: false}});
    string url = check adapter.authorizationUrl("it-state");
    http:Response res = check www->get(url.substring(mockWwwUrl.length()));
    string location = check res.getHeader("Location");
    int codeStart = <int>location.indexOf("code=") + 5;
    int? codeEnd = location.indexOf("&", codeStart);
    return adapter.exchangeCode(location.substring(codeStart, codeEnd ?: location.length()));
}

function itDeps(postgresql:Client jobsDb, postgresql:Client lockDb, linkedin:LinkedInAdapter adapter) returns Deps|error {
    RunConfig cfg = {...TEST_CONFIG};
    cfg.maxRows = 1000;
    return {
    runStore: new PgRunStore(jobsDb),
    runLock: new PgRunLock(lockDb),
    chat: new WebhookChat(check new googlechat:WebhookClient({
        webhookUrl: string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/it/messages?key=k&token=t`}), "dev-test", 0),
    linkedIn: adapter,
    cipher: check testCipher(),
    config: cfg,
    breakers: noBreakers
    };
}

# Runs until the outbox has nothing due (earlier suites, such as the domain IT's 240-write concurrency
# test, can leave more than one run's `maxRows`).
#
# + deps - Run dependencies
# + corr - Correlation id
# + return - An error
function drain(Deps deps, string corr) returns error? {
    foreach int i in 0 ..< 20 {
        RunReport r = check itRun(deps, corr);
        if r.claimed < deps.config.maxRows {
            return;
        }
    }
}

function itRun(Deps deps, string corr) returns RunReport|error {
    RunReport|RunSkipped r = check runOnce(deps, corr);
    if r is RunSkipped {
        return error("run skipped");
    }
    return r;
}

@test:Config {groups: ["integration"]}
function testM6RunAnnouncesSharesAndScores() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client apiDb = check itConnect("amplify_api", itApiPassword);
    postgresql:Client jobsDb = check itConnect("amplify_jobs", itJobsPassword);
    postgresql:Client lockDb = check itConnect("amplify_jobs", itJobsPassword, 1);
    _ = check store:runPartitionMaintenance(jobsDb);
    linkedin:LinkedInAdapter adapter = check new ({apiBaseUrl: mockApiUrl, authBaseUrl: mockWwwUrl,
        clientId: mockClientId, clientSecret: mockClientSecret, redirectUri: mockRedirectUri});
    Deps deps = check itDeps(jobsDb, lockDb, adapter);
    // Drain whatever earlier suites left in the outbox, so the counts below are this test's.
    check drain(deps, "it-drain");

    // Employee + campaign (amplify-api side).
    time:Utc now = time:utcNow();
    string emp = "emp-m6-" + types:newUuidV7().substring(24);
    check (new identity:PgEmployeeRepository(apiDb)).upsert(check identity:recordSeen((),
            {sub: emp, email: emp + "@wso2.com", name: "M6 IT"}, now));
    string urn = string `urn:li:share:7${check random:createIntInRange(100000000, 999999999)}${check random:createIntInRange(100000000, 999999999)}`;
    campaign:Campaign c = check campaign:registerCampaign(new campaign:PgCampaignRepository(apiDb,
            {actorId: emp, roles: ["amplify_po"], correlationId: "it-corr-campaign"}), {
        resourceUrn: urn,
        ownerUrn: "urn:li:organization:1337",
        title: "M6 integration campaign",
        categoryCode: "PRODUCT",
        tags: ["it"],
        resourceUrl: "https://www.linkedin.com/feed/update/" + urn + "/"
    }, {wso2OrganizationUrn: "urn:li:organization:1337"}, emp, true, now);

    // Connect through the mock OAuth flow; seal the token into today's partition (amplify-api side).
    linkedin:TokenGrant grant = check mockAccessToken(adapter);
    linkedin:MemberProfile me = check adapter.userInfo(grant.accessToken);
    _ = check jobsDb->execute(`DELETE FROM connection.member_connection WHERE member_urn = ${me.memberUrn}`);
    connection:StoredToken sealed = check connection:sealToken(check testCipher(), grant.accessToken, emp,
            time:utcAddSeconds(now, <decimal>grant.expiresInSeconds), now);
    check (new connection:PgTokenRepository(apiDb)).insert(sealed);
    _ = check connection:completeConnection(new connection:PgConnectionRepository(apiDb, {actorId: emp}), {
        employeeId: emp, memberUrn: me.memberUrn, scopes: grant.scopes, token: connection:tokenRef(sealed),
        expiresInSeconds: grant.expiresInSeconds}, now);
    sharing:ShareRequest share = check sharing:requestShare(new sharing:PgShareRepository(apiDb,
            {actorId: emp, correlationId: "it-corr-share-" + emp}), {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn,
        open: true}, {memberUrn: me.memberUrn, usable: true},
            {employeeId: emp, kind: types:REPOST_COMMENTARY, commentary: "Proud of this " + emp}, now);

    int postsBefore = check mockPostCount();
    int chatBefore = chatSnapshot().posts;
    RunReport report = check itRun(deps, "it-corr-run");
    test:assertTrue(report.claimed >= 4, "CampaignRegistered, RepostRequested, EngagementRecorded, PointsAwarded...");
    test:assertEquals(report.failed, 0);

    // Announced once, threaded, correlation id propagated.
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM announcement.announcement_v
            WHERE campaign_id = CAST(${c.id} AS uuid) AND status = 'SENT' AND chat_message_name IS NOT NULL
              AND chat_thread_name IS NOT NULL`), 1);
    ChatLog log = chatSnapshot();
    test:assertEquals(log.posts, chatBefore + 1);
    test:assertEquals(log.threadKeys[log.threadKeys.length() - 1], "campaign-" + c.id);
    test:assertEquals(log.correlationIds[log.correlationIds.length() - 1], "it-corr-campaign");
    // Published once on LinkedIn, commentary cleared, engagement + points + standing.
    test:assertEquals(check mockPostCount(), postsBefore + 1);
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM sharing.share_request_v
            WHERE id = CAST(${share.id} AS uuid) AND status = 'PUBLISHED'`), 1);
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM sharing.share_request
            WHERE id = CAST(${share.id} AS uuid) AND commentary IS NULL`), 1, "commentary cleared on publish");
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM sharing.engagement
            WHERE employee_id = ${emp} AND activity_urn LIKE 'urn:li:share:%'`), 1);
    int points = check itCount(jobsDb, `SELECT coalesce(sum(points), 0)::int FROM scoring.points_ledger
            WHERE employee_id = ${emp}`);
    test:assertTrue(points > 0);
    recognition:Standing? standing = check recognition:standingOf(jobsDb, emp);
    test:assertTrue(standing is recognition:Standing && standing.totalPoints == points, "standing updated in the award tx");
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM audit.audit_log
            WHERE correlation_id = ${"it-corr-share-" + emp} AND action = 'EngagementRecorded'`), 1,
            "jobs writes carry the outbox row's correlation id");

    // Rerun safety: redeliver every row of this flow, run twice more. No second post, card or ledger row.
    _ = check jobsDb->execute(`UPDATE messaging.outbox SET status = 'PENDING', next_attempt_at = now()
            WHERE aggregate_id IN (${c.id}, ${share.id}) AND status = 'DONE'`);
    _ = check itRun(deps, "it-rerun-1");
    _ = check itRun(deps, "it-rerun-2");
    test:assertEquals(check mockPostCount(), postsBefore + 1, "no double post");
    test:assertEquals(chatSnapshot().posts, chatBefore + 1, "no second card");
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM scoring.points_ledger WHERE employee_id = ${emp}`), 1,
            "no double ledger row");
}

@test:Config {groups: ["integration"], dependsOn: [testM6RunAnnouncesSharesAndScores]}
function testM6OneRunAcrossReplicasStaleLocksAndPurge() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client jobsDb = check itConnect("amplify_jobs", itJobsPassword);
    postgresql:Client lockDb = check itConnect("amplify_jobs", itJobsPassword, 1);
    postgresql:Client otherReplica = check itConnect("amplify_jobs", itJobsPassword, 1);
    linkedin:LinkedInAdapter adapter = check new ({apiBaseUrl: mockApiUrl, authBaseUrl: mockWwwUrl,
        clientId: mockClientId, clientSecret: mockClientSecret, redirectUri: mockRedirectUri});
    Deps deps = check itDeps(jobsDb, lockDb, adapter);

    // Another replica holds the advisory lock: this one skips.
    PgRunLock other = new (otherReplica);
    test:assertTrue(check other.tryAcquire());
    RunReport|RunSkipped skipped = check runOnce(deps);
    test:assertTrue(skipped is RunSkipped);
    check other.release();

    // A row left IN_PROGRESS by a dead run is released and handled.
    string key = "ConnectionReady:it-stale-" + types:newUuidV7();
    _ = check jobsDb->execute(`INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload,
            idempotency_key, status, attempts, locked_by, locked_until)
        VALUES ('member_connection', 'it', 'ConnectionReady', '{}'::jsonb, ${key}, 'IN_PROGRESS', 1, 'dead-run',
            now() - interval '1 minute')`);
    RunReport report = check itRun(deps, "it-stale");
    test:assertTrue(report.staleReleased >= 1);
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM messaging.outbox
            WHERE idempotency_key = ${key} AND status = 'DONE'`), 1);

    // Expired Idempotency-Key rows are purged by the maintenance pass.
    _ = check jobsDb->execute(`INSERT INTO messaging.idempotency_key (employee_id, key, request_hash, expires_at)
        VALUES ('it', ${key}, 'h', now() - interval '1 hour')`);
    test:assertTrue(check store:purgeExpiredIdempotencyKeys(jobsDb) >= 1);
}

// One partition maintenance pass at a time across replicas: a pass that outlives the scheduler's deadline is
// not started again by its retry (no second reseal sweep, no second partition drop).
@test:Config {groups: ["integration"]}
function aSecondMaintenancePassIsSkippedWhileOneIsRunning() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client first = check itConnect("amplify_jobs", itJobsPassword, 1);
    postgresql:Client second = check itConnect("amplify_jobs", itJobsPassword, 1);
    PgRunLock held = new (first, MAINTENANCE_LOCK_KEY);
    PgRunLock rival = new (second, MAINTENANCE_LOCK_KEY);
    test:assertTrue(check held.tryAcquire());
    test:assertFalse(check rival.tryAcquire(), "the retry answers 202 SKIPPED, not a second pass");
    check held.release();
    test:assertTrue(check rival.tryAcquire(), "once the pass is done the lock is free");
    check rival.release();
    check first.close();
    check second.close();
}

// The maintenance pass and the run use different advisory keys, so neither blocks the other.
@test:Config
function theMaintenanceLockIsNotTheRunLock() {
    test:assertNotEquals(MAINTENANCE_LOCK_KEY, RUN_LOCK_KEY);
}
