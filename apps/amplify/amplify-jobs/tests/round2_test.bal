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


// Round 2 (2026-10-17): the campaign title on SHARE posts (common H5 / jobs H1), a duplicate publish that
// settles instead of staying QUEUED (domain H-5), re-seal on use and the maintenance key-rotation step
// (common H4 / jobs H2), the DB TLS settings (domain H-1) and a pool-exhausted database failing readiness
// (item 12.5).

import amplify_common.crypto;
import amplify_common.linkedin;
import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.identity;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/http;
import ballerina/random;

import ballerina/lang.runtime;
import ballerina/sql;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

@test:Config
function shareCarriesTheCampaignTitle() returns error? {
    [World, string, int] [w, _, _] = check shareWorld("emp-title");
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1);
    test:assertEquals(w.linkedIn.lastTargetTitle(), "Ballerina 2201.13 is out",
            "the post carries the campaign title, not the generic default");
}

@test:Config
function duplicatePublishSettlesOnTheExistingEngagement() returns error? {
    [World, string, int] [w, cid, id] = check shareWorld("emp-dup");
    sharing:ShareRequest? share = check w.mem.share(cid, "emp-dup");
    if share is () {
        return error("no share");
    }
    // The employee already has an engagement for this target (an earlier round).
    sharing:Engagement earlier = {
        id: "eng-earlier",
        provider: types:LINKEDIN,
        providerApi: types:SHARE_ON_LINKEDIN,
        origin: types:IN_APP,
        targetResourceUrn: share.targetResourceUrn,
        campaignId: types:newUuidV7(),
        actorMemberUrn: "urn:li:person:emp-dup",
        employeeId: "emp-dup",
        action: share.kind,
        activityUrn: "urn:li:share:6999999999999999999",
        occurredAt: time:utcNow(),
        observedAt: time:utcNow(),
        lastVerifiedAt: (),
        deletedAt: ()
    };
    w.mem.putEngagement(earlier);
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    sharing:ShareRequest? settled = check w.mem.share(cid, "emp-dup");
    test:assertTrue(settled is sharing:ShareRequest && sharing:shareStatus(settled) == sharing:PUBLISHED,
            "no longer stuck QUEUED");
    test:assertEquals(settled is sharing:ShareRequest ? settled.engagementId : (), "eng-earlier");
    test:assertEquals(w.queue.countByType("EngagementRecorded"), 0, "nothing scored twice");
}

@test:Config
function duplicateWithoutAMatchingEngagementFailsTheShare() returns error? {
    [World, string, int] [w, cid, _] = check shareWorld("emp-dup2");
    w.mem.failNextPublishAsDuplicate();
    _ = check run(w);
    sharing:ShareRequest? failed = check w.mem.share(cid, "emp-dup2");
    test:assertTrue(failed is sharing:ShareRequest && failed.failureReason == types:PROVIDER_REJECTED
            && failed.lastErrorCode == "DUPLICATE_ENGAGEMENT", "settled as FAILED, not left QUEUED");
}

function cipherOf(string keyId, int seed) returns crypto:TokenCipher|error {
    byte[] key = [];
    foreach int i in 0 ..< 32 {
        key.push(<byte>((i * 5 + seed) % 256));
    }
    return new ([{keyId, key}], keyId);
}

@test:Config
function aTokenOnAnOldKeyIsResealedOnUse() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    var share = queuedShare(cid, "emp-rot", now);
    w.mem.putShare(share);
    crypto:TokenCipher old = check cipherOf("k-old", 3);
    check connectedEmployee(w.mem, old, "emp-rot", now);
    byte[] oldKey = [];
    byte[] newKey = [];
    foreach int i in 0 ..< 32 {
        oldKey.push(<byte>((i * 5 + 3) % 256));
        newKey.push(<byte>(i + 7));
    }
    crypto:TokenCipher ring = check new ([{keyId: "k-old", key: oldKey}, {keyId: "k1", key: newKey}], "k1");
    w.deps.cipher = ring;
    _ = w.queue.enqueue("RepostRequested", repostRequested(share.id, cid, "emp-rot"));
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1, "the share still goes out");
    test:assertEquals(w.linkedIn.last()[0], "bearer-emp-rot");
    test:assertEquals(w.mem.resealCount(), 1);
    connection:LinkedInConnection? conn = check w.mem.connection("emp-rot");
    connection:TokenRef? ref = conn is () ? () : conn.currentToken;
    connection:StoredToken? row = ref is () ? () : w.mem.storedToken(ref.tokenId);
    if row is () {
        return error("token gone");
    }
    test:assertEquals(row.keyId, "k1", "moved to the active key");
    test:assertEquals(check connection:openToken(ring, row), "bearer-emp-rot");
    test:assertTrue(connection:openToken(old, row) is error, "the old key alone can't read it");
}

@test:Config
function rotationStepReportsAndNeverFails() returns error? {
    MemTokens tokens = new;
    crypto:TokenCipher old = check cipherOf("k-old", 3);
    byte[] oldKey = [];
    byte[] newKey = [];
    foreach int i in 0 ..< 32 {
        oldKey.push(<byte>((i * 5 + 3) % 256));
        newKey.push(<byte>(i + 7));
    }
    crypto:TokenCipher ring = check new ([{keyId: "k-old", key: oldKey}, {keyId: "k1", key: newKey}], "k1");
    time:Utc now = time:utcNow();
    foreach int i in 0 ..< 3 {
        tokens.add(check connection:sealToken(old, "bearer", string `emp-${i}`, time:utcAddSeconds(now, 60), now));
    }
    test:assertEquals(rotateTokenKeys((), tokens), {status: "NOT_CONFIGURED", resealed: 0, skipped: 0, failed: 0});
    test:assertEquals(rotateTokenKeys(ring, tokens), {status: "DONE", resealed: 3, skipped: 0, failed: 0});
    test:assertEquals(rotateTokenKeys(ring, tokens), {status: "DONE", resealed: 0, skipped: 0, failed: 0});
    tokens.breakNext();
    test:assertEquals(rotateTokenKeys(ring, tokens).status, "FAILED", "a database error is reported, not thrown");
}

isolated class MemTokens {
    *connection:TokenResealStore;
    private connection:StoredToken[] rows = [];
    private boolean broken = false;

    isolated function add(connection:StoredToken t) {
        lock {
            self.rows.push(t.clone());
        }
    }

    isolated function breakNext() {
        lock {
            self.broken = true;
        }
    }

    public isolated function sealedWithOtherKey(string activeKeyId, connection:TokenRef? after, int 'limit)
            returns connection:StoredToken[]|error {
        lock {
            if self.broken {
                self.broken = false;
                return error sql:DatabaseError("Connection refused", errorCode = 0, sqlState = "08006");
            }
            if after !is () {
                return [];
            }
            connection:StoredToken[] page = from connection:StoredToken t in self.rows where t.keyId != activeKeyId
                select t;
            return page.clone();
        }
    }

    public isolated function updateSeal(connection:StoredToken old, crypto:SealedToken resealed) returns boolean|error {
        lock {
            foreach connection:StoredToken t in self.rows {
                if t.tokenId == old.tokenId && t.keyId == old.keyId {
                    t.keyId = resealed.keyId;
                    t.ciphertext = resealed.ciphertext.clone();
                    t.nonce = resealed.nonce.clone();
                    return true;
                }
            }
            return false;
        }
    }
}

// Domain review H-1: VERIFY_FULL by default, the CA file passed through.
@test:Config
function dbConfigVerifiesTheServerByDefault() {
    store:DbConfig cfg = dbConfig();
    test:assertEquals(cfg.sslMode, postgresql:VERIFY_FULL);
    test:assertTrue(store:verifiesServer(cfg));
    test:assertEquals(cfg.sslRootCert, "");
    test:assertEquals(dbConfig(maxOpenConnections = 1).maxOpenConnections, 1, "the run-lock connection");
    test:assertEquals(dbConfig(maxConnectionLifeTime = 0).maxConnectionLifeTime, 0d,
            "the session advisory lock must outlive the run, so its connection is never retired");
    test:assertTrue(dbMaintenanceSocketTimeoutSeconds < 180d,
            "stay below amplify-api's 180 s maintenance deadline, so a slow pass answers 500 and its retry is skipped");
}

// Item 12.5: a pool with leaked connections answers "Connection is not available"; the breaker counts it as
// transient, opens after the threshold, and `/ready` then answers DOWN (so the pod restarts).
@test:Config {groups: ["db-breaker"]}
function poolExhaustionFailsReadiness() returns error? {
    dbBreaker.reset();
    sql:Error exhausted = error sql:ApplicationError(
        "Failed to get a connection: HikariPool-1 - Connection is not available, request timed out after 3000ms.");
    test:assertTrue(resilience:isTransientDbError(exhausted));
    foreach int i in 0 ..< dbBreakerFailureThreshold {
        recordDbFailure(exhausted);
    }
    test:assertEquals(dbBreaker.state(), "OPEN");
    test:assertFalse(dbReachable(), "an open breaker refuses the probe");
    ReadyReport report = readiness(dbBreaker.state() != "OPEN" && dbReachable(), breakerStates(), false);
    test:assertEquals(report.status, types:DOWN);
    dbBreaker.reset();
}

// Item 12.5 against a real pool: one connection, held by a slow query; the next borrow times out with the
// HikariCP "Connection is not available" error, which the breaker counts, and readiness goes DOWN.
@test:Config {groups: ["integration"]}
function realPoolExhaustionTripsTheBreaker() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client tiny = check store:newClient({host: itDbHost, port: itDbPort, database: itDbName,
        user: "amplify_jobs", password: itJobsPassword, sslMode: postgresql:DISABLE, maxOpenConnections: 1,
        minIdleConnections: 0, poolAcquireTimeoutSeconds: 1});
    future<error?> holder = start holdConnection(tiny);
    runtime:sleep(0.5);
    resilience:DbBreaker breaker = new ({failureThreshold: 2, windowSeconds: 30, resetTimeSeconds: 30});
    string message = "";
    foreach int i in 0 ..< 2 {
        error? probed = store:probe(tiny);
        if probed is () {
            return error("the pool should be exhausted");
        }
        message = probed.message();
        test:assertTrue(resilience:isTransientDbError(probed), "pool exhaustion is transient: " + message);
        _ = breaker.onFailure(probed);
    }
    test:assertTrue(message.includes("Connection is not available"), message);
    test:assertEquals(breaker.state(), "OPEN");
    test:assertEquals(readiness(breaker.state() != "OPEN", {}, false).status, types:DOWN);
    error? held = wait holder;
    check held;
    check tiny.close();
}

isolated function holdConnection(postgresql:Client db) returns error? {
    _ = check db->queryRow(`SELECT pg_sleep(4)::text`, string);
}

// Common H5 / jobs H1 end to end: a SHARE_COMMENTARY post through the Run reaches mock_linkedin, which
// (like the real Posts API) refuses an article without `content.article.title`; the post it stored carries
// the campaign's own title.
@test:Config {groups: ["integration"], dependsOn: [testM6OneRunAcrossReplicasStaleLocksAndPurge]}
function testShareArticleCarriesTheCampaignTitleToLinkedIn() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client apiDb = check itConnect("amplify_api", itApiPassword);
    postgresql:Client jobsDb = check itConnect("amplify_jobs", itJobsPassword);
    postgresql:Client lockDb = check itConnect("amplify_jobs", itJobsPassword, 1);
    linkedin:LinkedInAdapter adapter = check new ({apiBaseUrl: mockApiUrl, authBaseUrl: mockWwwUrl,
        clientId: mockClientId, clientSecret: mockClientSecret, redirectUri: mockRedirectUri});
    Deps deps = check itDeps(jobsDb, lockDb, adapter);
    check drain(deps, "it-title-drain");

    time:Utc now = time:utcNow();
    string emp = "emp-title-" + types:newUuidV7().substring(24);
    check (new identity:PgEmployeeRepository(apiDb)).upsert(check identity:recordSeen((),
            {sub: emp, email: emp + "@wso2.com", name: "Title IT"}, now));
    string urn = string `urn:li:share:7${check random:createIntInRange(100000000, 999999999)}${check random:createIntInRange(100000000, 999999999)}`;
    string title = "Round 2 title " + emp;
    campaign:Campaign c = check campaign:registerCampaign(new campaign:PgCampaignRepository(apiDb,
            {actorId: emp, roles: ["amplify_po"]}), {
        resourceUrn: urn,
        ownerUrn: "urn:li:organization:1337",
        title,
        categoryCode: "PRODUCT",
        tags: ["it"],
        resourceUrl: "https://www.linkedin.com/feed/update/" + urn + "/"
    }, {wso2OrganizationUrn: "urn:li:organization:1337"}, emp, true, now);

    linkedin:TokenGrant grant = check mockAccessToken(adapter);
    linkedin:MemberProfile me = check adapter.userInfo(grant.accessToken);
    _ = check jobsDb->execute(`DELETE FROM connection.member_connection WHERE member_urn = ${me.memberUrn}`);
    connection:StoredToken sealed = check connection:sealToken(check testCipher(), grant.accessToken, emp,
            time:utcAddSeconds(now, <decimal>grant.expiresInSeconds), now);
    _ = check connection:completeConnection(new connection:PgConnectionRepository(apiDb, {actorId: emp}), {
        employeeId: emp, memberUrn: me.memberUrn, scopes: grant.scopes, token: connection:tokenRef(sealed),
        expiresInSeconds: grant.expiresInSeconds}, now, sealed);
    sharing:ShareRequest share = check sharing:requestShare(new sharing:PgShareRepository(apiDb, {actorId: emp}),
            {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn, open: true}, {memberUrn: me.memberUrn, usable: true},
            {employeeId: emp, kind: types:SHARE_COMMENTARY, commentary: "Worth a read " + emp}, now);
    _ = check itRun(deps, "it-title-run");

    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM sharing.share_request_v
            WHERE id = CAST(${share.id} AS uuid) AND status = 'PUBLISHED'`), 1,
            "published: the mock accepted the article (it refuses one without a title)");
    http:Client mock = check new (mockApiUrl);
    json[] posts = check mock->get("/mock/posts", {"X-Amplify-Internal-Key": mockAdminKey});
    json[] mine = from json p in posts where (check p.commentary) == "Worth a read " + emp select p;
    test:assertEquals(mine.length(), 1);
    test:assertEquals(check mine[0].articleTitle, title, "the campaign title, not the generic default");
}
