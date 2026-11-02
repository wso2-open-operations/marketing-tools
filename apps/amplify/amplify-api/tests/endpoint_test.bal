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


// Endpoint tests on the in-memory fakes with the M4 test JWTs: S1, C1, S3, C2 main flows, stable codes,
// idempotent replay, validation, and response shapes against openapi.yaml.

import amplify_common.types;

import ballerina/http;
import ballerina/http.httpscerr;
import ballerina/sql;
import ballerina/test;
import ballerina/time;

const string WSO2_PAGE = "urn:li:organization:1477";

function send(string method, string path, json body, string token, map<string> extra = {}) returns http:Response|error {
    map<string> headers = {"x-jwt-assertion": token};
    foreach [string, string] [k, v] in extra.entries() {
        headers[k] = v;
    }
    return api->execute(method, path, method == "GET" ? () : body, headers);
}

function po() returns string|error => mint({sub: "po-0001", email: "po@wso2.com", groups: [PO_GROUP]});

function employee(string sub) returns string|error => mint({sub, email: sub + "@wso2.com", name: sub});

function codeIn(http:Response res) returns string|error => (check (check res.getJsonPayload()).code).toString();

function connect(string employeeId) {
    time:Utc now = time:utcNow();
    fakeConnections.put({
        employeeId,
        provider: types:LINKEDIN,
        memberUrn: "urn:li:person:" + employeeId,
        providerApi: types:SHARE_ON_LINKEDIN,
        scopes: ["w_member_social"],
        currentToken: {tokenId: "t-" + employeeId, issuedOn: "2026-10-16"},
        accessExpiresAt: types:addDays(now, 30),
        connectedAt: now,
        revokedAt: (),
        removedAt: (),
        lastRemindedAt: (),
        version: 1
    });
}

function registerBody(string urn) returns json => {
    resourceUrn: urn,
    ownerUrn: WSO2_PAGE,
    title: "WSO2 at KubeCon",
    categoryCode: "PRODUCT",
    tags: ["Kubernetes", "Events"]
};

@test:Config
function testRegisterCampaignIsIdempotentAndShaped() returns error? {
    string token = check po();
    json body = registerBody("urn:li:share:9001");
    http:Response first = check send("POST", "/campaigns?shareNow=true", body, token, {"Idempotency-Key": "reg-1"});
    test:assertEquals(first.statusCode, 201);
    check assertShape(first, "CampaignRegistration");
    json created = check first.getJsonPayload();
    test:assertEquals(check created.run, "DEFERRED", "shareNow is fire-and-forget and non-fatal");
    test:assertEquals(check created.campaign.tags, ["kubernetes", "events"]);
    int inserts = fakeCampaigns.insertCount();

    http:Response replay = check send("POST", "/campaigns?shareNow=true", body, token, {"Idempotency-Key": "reg-1"});
    test:assertEquals(replay.statusCode, 201);
    test:assertEquals(replay.getHeader("Idempotent-Replayed"), "true");
    test:assertEquals(check replay.getJsonPayload(), created);
    test:assertEquals(fakeCampaigns.insertCount(), inserts, "a replay never registers twice");

    http:Response reused = check send("POST", "/campaigns", registerBody("urn:li:share:9002"), token,
            {"Idempotency-Key": "reg-1"});
    test:assertEquals(reused.statusCode, 422);
    test:assertEquals(check codeIn(reused), "IDEMPOTENCY_KEY_REUSED");

    http:Response dup = check send("POST", "/campaigns", body, token);
    test:assertEquals(dup.statusCode, 409);
    test:assertEquals(check codeIn(dup), "CAMPAIGN_ALREADY_REGISTERED");

    http:Response notWso2 = check send("POST", "/campaigns", {resourceUrn: "urn:li:share:9003",
        ownerUrn: "urn:li:organization:42", title: "x", categoryCode: "PRODUCT"}, token);
    test:assertEquals(notWso2.statusCode, 422);
    test:assertEquals(check codeIn(notWso2), "NOT_WSO2_RESOURCE");

    http:Response unknownField = check send("POST", "/campaigns", {resourceUrn: "urn:li:share:9004", ownerUrn: WSO2_PAGE,
        title: "x", categoryCode: "PRODUCT", hack: true}, token);
    test:assertEquals(unknownField.statusCode, 400);
    test:assertEquals(check codeIn(unknownField), "VALIDATION_FAILED");
}

@test:Config {dependsOn: [testRegisterCampaignIsIdempotentAndShaped]}
function testEmployeeListsAndSharesWithStableCodes() returns error? {
    string emp = check employee("emp-share-1");
    http:Response list = check send("GET", "/campaigns", (), emp);
    test:assertEquals(list.statusCode, 200);
    check assertShape(list, "CampaignPage");
    json page = check list.getJsonPayload();
    json[] items = check page.items.ensureType();
    test:assertTrue(items.length() > 0);
    string id = (check items[0].id).toString();

    http:Response one = check send("GET", "/campaigns/" + id, (), emp);
    check assertShape(one, "Campaign");

    http:Response anyStatus = check send("GET", "/campaigns?status=all", (), emp);
    test:assertEquals(anyStatus.statusCode, 400, "employees list open campaigns only");

    http:Response notConnected = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"}, emp);
    test:assertEquals(notConnected.statusCode, 409);
    test:assertEquals(check codeIn(notConnected), "LINKEDIN_NOT_CONNECTED");

    connect("emp-share-1");
    http:Response badKind = check send("POST", string `/campaigns/${id}/shares`, {kind: "LIKE"}, emp);
    test:assertEquals(badKind.statusCode, 400);
    http:Response queued = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"}, emp);
    test:assertEquals(queued.statusCode, 202);
    check assertShape(queued, "Share");
    test:assertEquals(check (check queued.getJsonPayload()).status, "QUEUED");

    http:Response again = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"}, emp);
    test:assertEquals(again.statusCode, 409);
    test:assertEquals(check codeIn(again), "DUPLICATE_ACTION");

    http:Response missing = check send("POST", string `/campaigns/${SAMPLE_UUID}/shares`, {kind: "REPOST"}, emp);
    test:assertEquals(missing.statusCode, 404);
    http:Response badId = check send("POST", "/campaigns/not-a-uuid/shares", {kind: "REPOST"}, emp);
    test:assertEquals(badId.statusCode, 400);
}

@test:Config
function testExternalShareAcceptsJustThePostNumber() returns error? {
    string claimant = check employee("emp-ext-num-1");
    http:Response claimed = check send("POST", "/external-shares",
            {activityId: " 7123456789012340001 ", certified: true}, claimant);
    test:assertEquals(claimed.statusCode, 201);
    check assertShape(claimed, "ExternalShare");
    json body = check claimed.getJsonPayload();
    test:assertEquals(check body.evidenceUrl, "https://www.linkedin.com/feed/update/urn:li:activity:7123456789012340001",
            "the canonical post URL is what is stored");
    test:assertEquals(check body.evidenceProvider, "linkedin");

    // The same post by its full URL, from someone else: one claim per post.
    http:Response sameByUrl = check send("POST", "/external-shares",
            {evidenceUrl: "https://www.linkedin.com/posts/avery_x-activity-7123456789012340001-AbCd", certified: true},
            check employee("emp-ext-num-2"));
    test:assertEquals(sameByUrl.statusCode, 409);
    test:assertEquals(check codeIn(sameByUrl), "EVIDENCE_ALREADY_CLAIMED");
    // And by the number again.
    http:Response sameByNumber = check send("POST", "/external-shares",
            {activityId: "7123456789012340001", certified: true}, check employee("emp-ext-num-3"));
    test:assertEquals(sameByNumber.statusCode, 409);

    // The full URL still works on its own; both or neither is a 400; a bad number is a 422.
    http:Response urlOnly = check send("POST", "/external-shares",
            {evidenceUrl: "https://medium.com/@emp/by-url-only", certified: true}, check employee("emp-ext-num-4"));
    test:assertEquals(urlOnly.statusCode, 201);
    http:Response both = check send("POST", "/external-shares",
            {evidenceUrl: "https://medium.com/@emp/both", activityId: "7123456789012340002", certified: true}, claimant);
    test:assertEquals(both.statusCode, 400);
    test:assertEquals(check codeIn(both), "VALIDATION_FAILED");
    http:Response neither = check send("POST", "/external-shares", {certified: true}, claimant);
    test:assertEquals(neither.statusCode, 400);
    http:Response letters = check send("POST", "/external-shares", {activityId: "12ab", certified: true}, claimant);
    test:assertEquals(letters.statusCode, 422);
    test:assertEquals(check codeIn(letters), "INVALID_EVIDENCE_URL");
}

@test:Config
function testExternalShareRefusesLnkdInShortLinks() returns error? {
    http:Response res = check send("POST", "/external-shares",
            {evidenceUrl: "https://lnkd.in/eAbCdEf", certified: true}, check employee("emp-ext-lnkd"));
    test:assertEquals(res.statusCode, 422);
    test:assertEquals(check codeIn(res), "INVALID_EVIDENCE_URL");
}

@test:Config
function testExternalShareApproveAndAmplifyAwardPoints() returns error? {
    string claimant = check employee("emp-ext-1");
    http:Response claimed = check send("POST", "/external-shares",
            {evidenceUrl: "https://medium.com/@emp/why-wso2?utm_source=x", certified: true}, claimant);
    test:assertEquals(claimed.statusCode, 201);
    check assertShape(claimed, "ExternalShare");
    string id = (check (check claimed.getJsonPayload()).id).toString();

    http:Response taken = check send("POST", "/external-shares",
            {evidenceUrl: "https://medium.com/@emp/why-wso2/", certified: true}, check employee("emp-ext-2"));
    test:assertEquals(taken.statusCode, 409);
    test:assertEquals(check codeIn(taken), "EVIDENCE_ALREADY_CLAIMED");

    http:Response uncertified = check send("POST", "/external-shares",
            {evidenceUrl: "https://example.org/a", certified: false}, claimant);
    test:assertEquals(uncertified.statusCode, 422);

    string token = check po();
    http:Response early = check send("POST", string `/po/external-shares/${id}/amplified`, (), token);
    test:assertEquals(check codeIn(early), "NOT_APPROVED");
    http:Response approved = check send("POST", string `/po/external-shares/${id}/approve`, (), token);
    test:assertEquals(approved.statusCode, 200);
    test:assertEquals(check (check approved.getJsonPayload()).status, "APPROVED");
    http:Response amplified = check send("POST", string `/po/external-shares/${id}/amplified`, (), token);
    test:assertEquals(check (check amplified.getJsonPayload()).status, "AMPLIFIED");
    types:LedgerEntry[] awards = fakeExternalShares.awardRows();
    test:assertEquals(awards.length(), 2);
    test:assertEquals(awards[1].points, 15, "T4 top-up = OWN_POST_AMPLIFIED − OWN_POST");

    http:Response noReason = check send("POST", string `/po/external-shares/${id}/reject`, {reason: " "}, token);
    test:assertTrue(noReason.statusCode == 409 || noReason.statusCode == 422);
}

@test:Config
function testAdjustAndReverse() returns error? {
    // The target must exist: GET /me records the employee.
    _ = check send("GET", "/me", (), check employee("emp-adj-1"));
    string token = check po();
    http:Response adjusted = check send("POST", "/po/points/adjustments",
            {employeeId: "emp-adj-1", points: 10, reason: "Missed share during outage"}, token, {"Idempotency-Key": "adj-1"});
    test:assertEquals(adjusted.statusCode, 201);
    check assertShape(adjusted, "LedgerEntry");
    string reference = (check (check adjusted.getJsonPayload()).reference).toString();

    http:Response unknown = check send("POST", "/po/points/adjustments",
            {employeeId: "nobody", points: 10, reason: "x"}, token);
    test:assertEquals(unknown.statusCode, 404);

    http:Response reversed = check send("POST", string `/po/points/${reference}/reverse`, {reason: "Duplicate"}, token);
    test:assertEquals(reversed.statusCode, 201);
    test:assertEquals(check (check reversed.getJsonPayload()).points, -10);
    http:Response twice = check send("POST", string `/po/points/${reference}/reverse`, {reason: "Again"}, token);
    test:assertEquals(check codeIn(twice), "ALREADY_REVERSED");

    http:Response asEmployee = check send("POST", "/po/points/adjustments",
            {employeeId: "emp-adj-1", points: 10, reason: "x"}, check employee("emp-adj-2"));
    test:assertEquals(asEmployee.statusCode, 403);
}

@test:Config
function testSettingsValidation() returns error? {
    string admin = check mint({groups: [ADMIN_GROUP]});
    http:Response unknown = check send("PUT", "/admin/settings", {changes: [{key: "coin.rate", value: 1, version: 1}]}, admin);
    test:assertEquals(check codeIn(unknown), "UNKNOWN_SETTING");
    http:Response bad = check send("PUT", "/admin/settings", {changes: [{key: "leaderboard.top_n", value: 0, version: 1}]},
            admin);
    test:assertEquals(check codeIn(bad), "INVALID_SETTING");
}

@test:Config
function testOversizedBodyIsProblemDetailsBeforeBinding() returns error? {
    // HTTP/1.1 with chunking off, so the request declares its `Content-Length`: the API answers it before the
    // payload is read (and hashed for idempotency), as problem details.
    http:Client h1 = check new (string `http://localhost:${port}`,
            {httpVersion: http:HTTP_1_1, http1Settings: {chunking: http:CHUNKING_NEVER}, cache: {enabled: false}});
    http:Response res = check h1->post("/campaigns", {summary: "a".padEnd(70000, "a")},
            {"x-jwt-assertion": check po()});
    test:assertEquals(res.statusCode, 413);
    test:assertEquals(res.getContentType(), "application/problem+json");
    json body = check res.getJsonPayload();
    test:assertEquals(check body.status, 413);
    test:assertEquals(check body.code, "PAYLOAD_TOO_LARGE");
    test:assertTrue((check body.detail).toString().includes("65536"), "the detail names the limit");
    test:assertTrue(res.getHeader("X-Correlation-ID") is string, "the security interceptor still runs");
}

// A chunked body has no Content-Length, so BodyLimitInterceptor cannot see it; the listener's own limit
// (`MAX_ENTITY_BODY_BYTES`) refuses it. The listener answers that 413 itself, before any interceptor runs, so it
// carries no problem+json body: the status is what is pinned here (it must never be a 500).
@test:Config
function testChunkedOverLimitBodyIsRefusedWith413() returns error? {
    http:Client h1 = check new (string `http://localhost:${port}`,
            {httpVersion: http:HTTP_1_1, http1Settings: {chunking: http:CHUNKING_ALWAYS}, cache: {enabled: false}});
    byte[] chunk = "a".padEnd(1024, "a").toBytes();
    byte[][] chunks = [];
    foreach int i in 0 ..< 300 {
        chunks.push(chunk);
    }
    http:Request req = new;
    req.setByteStream(chunks.toStream(), "application/json");
    req.setHeader("x-jwt-assertion", check po());
    http:Response res = check h1->post("/campaigns", req);
    test:assertEquals(res.statusCode, 413, "an over-limit chunked body is 413, never 500");
}

@test:Config
function testPayloadTooLargeErrorMapsToProblemDetails() returns error? {
    httpscerr:PayloadTooLargeError err = error httpscerr:PayloadTooLargeError("Entity too large");
    http:RequestContext ctx = new;
    http:Response res = errorResponse(ctx, err);
    test:assertEquals(res.statusCode, 413);
    test:assertEquals(res.getContentType(), "application/problem+json");
    json body = check res.getJsonPayload();
    test:assertEquals(check body.code, "PAYLOAD_TOO_LARGE");
}

@test:Config
function testLoggedDatabaseErrorsCarryKindAndSqlStateOnly() {
    sql:DatabaseError dbErr = error sql:DatabaseError("ERROR: duplicate key\nDetail: Key (email)=(ada@wso2.com) exists",
            sqlState = "23505", errorCode = 0);
    test:assertEquals(errorKind(dbErr), "sql:DatabaseError");
    test:assertEquals(sqlStateOf(dbErr), "23505");
    test:assertEquals(errorKind(error("boom")), "error");
    test:assertEquals(sqlStateOf(error("boom")), ());
}
