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
import amplify_api.auth;
import amplify_common.types;
import amplify_domain.identity;
import amplify_domain.store;

import ballerina/crypto;
import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

// No client cache: `/leaderboard` is `private, max-age=30`, and a cached 200 would answer the anonymous and
// breaker-open calls of later tests without reaching the server.
final http:Client api = check new (string `http://localhost:${port}`, {cache: {enabled: false}});

function call(string method, string path, string? token) returns http:Response|error {
    map<string> headers = {};
    if token is string {
        headers = {"x-jwt-assertion": token, "X-Correlation-ID": "test-corr-1"};
    }
    return api->execute(method, path, method == "GET" ? () : {}, headers);
}

function codeOf(http:Response res) returns string|error {
    json body = check res.getJsonPayload();
    return (check body.code).toString();
}

// ---- Authentication: 401 ------------------------------------------------------------------------

@test:Config
function testMissingTokenIs401() returns error? {
    _ = takeDenials();
    http:Response res = check call("GET", "/me", ());
    test:assertEquals(res.statusCode, 401);
    test:assertEquals(res.getContentType(), "application/problem+json");
    test:assertEquals(check codeOf(res), auth:TOKEN_MISSING);
    // RFC 9110 section 11.6.1: a 401 names the scheme it expects.
    test:assertEquals(check res.getHeader("WWW-Authenticate"), "Bearer realm=\"amplify\"");
    store:AuditEntry[] audit = takeDenials();
    test:assertEquals(audit.length(), 1);
    test:assertEquals(audit[0].actorId, "anonymous");
    test:assertEquals(audit[0].outcome, "DENIED");
    test:assertEquals(audit[0].reason, auth:TOKEN_MISSING);
}

@test:Config
function testInvalidTokensAre401() returns error? {
    _ = takeDenials();
    int now = time:utcNow()[0];
    crypto:PrivateKey rogue = check rogueKey.ensureType();
    [string, string][] cases = [
        [check mint({exp: now - 3600, iat: now - 7200}), auth:TOKEN_EXPIRED],
        [check mint({exp: ()}), auth:TOKEN_EXPIRED],
        [check mint({aud: "someone-else"}), auth:TOKEN_AUDIENCE_INVALID],
        [check mint({iss: "https://evil.example"}), auth:TOKEN_ISSUER_INVALID],
        [check mint(key = rogue), auth:TOKEN_SIGNATURE_INVALID],
        [check mint(header = {alg: "HS256"}), auth:TOKEN_ALG_NOT_ALLOWED],
        [check mint({sub: ()}), auth:TOKEN_CLAIMS_INVALID],
        [check mint({email: ()}), auth:TOKEN_CLAIMS_INVALID],
        [check mint({nbf: now + 3600}), auth:TOKEN_NOT_YET_VALID],
        ["not-a-jwt", auth:TOKEN_MALFORMED]
    ];
    foreach [string, string] [token, expected] in cases {
        http:Response res = check call("GET", "/me", token);
        test:assertEquals(res.statusCode, 401, expected);
        test:assertEquals(check codeOf(res), expected);
    }
    store:AuditEntry[] audit = takeDenials();
    test:assertEquals(audit.length(), cases.length());
    foreach store:AuditEntry entry in audit {
        test:assertEquals(entry.correlationId, "test-corr-1");
        test:assertFalse(entry.toJsonString().includes("eyJ"), "token leaked into the audit row");
    }
}

@test:Config
function testUnsignedTokenIs401() returns error? {
    string token = check mint();
    string unsigned = token.substring(0, <int>token.lastIndexOf(".")) + ".";
    http:Response res = check call("GET", "/me", unsigned);
    test:assertEquals(res.statusCode, 401);
}

@test:Config
function testProbesNeedNoToken() returns error? {
    http:Response res = check call("GET", "/health", ());
    test:assertEquals(res.statusCode, 200);
}

// ---- Authorization: activity matrix -------------------------------------------------------------

@test:Config
function testActivityMatrixSample() returns error? {
    // [method, path, groups, expected]. 0 = passed the interceptor (any status but 401/403).
    [string, string, string[], int][] cases = [
        ["GET", "/me", [], 200],
        ["GET", "/me", [SLT_GROUP], 200],
        ["GET", "/leaderboard", [], 0],
        ["GET", "/po/dashboard", [], 403],
        ["GET", "/po/dashboard", [MARKETING_GROUP], 403],
        ["GET", "/po/dashboard", [PO_GROUP], 0],
        ["POST", "/campaigns", [], 403],
        ["POST", "/campaigns", [SLT_GROUP], 403],
        ["POST", "/campaigns", [MARKETING_GROUP], 0],
        ["POST", "/campaigns", [PO_GROUP], 0],
        ["DELETE", "/campaigns/c-1", [ADMIN_GROUP], 403],
        // New Post / Current Posts writes: PO and Marketing only (CAN_CAMPAIGN).
        ["PATCH", "/campaigns/c-1", [], 403],
        ["PATCH", "/campaigns/c-1", [SLT_GROUP], 403],
        ["PATCH", "/campaigns/c-1", [PO_GROUP], 0],
        ["PATCH", "/campaigns/c-1", [MARKETING_GROUP], 0],
        ["DELETE", "/campaigns/c-1", [], 403],
        ["DELETE", "/campaigns/c-1", [SLT_GROUP], 403],
        ["DELETE", "/campaigns/c-1", [PO_GROUP], 0],
        ["DELETE", "/campaigns/c-1", [MARKETING_GROUP], 0],
        ["POST", "/po/external-shares/x-1/approve", [MARKETING_GROUP], 403],
        ["POST", "/po/external-shares/x-1/approve", [PO_GROUP], 0],
        ["POST", "/po/points/adjustments", [ADMIN_GROUP], 403],
        ["PUT", "/admin/settings", [PO_GROUP], 403],
        ["PUT", "/admin/settings", [ADMIN_GROUP], 0],
        ["GET", "/reports/participation", [ADMIN_GROUP], 403],
        ["GET", "/reports/participation", [SLT_GROUP], 0],
        ["GET", "/team/emp-9/history", [], 0],
        ["GET", "/not-in-matrix", [ADMIN_GROUP, PO_GROUP], 403],
        ["GET", "/po/dashboard", ["amplify_po_typo", "Admins"], 403]
    ];
    _ = takeDenials();
    int expectedDenials = 0;
    foreach [string, string, string[], int] [method, path, groups, expected] in cases {
        http:Response res = check call(method, path, check mint(groupsClaim(...groups)));
        if expected == 0 {
            // Past the interceptor: no 401, and no interceptor 403 (a use-case 403 such as TEAM_SCOPE is fine).
            boolean interceptorDenied = res.statusCode == 403
                && [ROLE_NOT_PERMITTED, ROUTE_NOT_PERMITTED].indexOf(check codeOf(res)) !is ();
            test:assertTrue(res.statusCode != 401 && !interceptorDenied,
                    string `${method} ${path} as ${groups.toString()} got ${res.statusCode}`);
        } else {
            test:assertEquals(res.statusCode, expected, string `${method} ${path} as ${groups.toString()}`);
        }
        if expected == 403 {
            expectedDenials += 1;
            test:assertEquals(res.getContentType(), "application/problem+json");
        }
    }
    store:AuditEntry[] audit = takeDenials();
    test:assertEquals(audit.length(), expectedDenials);
    test:assertEquals(audit[0].actorId, "emp-0001");
    test:assertEquals(audit[0].entityId, "GET /po/dashboard");
    test:assertEquals(audit[0].reason, "ROLE_NOT_PERMITTED");
}

@test:Config
function testMissingGroupsClaimIsPlainEmployee() returns error? {
    http:Response res = check call("GET", "/po/dashboard", check mint({groups: ()}));
    test:assertEquals(res.statusCode, 403);
    res = check call("GET", "/me", check mint({groups: ()}));
    test:assertEquals(res.statusCode, 200);
}

@test:Config
function testMatrixHelpers() {
    auth:AccessGroups access = {canCampaign: [PO_GROUP, MARKETING_GROUP], canAdjustPoints: [PO_GROUP],
        canAdmin: [ADMIN_GROUP], canReports: [SLT_GROUP]};
    test:assertEquals(auth:knownGroups("amplify_po, amplify_admin amplify_po", access), [PO_GROUP, ADMIN_GROUP]);
    test:assertEquals(auth:knownGroups(["amplify_slt", 42, "other"], access), [SLT_GROUP]);
    test:assertEquals(auth:knownGroups((), access), []);
    test:assertEquals(auth:knownGroups([PO_GROUP], {}), [], "no configuration names no group");
    test:assertEquals(auth:groupList(" amplify_po, amplify_marketing,,amplify_slt "),
            [PO_GROUP, MARKETING_GROUP, SLT_GROUP]);
    test:assertEquals(auth:groupList(""), []);
    // Any one group grants; a blank configured entry never matches a blank caller group (fail closed).
    test:assertEquals(auth:grantsOf([MARKETING_GROUP], access), [auth:EMPLOYEE, auth:CAN_CAMPAIGN]);
    test:assertEquals(auth:grantsOf([""], {canAdmin: [""]}), [auth:EMPLOYEE]);
    test:assertEquals(auth:grantsOf([], access), [auth:EMPLOYEE]);
    string[] po = auth:capabilities(auth:grantsOf([PO_GROUP], access));
    test:assertTrue(po.indexOf("team.history.read_any") !is ());
    test:assertTrue(po.indexOf("campaigns.read_any_status") !is ());
    test:assertTrue(po.indexOf("admin.settings") is ());
    string[] emp = auth:capabilities([auth:EMPLOYEE]);
    test:assertTrue(emp.indexOf("shares.create") !is ());
    test:assertTrue(emp.indexOf("campaigns.manage") is ());
    test:assertTrue(auth:capabilities([auth:EMPLOYEE, auth:CAN_CAMPAIGN]).indexOf("campaigns.manage") !is ());
    // Every route row names a capability and a known method.
    foreach auth:Rule rule in auth:ACTIVITY_MATRIX {
        test:assertTrue(["GET", "POST", "PATCH", "PUT", "DELETE"].indexOf(rule.method) !is (), rule.path);
        test:assertTrue(rule.capability.length() > 0, rule.path);
    }
}

@test:Config
function testSecondConfiguredGroupSharesACapability() returns error? {
    string token = check mint({sub: "cmp-0001", email: "cmp@wso2.com", groups: [CAMPAIGN_ONLY_GROUP]});
    http:Response me = check call("GET", "/me", token);
    test:assertEquals(me.statusCode, 200);
    json body = check me.getJsonPayload();
    test:assertEquals(check body.roles, [CAMPAIGN_ONLY_GROUP]);
    test:assertEquals(check body.grants, [auth:EMPLOYEE, auth:CAN_CAMPAIGN]);
    // Past the interceptor on the campaign routes, refused everywhere PO-only.
    test:assertNotEquals((check call("POST", "/campaigns", token)).statusCode, 403);
    test:assertEquals((check call("GET", "/po/dashboard", token)).statusCode, 403);
    test:assertEquals((check call("GET", "/dashboards/glance", token)).statusCode, 403);
}

// ---- GET /me --------------------------------------------------------------------------------------

@test:Config
function testMeUpsertsEmployeeAndReportsCapabilities() returns error? {
    http:Response res = check call("GET", "/me", check mint(groupsClaim(MARKETING_GROUP)));
    test:assertEquals(res.statusCode, 200);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.employee.email, "ada.lovelace@wso2.com");
    test:assertEquals(check body.employee.displayName, "Ada Lovelace");
    test:assertEquals(check body.roles, [MARKETING_GROUP]);
    test:assertEquals(check body.grants, [auth:EMPLOYEE, auth:CAN_CAMPAIGN, auth:CAN_DASHBOARD, auth:CAN_EXPORT]);
    json[] caps = check (check body.capabilities).ensureType();
    test:assertTrue(caps.indexOf("campaigns.manage") !is ());
    test:assertTrue(caps.indexOf("po.dashboard") is ());
    test:assertEquals(check body.linkedin.status, "NOT_CONNECTED");
    test:assertEquals(check body.linkedin.expiresAt, ());
    test:assertTrue(fakeEmployees.findById("emp-0001") is record {});
}

@test:Config
function testMeReportsLinkedInStatus() returns error? {
    time:Utc now = time:utcNow();
    time:Utc expires = types:addDays(now, 30);
    fakeConnections.put({
        employeeId: "emp-0002",
        provider: types:LINKEDIN,
        memberUrn: "urn:li:person:abc",
        providerApi: types:SHARE_ON_LINKEDIN,
        scopes: ["w_member_social"],
        currentToken: {tokenId: "t-1", issuedOn: "2026-10-16"},
        accessExpiresAt: expires,
        connectedAt: now,
        revokedAt: (),
        removedAt: (),
        lastRemindedAt: (),
        version: 1
    });
    http:Response res = check call("GET", "/me", check mint({sub: "emp-0002", email: "grace@wso2.com", name: ()}));
    test:assertEquals(res.statusCode, 200);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.employee.displayName, "grace");
    test:assertEquals(check body.linkedin.status, "ACTIVE");
    test:assertEquals(check body.linkedin.expiresAt, time:utcToString(expires));
}

// ---- Dev-only local signing (ADR-023) ------------------------------------------------------------

const string LOCAL_JWKS = "http://localhost:1/unset";

@test:Config
function testDevSwitchIsRefusedOutsideLocal() {
    postgresql:SSLMode off = postgresql:DISABLE;
    test:assertTrue(checkDevSwitch("prod", true, "amplify-local-dev", TEST_ISSUER, off, LOCAL_JWKS) is error);
    test:assertTrue(checkDevSwitch("dev", true, "amplify-local-dev", TEST_ISSUER, off, LOCAL_JWKS) is error);
    test:assertTrue(checkDevSwitch("local", true, TEST_ISSUER, TEST_ISSUER, off, LOCAL_JWKS) is error);
    test:assertTrue(checkDevSwitch("local", true, " ", TEST_ISSUER, off, LOCAL_JWKS) is error);
    test:assertTrue(checkDevSwitch("prod", false, "", TEST_ISSUER, postgresql:VERIFY_FULL, "https://idp.example/jwks")
            is ());
}

// Each of the three signs of a local stack is enough, on its own, to refuse the switch.
@test:Config
function testDevSwitchNeedsAllThreeLocalSigns() {
    string issuer = "amplify-local-dev";
    // The allowed local stack.
    test:assertTrue(checkDevSwitch("local", true, issuer, TEST_ISSUER, postgresql:DISABLE, LOCAL_JWKS) is ());
    // environment is not local.
    error? wrongEnv = checkDevSwitch("dev", true, issuer, TEST_ISSUER, postgresql:DISABLE, LOCAL_JWKS);
    test:assertTrue(wrongEnv is error);
    if wrongEnv is error {
        test:assertTrue(wrongEnv.message().includes("outside a local stack"));
    }
    // The database is verified or encrypted (a real database).
    test:assertTrue(checkDevSwitch("local", true, issuer, TEST_ISSUER, postgresql:VERIFY_FULL, LOCAL_JWKS) is error);
    test:assertTrue(checkDevSwitch("local", true, issuer, TEST_ISSUER, postgresql:REQUIRE, LOCAL_JWKS) is error);
    // The gateway JWKS is a real endpoint, not a local one.
    test:assertTrue(checkDevSwitch("local", true, issuer, TEST_ISSUER, postgresql:DISABLE,
            "https://api.asgardeo.io/t/org/oauth2/jwks") is error);
    test:assertTrue(checkDevSwitch("local", true, issuer, TEST_ISSUER, postgresql:DISABLE,
            "http://127.0.0.1:1/unset") is error);
    // Switched off, the three checks do not apply.
    test:assertTrue(checkDevSwitch("prod", false, issuer, TEST_ISSUER, postgresql:VERIFY_FULL, "https://x/jwks") is ());
}

@test:Config
function testReportsRowsAreNotAdvertisedUntilBuilt() {
    auth:AccessGroups access = {canReports: [SLT_GROUP], canDashboard: [SLT_GROUP]};
    auth:Access[] slt = auth:grantsOf([SLT_GROUP], access);
    test:assertTrue(slt.some(g => g == auth:CAN_REPORTS), "the grant itself still exists");
    string[] caps = auth:capabilities(slt);
    test:assertTrue(caps.indexOf("reports.read") is (), "GET /me must not advertise unbuilt /reports/*");
    test:assertTrue(caps.indexOf("dashboards.operations.read") !is ());
    // The matrix keeps the rows, so the route still answers 403 / authorised-404 as before.
    int unbuilt = 0;
    foreach auth:Rule rule in auth:ACTIVITY_MATRIX {
        if !rule.built {
            unbuilt += 1;
            test:assertTrue(rule.path.startsWith("/reports/"), rule.path);
        }
    }
    test:assertEquals(unbuilt, 2);
}

@test:Config
function testDevTrustOnlyAcceptsDevKeysForDevIssuer() returns error? {
    auth:JwksCache jwks = check new ({url: "http://localhost:9591/jwks"});
    auth:VerifierConfig config = {issuer: TEST_ISSUER, audiences: [TEST_AUDIENCE]};
    auth:Jwk devKey = check rogueJwk.ensureType();
    auth:TokenVerifier withDev = new (jwks, config, {issuer: "amplify-local-dev", keys: [devKey]});
    auth:TokenVerifier withoutDev = new (jwks, config);
    crypto:PrivateKey local = check rogueKey.ensureType();

    string devToken = check mint({iss: "amplify-local-dev"}, key = local);
    auth:Principal principal = check withDev.verify(devToken);
    test:assertEquals(principal.issuer, "amplify-local-dev");
    test:assertTrue(withoutDev.verify(devToken) is auth:AuthError, "dev token accepted with the switch off");
    // A dev-issuer token signed by the gateway key, and a gateway token signed by the dev key, both fail.
    test:assertTrue(withDev.verify(check mint({iss: "amplify-local-dev"})) is auth:AuthError);
    test:assertTrue(withDev.verify(check mint(key = local)) is auth:AuthError);
}

// ---- JWKS outage: keep serving with cached keys (M9) ---------------------------------------------

@test:Config {
    dependsOn: [testMissingTokenIs401, testInvalidTokensAre401, testUnsignedTokenIs401, testActivityMatrixSample,
        testMissingGroupsClaimIsPlainEmployee, testMeUpsertsEmployeeAndReportsCapabilities, testMeReportsLinkedInStatus,
        testDevTrustOnlyAcceptsDevKeysForDevIssuer]
}
function testJwksOutageServesCachedKeys() returns error? {
    http:Response warm = check call("GET", "/me", check mint());
    test:assertEquals(warm.statusCode, 200);
    setJwksDown(true);
    do {
        runtime:sleep(1.2); // past jwksRefreshSeconds, so the next call tries (and fails) a refresh
        http:Response res = check call("GET", "/me", check mint());
        test:assertEquals(res.statusCode, 200, "cached keys should keep serving while the IdP is down");

        auth:JwksCache cold = check new ({url: "http://localhost:9591/jwks"});
        auth:Jwk[]|auth:AuthError keys = cold.keysFor(TEST_KID);
        test:assertTrue(keys is auth:AuthError && keys.detail().code == auth:KEYS_UNAVAILABLE);
    } on fail error e {
        setJwksDown(false);
        return e;
    }
    setJwksDown(false);
}

// ---- Token length matches the listener header limit ----------------------------------------------

@test:Config
function testTokenLengthLimitMatchesTheListener() returns error? {
    // The HTTP listener refuses a header over its default `maxHeaderSize` (8192) before the verifier runs,
    // so a larger limit here would never fire. Keep the two equal.
    test:assertEquals(auth:MAX_TOKEN_LENGTH, 8192, "the token limit must not exceed the listener's header limit");
    auth:JwksCache jwks = check new ({url: "http://localhost:9591/jwks"});
    auth:TokenVerifier verifier = new (jwks, {issuer: TEST_ISSUER, audiences: [TEST_AUDIENCE]});
    // Three parts (so only the length check can reject it), one byte past the limit.
    string tooLong = "a".padEnd(auth:MAX_TOKEN_LENGTH, "a") + ".b.c";
    auth:Principal|auth:AuthError result = verifier.verify(tooLong);
    test:assertTrue(result is auth:AuthError, "a token past the limit is malformed");
    if result is auth:AuthError {
        test:assertEquals(result.detail().code, auth:TOKEN_MALFORMED);
    }
}

// ---- JWKS refresh gate: one fetch per interval, warm or cold -------------------------------------

@test:Config
function testColdJwksCacheFetchesOncePerInterval() returns error? {
    setJwksEmptyBody(true);
    resetJwksHits();
    do {
        // No usable keys, so the cache stays empty after each call: the gate must hold on a cold cache
        // too (an old `!empty &&` gate let every request in a start-up burst fetch).
        auth:JwksCache cold = check new ({url: "http://localhost:9591/jwks", minRefreshIntervalSeconds: 60});
        foreach int i in 0 ..< 4 {
            auth:Jwk[]|auth:AuthError keys = cold.keysFor("unknown-" + i.toString());
            test:assertTrue(keys is auth:AuthError && keys.detail().code == auth:KEYS_UNAVAILABLE);
        }
        test:assertEquals(jwksHitCount(), 1, "a cold cache must fetch once per interval, not once per request");
    } on fail error e {
        setJwksEmptyBody(false);
        return e;
    }
    setJwksEmptyBody(false);
}

// ---- A re-created Asgardeo account (new sub, same email) ---------------------------------------------

@test:Config
function testRecreatedAccountActsAsTheExistingEmployee() returns error? {
    http:Response first = check call("GET", "/me", check mint({sub: "emp-re-old", email: "Re.Person@wso2.com", name: "Re Person"}));
    test:assertEquals(first.statusCode, 200);
    test:assertEquals(check (check first.getJsonPayload()).employee.employeeId, "emp-re-old");
    int before = fakeEmployees.aliasCount();

    // Same person, new sub: no 409, and the history key stays the first one.
    string recreated = check mint({sub: "emp-re-new", email: "re.person@wso2.com", name: "Re Person"});
    http:Response second = check call("GET", "/me", recreated);
    test:assertEquals(second.statusCode, 200);
    test:assertEquals(check (check second.getJsonPayload()).employee.employeeId, "emp-re-old",
            "acts as the first employee id, so the ledger and standing are the same person's");
    test:assertEquals(fakeEmployees.aliasCount(), before + 1);
    test:assertTrue(fakeEmployees.findById("emp-re-new") is (), "no second employee row is made");

    // Idempotent: asking again, with the resolver's cache gone, adds nothing.
    lock {
        resolvedSubs.removeAll();
    }
    http:Response third = check call("GET", "/me", recreated);
    test:assertEquals(third.statusCode, 200);
    test:assertEquals(check (check third.getJsonPayload()).employee.employeeId, "emp-re-old");
    test:assertEquals(fakeEmployees.aliasCount(), before + 1);
    // And so does a route other than /me: the principal everywhere is the first id.
    http:Response points = check call("GET", "/me/points", recreated);
    test:assertEquals(points.statusCode, 200);
    test:assertEquals(check (check points.getJsonPayload()).standing.employeeId, "emp-re-old");
}

@test:Config
function testGenuineEmailClashIsATypedGenericConflict() returns error? {
    _ = check call("GET", "/me", check mint({sub: "emp-cl-a", email: "cl.a@wso2.com", name: "A"}));
    _ = check call("GET", "/me", check mint({sub: "emp-cl-b", email: "cl.b@wso2.com", name: "B"}));
    // b's account now claims a's email: two separate records, nothing to merge by guessing.
    string token = check mint({sub: "emp-cl-b", email: "cl.a@wso2.com", name: "B"});
    lock {
        resolvedSubs.removeAll();
    }
    foreach string path in ["/me", "/me/points"] {
        http:Response res = check call("GET", path, token);
        test:assertEquals(res.statusCode, 409, path);
        json body = check res.getJsonPayload();
        test:assertEquals(check body.code, "EMAIL_CONFLICT");
        string text = body.toJsonString();
        test:assertFalse(text.includes("cl.a") || text.includes("emp-cl-a") || text.includes("belongs to another"),
                "the body says nothing about the other record (no account-enumeration oracle): " + text);
    }
    // The clash is not cached: once the other record is out of the way the caller recovers on the next call.
    test:assertTrue(fakeEmployees.findByEmail("cl.a@wso2.com") is identity:Employee);
}

@test:Config
function testNewPersonAndKnownPersonAreUntouched() returns error? {
    int before = fakeEmployees.aliasCount();
    http:Response fresh = check call("GET", "/me", check mint({sub: "emp-plain-1", email: "plain.one@wso2.com", name: "P"}));
    test:assertEquals(check (check fresh.getJsonPayload()).employee.employeeId, "emp-plain-1");
    http:Response again = check call("GET", "/me", check mint({sub: "emp-plain-1", email: "plain.one@wso2.com", name: "P2"}));
    test:assertEquals(check (check again.getJsonPayload()).employee.displayName, "P2");
    test:assertEquals(fakeEmployees.aliasCount(), before, "no alias for an ordinary sign-in");
}

@test:Config
function testJwksUrlMustBeHttpsExceptOnALocalStack() {
    test:assertTrue(checkJwksUrl("prod", "https://gw.example.com/jwks") is ());
    test:assertTrue(checkJwksUrl("local", "http://localhost:9591/jwks") is ());
    test:assertTrue(checkJwksUrl("local", "http://127.0.0.1:9591/jwks") is ());
    test:assertTrue(checkJwksUrl("prod", "http://localhost:9591/jwks") is error);
    test:assertTrue(checkJwksUrl("prod", "http://gw.example.com/jwks") is error);
    test:assertTrue(checkJwksUrl("local", "http://gw.example.com/jwks") is error);
    test:assertTrue(checkJwksUrl("local", "http://localhost.evil.example/jwks") is error);
    test:assertTrue(checkJwksUrl("prod", "") is error);
}
