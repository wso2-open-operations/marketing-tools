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

// LinkedIn connect (S2) on the fake provider: `returnTo` open-redirect guard, single-use employee-bound state,
// the server-side redirect URI check, provider failures mapped without leaking, the startup redirect URI
// rules; and the idempotency edges (ADR-024): in progress, 4xx stored, 5xx released, key-store failures
// counted against the DB breaker, replay bytes.

import amplify_common.types;
import amplify_domain.connection;

import ballerina/http;
import ballerina/sql;
import ballerina/test;
import ballerina/time;

function startFor(string token, json body = {}) returns http:Response|error =>
    send("POST", "/connections/linkedin/start", body, token);

function stateOf(http:Response res) returns string|error => (check (check res.getJsonPayload()).state).toString();

@test:Config {groups: ["connect"]}
function testConnectStartRefusesOpenRedirects() returns error? {
    setLinkedInMode("OK");
    string token = check employee("emp-conn-1");
    foreach string bad in ["//evil.example", "/\\evil.example", "https://evil.example", "evil", "/a b", "/a\tb",
            "/" + "a".padEnd(512, "a")] {
        http:Response res = check startFor(token, {returnTo: bad});
        test:assertEquals(res.statusCode, 400, bad);
        test:assertEquals(check codeIn(res), "VALIDATION_FAILED", bad);
    }
    test:assertEquals((check startFor(token, {pendingCampaignId: "nope"})).statusCode, 400);
    foreach string good in ["/", "/amplify/campaigns/123?share=1"] {
        http:Response ok = check startFor(token, {returnTo: good});
        test:assertEquals(ok.statusCode, 200, good);
        check assertShape(ok, "ConnectAuthorization");
    }
    http:Response noBody = check send("POST", "/connections/linkedin/start", (), token);
    test:assertEquals(noBody.statusCode, 200, "the body is optional");
}

@test:Config {groups: ["connect"]}
function testConnectStartSeparatesMissingBodyFromMalformedBody() returns error? {
    // `start` reads the body itself, so no body (`{}`) and a body that is not JSON must not be the same case.
    setLinkedInMode("OK");
    string token = check employee("emp-conn-1b");
    http:Response malformed = check api->execute("POST", "/connections/linkedin/start", "{not json", {
        "x-jwt-assertion": token,
        "Content-Type": "application/json"
    });
    test:assertEquals(malformed.statusCode, 400, "unparseable JSON is a 400, not a 200 with the defaults");
    test:assertEquals(malformed.getContentType(), "application/problem+json");
    test:assertEquals(check codeIn(malformed), "VALIDATION_FAILED");
    test:assertEquals((check send("POST", "/connections/linkedin/start", (), token)).statusCode, 200,
            "and a request with no body still starts the flow");
}

@test:Config {groups: ["connect"]}
function testConnectCompleteFlowAndStateRules() returns error? {
    setLinkedInMode("OK");
    string token = check employee("emp-conn-2");
    string state = check stateOf(check startFor(token, {returnTo: "/amplify/home", pendingCampaignId: SAMPLE_UUID}));

    http:Response wrongPage = check send("POST", "/connections/linkedin/complete",
            {code: "c-1", state, redirectUri: "https://evil.example/callback"}, token);
    test:assertEquals(wrongPage.statusCode, 422);
    test:assertEquals(check codeIn(wrongPage), "OAUTH_REDIRECT_MISMATCH");

    http:Response otherEmployee = check send("POST", "/connections/linkedin/complete", {code: "c-1", state, redirectUri: TEST_REDIRECT_URI},
            check employee("emp-conn-3"));
    test:assertEquals(otherEmployee.statusCode, 409, "state is bound to the employee who started");
    test:assertEquals(check codeIn(otherEmployee), "OAUTH_STATE_INVALID");

    int tokens = fakeTokens.count();
    int saved = fakeConnections.tokensSaved();
    http:Response done = check send("POST", "/connections/linkedin/complete",
            {code: "c-abcdef", state, redirectUri: TEST_REDIRECT_URI}, token);
    test:assertEquals(done.statusCode, 200);
    check assertShape(done, "LinkedInConnection");
    json body = check done.getJsonPayload();
    test:assertEquals(check body.returnTo, "/amplify/home");
    test:assertEquals(check body.pendingCampaignId, SAMPLE_UUID);
    test:assertEquals(fakeConnections.tokensSaved(), saved + 1, "the sealed token goes in with the connection save");
    test:assertEquals(fakeTokens.count(), tokens, "and is never inserted on its own (api H3)");
    test:assertFalse(body.toJsonString().includes("li-token"), "the access token never reaches the caller");

    http:Response reused = check send("POST", "/connections/linkedin/complete", {code: "c-abcdef", state, redirectUri: TEST_REDIRECT_URI}, token);
    test:assertEquals(check codeIn(reused), "OAUTH_STATE_INVALID", "state is single use");

    foreach [json, string] [bad, why] in [[{code: "", state, redirectUri: TEST_REDIRECT_URI}, "empty code"],
            [{code: "c", state: "short", redirectUri: TEST_REDIRECT_URI}, "short state"], [{code: "c", state, redirectUri: TEST_REDIRECT_URI, extra: 1}, "unknown field"],
            [{code: "c", state}, "missing redirectUri"]] {
        test:assertEquals((check send("POST", "/connections/linkedin/complete", bad, token)).statusCode, 400, why);
    }
}

@test:Config {groups: ["connect"]}
function testConnectProviderFailures() returns error? {
    string token = check employee("emp-conn-4");
    setLinkedInMode("OK");
    string rejectedState = check stateOf(check startFor(token));
    setLinkedInMode("REJECTED");
    http:Response rejected = check send("POST", "/connections/linkedin/complete", {code: "c-2", state: rejectedState, redirectUri: TEST_REDIRECT_URI},
            token);
    test:assertEquals(rejected.statusCode, 422);
    test:assertEquals(check codeIn(rejected), "OAUTH_STATE_INVALID");
    test:assertFalse((check rejected.getTextPayload()).includes("bad code"), "the provider message stays in the log");

    setLinkedInMode("OK");
    string downState = check stateOf(check startFor(token));
    setLinkedInMode("DOWN");
    http:Response down = check send("POST", "/connections/linkedin/complete", {code: "c-3", state: downState, redirectUri: TEST_REDIRECT_URI}, token);
    test:assertEquals(down.statusCode, 503);
    test:assertEquals(check codeIn(down), "DEPENDENCY_UNAVAILABLE");

    setLinkedInMode("OFF");
    test:assertEquals((check startFor(token)).statusCode, 503, "LinkedIn not configured");
    test:assertEquals((check send("POST", "/connections/linkedin/complete", {code: "c", state: downState, redirectUri: TEST_REDIRECT_URI}, token)).statusCode,
            503);
    setLinkedInMode("OK");
}

@test:Config {groups: ["connect"]}
function testRedirectUriStartupRules() {
    test:assertEquals(checkRedirectUri("https://one.wso2.com/amplify/linkedin/callback", "prod"), ());
    test:assertEquals(checkRedirectUri("http://localhost:3000/amplify/linkedin/callback", "local"), ());
    foreach [string, string] [uri, env] in [
        ["http://one.wso2.com/cb", "prod"],
        ["", "prod"],
        ["/amplify/linkedin/callback", "prod"],
        ["https://one.wso2.com/cb?x=1", "prod"],
        ["https://one.wso2.com/cb#x", "prod"],
        ["https://user:pw@one.wso2.com/cb", "prod"],
        ["https:///cb", "prod"],
        ["https://one.wso2.com/c b", "prod"],
        ["javascript:alert(1)", "local"]
    ] {
        test:assertTrue(checkRedirectUri(uri, env) is error, string `${uri} on ${env}`);
    }
}

@test:Config {groups: ["connect"]}
function testRemoveConnection() returns error? {
    connect("emp-conn-5");
    http:Response removed = check send("DELETE", "/connections/linkedin", (), check employee("emp-conn-5"));
    test:assertEquals(removed.statusCode, 204);
}

// ---- Idempotency (ADR-024) ------------------------------------------------------------------------------

@test:Config {groups: ["idempotency"]}
function testIdempotencyInProgressStoredAndReleased() returns error? {
    string token = check employee("emp-idem-1");
    json body = {evidenceUrl: "https://example.org/uncertified", certified: false};
    http:Response first = check send("POST", "/external-shares", body, token, {"Idempotency-Key": "idem-4xx"});
    test:assertEquals(first.statusCode, 422);
    http:Response replay = check send("POST", "/external-shares", body, token, {"Idempotency-Key": "idem-4xx"});
    test:assertEquals(replay.statusCode, 422, "a 4xx is stored and replayed");
    test:assertEquals(replay.getHeader("Idempotent-Replayed"), "true");
    test:assertEquals(replay.getContentType(), "application/problem+json");
    test:assertEquals(check replay.getTextPayload(), check first.getTextPayload());

    // The first request with this key is still running.
    var row = idemRow("emp-idem-1", "idem-4xx");
    if row is () {
        test:assertFail("key row missing");
    }
    putIdemRow("emp-idem-1", "idem-4xx", {requestHash: row.requestHash, responseStatus: (), responseBody: ()});
    http:Response running = check send("POST", "/external-shares", body, token, {"Idempotency-Key": "idem-4xx"});
    test:assertEquals(running.statusCode, 409);
    test:assertEquals(check codeIn(running), "IDEMPOTENCY_IN_PROGRESS");

    // (An empty key can't be sent: the HTTP client refuses an empty header value.)
    foreach string bad in ["k".padEnd(256, "k")] {
        http:Response res = check send("POST", "/external-shares", body, token, {"Idempotency-Key": bad});
        test:assertEquals(res.statusCode, 400, string `key of ${bad.length()}`);
    }

    // A 5xx is released: the same key runs again once the dependency is back.
    resetSync();
    string admin = check adminToken();
    fakeScheduler.setUp(false);
    http:Response down = check send("POST", "/admin/scheduler/sync", (), admin, {"Idempotency-Key": "idem-5xx"});
    test:assertEquals(down.statusCode, 503);
    test:assertEquals(idemRow("adm-0001", "idem-5xx"), (), "a 5xx outcome is not remembered");
    fakeScheduler.setUp(true);
    http:Response up = check send("POST", "/admin/scheduler/sync", (), admin, {"Idempotency-Key": "idem-5xx"});
    test:assertEquals(up.statusCode, 200);
    test:assertEquals(up.getHeader("Idempotent-Replayed") is error, true, "it ran again, not a replay");
    check assertShape(up, "SchedulerSync");
}

@test:Config {groups: ["idempotency", "db-breaker"]}
function testIdempotencyStoreFailuresCountAgainstTheDbBreaker() returns error? {
    dbBreaker.reset();
    setIdemClaimError(error sql:DatabaseError("Connection refused", errorCode = 0, sqlState = "08006"));
    do {
        string token = check employee("emp-idem-2");
        foreach int i in 0 ..< 3 {
            http:Response res = check send("POST", "/external-shares",
                    {evidenceUrl: "https://example.org/x" + i.toString(), certified: true}, token,
                    {"Idempotency-Key": "idem-db-" + i.toString()});
            test:assertEquals(res.statusCode, 503);
            test:assertEquals(check codeIn(res), "DEPENDENCY_UNAVAILABLE");
        }
        test:assertEquals(dbBreakerState(), "OPEN", "the key store is the database: its outage opens the breaker");
    } on fail error e {
        setIdemClaimError(());
        dbBreaker.reset();
        return e;
    }
    setIdemClaimError(());
    dbBreaker.reset();
}

@test:Config {groups: ["idempotency"]}
function testJsonResponseKeepsTheStandardBytes() returns error? {
    json body = {campaign: {id: SAMPLE_UUID, title: "quote \" and é", tags: ["a", "b"], archivedAt: ()}, run: "DEFERRED"};
    http:Response ok = jsonResponse(201, body);
    test:assertEquals(ok.statusCode, 201);
    test:assertEquals(ok.getContentType(), "application/json");
    test:assertEquals(check ok.getTextPayload(), body.toJsonString());
    http:Response problem = jsonResponse(422, {code: "X"});
    test:assertEquals(problem.getContentType(), "application/problem+json");
    http:Response empty = jsonResponse(204, ());
    test:assertEquals(empty.statusCode, 204);
}

// A connection whose sealed token the fake token store can return, so removal can open and revoke it.
function connectWithToken(string employeeId, string plaintext) returns error? {
    time:Utc now = time:utcNow();
    connection:StoredToken stored = check connection:sealToken(testCipher, plaintext, employeeId,
            types:addDays(now, 30), now);
    fakeTokens.seed(stored);
    fakeConnections.put({
        employeeId,
        provider: types:LINKEDIN,
        memberUrn: "urn:li:person:" + employeeId,
        providerApi: types:SHARE_ON_LINKEDIN,
        scopes: ["w_member_social"],
        currentToken: {tokenId: stored.tokenId, issuedOn: stored.issuedOn},
        accessExpiresAt: types:addDays(now, 30),
        connectedAt: now,
        revokedAt: (),
        removedAt: (),
        lastRemindedAt: (),
        version: 1
    });
}

@test:Config {groups: ["connect"]}
function testRemoveRevokesAtLinkedInThenDeletes() returns error? {
    setLinkedInMode("OK");
    check connectWithToken("emp-conn-rm1", "li-token-revoke-me");
    http:Response removed = check send("DELETE", "/connections/linkedin", (), check employee("emp-conn-rm1"));
    test:assertEquals(removed.statusCode, 204);
    test:assertTrue(revokedSoFar().indexOf("li-token-revoke-me") !is (), "the sealed token was revoked at LinkedIn");
}

@test:Config {groups: ["connect"]}
function testRemoveKeepsTheConnectionWhenLinkedInCantRevoke() returns error? {
    check connectWithToken("emp-conn-rm2", "li-token-keep-me");
    setLinkedInMode("REVOKE_DOWN");
    http:Response refused = check send("DELETE", "/connections/linkedin", (), check employee("emp-conn-rm2"));
    setLinkedInMode("OK");
    test:assertEquals(refused.statusCode, 503);
    test:assertEquals(check codeIn(refused), "DEPENDENCY_UNAVAILABLE");
    test:assertEquals(revokedSoFar().indexOf("li-token-keep-me"), (), "nothing was revoked");

    http:Response retried = check send("DELETE", "/connections/linkedin", (), check employee("emp-conn-rm2"));
    test:assertEquals(retried.statusCode, 204, "nothing was deleted, so a retry works");
    test:assertTrue(revokedSoFar().indexOf("li-token-keep-me") !is ());
}
