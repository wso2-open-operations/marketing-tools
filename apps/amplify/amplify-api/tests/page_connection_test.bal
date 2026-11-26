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

// The company page connection (admin, Community Management) and the native repost intent, on fakes: page states vs
// member states, the page admin check, tokens sealed as ORG, disconnect, status, and nativeStatus.

import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/http;
import ballerina/test;
import ballerina/time;

const string TEST_PAGE_REDIRECT_URI = "http://localhost:3000/amplify/admin/linkedin-page/callback";

isolated boolean pageAdmin = true;
isolated string[] pageRevoked = [];

function setPageAdmin(boolean value) {
    lock {
        pageAdmin = value;
    }
}

function pageRevokedSoFar() returns string[] {
    lock {
        return pageRevoked.clone();
    }
}

isolated class FakeCommunityPort {
    *linkedin:CommunityPort;

    public isolated function authorizationUrl(string state) returns string|linkedin:ProviderError =>
        "https://www.linkedin.com/oauth/v2/authorization?scope=r_organization_social_feed%20rw_organization_admin&state="
            + state;

    public isolated function exchangeCode(string code) returns linkedin:TokenGrant|linkedin:ProviderError =>
        {accessToken: "page-token-" + code, expiresInSeconds: 5184000, scopes: linkedin:PAGE_SCOPES,
            refreshToken: "page-refresh-" + code, refreshExpiresInSeconds: 31536000};

    public isolated function refresh(string refreshToken) returns linkedin:TokenGrant|linkedin:ProviderError =>
        error linkedin:ProviderError("not in api tests", code = linkedin:UNAVAILABLE, httpStatus = 503,
            serviceErrorCode = (), retryable = true);

    public isolated function revokeToken(string token) returns linkedin:ProviderError? {
        lock {
            pageRevoked.push(token);
        }
    }

    public isolated function isAdmin(string accessToken, string orgUrn) returns boolean|linkedin:ProviderError {
        lock {
            return pageAdmin;
        }
    }

    public isolated function listReactions(string accessToken, string entityUrn, int 'start, int count)
            returns linkedin:ReactionPage|linkedin:ProviderError => {items: [], fetched: 0};

    public isolated function listComments(string accessToken, string entityUrn, int 'start, int count)
            returns linkedin:CommentPage|linkedin:ProviderError => {items: [], fetched: 0};

    public isolated function listShareNotifications(string accessToken, string orgUrn, int startMs, int endMs,
            int 'start = 0, int count = 50) returns linkedin:NotificationPage|linkedin:ProviderError =>
        {items: [], fetched: 0};
}

isolated class FakeOrgConnections {
    *connection:OrgConnectionRepository;
    private map<connection:OrgConnection> rows = {};
    private connection:OrgConnectionChange[] changes = [];

    public isolated function find(types:Provider provider, string orgUrn) returns connection:OrgConnection|error? {
        lock {
            return self.rows[orgUrn].clone();
        }
    }

    public isolated function findActive(types:Provider provider) returns connection:OrgConnection|error? {
        lock {
            foreach connection:OrgConnection c in self.rows {
                if c.revokedAt is () {
                    return c.clone();
                }
            }
            return ();
        }
    }

    public isolated function save(connection:OrgConnectionChange change, int? expectedVersion) returns error? {
        lock {
            connection:OrgConnection? existing = self.rows[change.connection.orgUrn];
            int? current = existing is () ? () : existing.version;
            if current != expectedVersion {
                return error("version conflict");
            }
            self.rows[change.connection.orgUrn] = change.connection.clone();
            self.changes.push(change.clone());
        }
    }

    isolated function lastChange() returns connection:OrgConnectionChange? {
        lock {
            return self.changes.length() == 0 ? () : self.changes[self.changes.length() - 1].clone();
        }
    }
}

isolated class FakeNativeIntents {
    *sharing:NativeIntentRepository;
    private map<sharing:NativeIntent> rows = {};

    public isolated function open(types:EmployeeId employeeId, string campaignId, time:Utc now)
            returns sharing:NativeIntent|error {
        lock {
            string key = employeeId + "|" + campaignId;
            sharing:NativeIntent? existing = self.rows[key];
            sharing:NativeIntent next = existing is sharing:NativeIntent && existing.detectedAt !is ()
                ? existing.clone() : {employeeId, campaignId, openedAt: now, detectedAt: ()};
            self.rows[key] = next.clone();
            return next.clone();
        }
    }

    public isolated function ofEmployee(types:EmployeeId employeeId) returns sharing:NativeIntent[]|error {
        sharing:NativeIntent[] all;
        lock {
            all = self.rows.toArray().clone();
        }
        return from sharing:NativeIntent i in all where i.employeeId == employeeId select i;
    }

    isolated function put(sharing:NativeIntent intent) {
        lock {
            self.rows[intent.employeeId + "|" + intent.campaignId] = intent.clone();
        }
    }
}

final FakeCommunityPort fakeCommunity = new;
final FakeOrgConnections fakeOrgConnections = new;
final FakeNativeIntents fakeNativeIntents = new;

@test:Mock {functionName: "communityProvider"}
isolated function mockCommunityProvider() returns linkedin:CommunityPort? => fakeCommunity;

@test:Mock {functionName: "pageRedirectUri"}
isolated function mockPageRedirectUri() returns string => TEST_PAGE_REDIRECT_URI;

@test:Mock {functionName: "orgConnectionRepository"}
isolated function mockOrgConnectionRepository(store:Actor actor) returns connection:OrgConnectionRepository|error =>
    fakeOrgConnections;

@test:Mock {functionName: "nativeIntentRepository"}
isolated function mockNativeIntentRepository() returns sharing:NativeIntentRepository|error => fakeNativeIntents;

@test:Mock {functionName: "apiCallsToday"}
isolated function mockApiCallsToday() returns int|error => 12;

const string SCORED_CAMPAIGN = "0192f0e0-0000-7000-8000-00000000e001";

@test:Mock {functionName: "resharePoints"}
isolated function mockResharePoints(types:EmployeeId employeeId, string[] campaignIds) returns map<int>|error {
    // The detected reshare of SCORED_CAMPAIGN earned 5; anything else isn't scored yet.
    map<int> found = {};
    foreach string id in campaignIds {
        if id == SCORED_CAMPAIGN {
            found[id] = 5;
        }
    }
    return found;
}

@test:Mock {functionName: "engagementLastSyncAt"}
isolated function mockEngagementLastSyncAt() returns time:Utc|error? => [1795000000, 0];

function admin(string sub) returns string|error => mint({sub, email: sub + "@wso2.com", name: sub, groups: [ADMIN_GROUP]});

@test:Config {groups: ["page"]}
function testPageConnectIsForAdminsAndChecksThePageRole() returns error? {
    string emp = check employee("emp-page-1");
    http:Response denied = check send("POST", "/admin/linkedin-page/connect/start", (), emp);
    test:assertEquals(denied.statusCode, 403, "an employee can't connect the page");

    string adm = check admin("adm-page-1");
    http:Response started = check send("POST", "/admin/linkedin-page/connect/start", (), adm);
    test:assertEquals(started.statusCode, 200);
    check assertShape(started, "ConnectAuthorization");
    json body = check started.getJsonPayload();
    string state = (check body.state).toString();
    test:assertTrue((check body.authorizationUrl).toString().includes("rw_organization_admin"));

    // A page state never completes a member connect.
    http:Response asMember = check send("POST", "/connections/linkedin/complete",
            {code: "c-pg", state, redirectUri: TEST_REDIRECT_URI}, adm);
    test:assertEquals(asMember.statusCode, 409);
    test:assertEquals(check codeIn(asMember), "OAUTH_STATE_INVALID");

    // ... and a member state never completes a page connect.
    string memberState = check stateOf(check send("POST", "/connections/linkedin/start", {}, adm));
    http:Response asPage = check send("POST", "/admin/linkedin-page/connect/complete",
            {code: "c-pg", state: memberState, redirectUri: TEST_PAGE_REDIRECT_URI}, adm);
    test:assertEquals(check codeIn(asPage), "OAUTH_STATE_INVALID");

    // Wrong callback page.
    string s2 = check stateOf(check send("POST", "/admin/linkedin-page/connect/start", (), adm));
    http:Response wrongPage = check send("POST", "/admin/linkedin-page/connect/complete",
            {code: "c-pg", state: s2, redirectUri: TEST_REDIRECT_URI}, adm);
    test:assertEquals(check codeIn(wrongPage), "OAUTH_REDIRECT_MISMATCH");

    // Not an administrator of the page: 403, and the token goes back to LinkedIn.
    setPageAdmin(false);
    string s3 = check stateOf(check send("POST", "/admin/linkedin-page/connect/start", (), adm));
    http:Response notAdmin = check send("POST", "/admin/linkedin-page/connect/complete",
            {code: "c-nope", state: s3, redirectUri: TEST_PAGE_REDIRECT_URI}, adm);
    setPageAdmin(true);
    test:assertEquals(notAdmin.statusCode, 403);
    test:assertEquals(check codeIn(notAdmin), "NOT_PAGE_ADMIN");
    test:assertTrue(pageRevokedSoFar().indexOf("page-token-c-nope") !is ());
}

@test:Config {groups: ["page"], dependsOn: [testPageConnectIsForAdminsAndChecksThePageRole]}
function testPageConnectStatusAndDisconnect() returns error? {
    string adm = check admin("adm-page-2");
    string state = check stateOf(check send("POST", "/admin/linkedin-page/connect/start", (), adm));
    http:Response done = check send("POST", "/admin/linkedin-page/connect/complete",
            {code: "c-ok", state, redirectUri: TEST_PAGE_REDIRECT_URI}, adm);
    test:assertEquals(done.statusCode, 200);
    check assertShape(done, "LinkedInPage");
    json body = check done.getJsonPayload();
    test:assertEquals(check body.connected, true);
    test:assertEquals(check body.connectedByName, "Name adm-page-2");
    test:assertEquals(check body.callsToday, 12);
    test:assertEquals(check body.dailyBudget, 450);
    test:assertFalse(body.toJsonString().includes("page-token"), "no token reaches the caller");

    connection:OrgConnectionChange change = <connection:OrgConnectionChange>fakeOrgConnections.lastChange();
    test:assertEquals(change.tokensToInsert.length(), 2, "access and refresh rows");
    foreach connection:StoredToken t in change.tokensToInsert {
        test:assertEquals(t.ownerType, "ORG");
        test:assertEquals(t.ownerId, "urn:li:organization:1477");
        test:assertEquals(check connection:openToken(testCipher, t) == "page-token-c-ok"
            || check connection:openToken(testCipher, t) == "page-refresh-c-ok", true);
    }
    test:assertEquals(change.auditAction, connection:ORG_CONNECTED);

    http:Response status = check send("GET", "/admin/linkedin-page", (), adm);
    test:assertEquals(status.statusCode, 200);
    check assertShape(status, "LinkedInPage");
    test:assertEquals(check (check status.getJsonPayload()).lastSyncAt, "2026-11-18T11:06:40Z");

    // Reconnect replaces the rows.
    string again = check stateOf(check send("POST", "/admin/linkedin-page/connect/start", (), adm));
    test:assertEquals((check send("POST", "/admin/linkedin-page/connect/complete",
            {code: "c-ok2", state: again, redirectUri: TEST_PAGE_REDIRECT_URI}, adm)).statusCode, 200);
    test:assertEquals((<connection:OrgConnectionChange>fakeOrgConnections.lastChange()).tokensToDelete.length(), 2);

    // Disconnect: revoke at LinkedIn (the fake token repository has no row, so nothing to open), rows deleted.
    http:Response gone = check send("DELETE", "/admin/linkedin-page", (), adm);
    test:assertEquals(gone.statusCode, 204);
    connection:OrgConnectionChange revoked = <connection:OrgConnectionChange>fakeOrgConnections.lastChange();
    test:assertEquals(revoked.auditAction, connection:ORG_CONNECTION_REVOKED);
    test:assertEquals(revoked.tokensToDelete.length(), 2);
    json after = check (check send("GET", "/admin/linkedin-page", (), adm)).getJsonPayload();
    test:assertEquals(check after.connected, false);
    test:assertEquals(check after.lastSyncAt, "2026-11-18T11:06:40Z", "the last sync shows even when disconnected");
    test:assertEquals((check send("DELETE", "/admin/linkedin-page", (), adm)).statusCode, 204, "idempotent");
}

@test:Config {groups: ["page"]}
function testNativeIntentAndStatus() returns error? {
    string id = check registered("urn:li:share:9250", check po());
    string emp = check employee("emp-native-1");
    http:Response clicked = check send("POST", string `/campaigns/${id}/native-intent`, (), emp);
    test:assertEquals(clicked.statusCode, 200);
    check assertShape(clicked, "NativeIntent");
    test:assertEquals(check (check clicked.getJsonPayload()).nativeStatus, "LOOKING");
    test:assertEquals(check (check clicked.getJsonPayload()).points, (), "nothing found yet");
    test:assertEquals((check send("POST", string `/campaigns/${SAMPLE_UUID}/native-intent`, (), emp)).statusCode, 404);

    // A day-old click not seen, and one the sync detected.
    time:Utc now = time:utcNow();
    fakeNativeIntents.put({employeeId: "emp-native-1", campaignId: SAMPLE_UUID,
        openedAt: time:utcAddSeconds(now, -86400), detectedAt: ()});
    fakeNativeIntents.put({employeeId: "emp-native-1", campaignId: SCORED_CAMPAIGN,
        openedAt: time:utcAddSeconds(now, -600), detectedAt: now});
    fakeNativeIntents.put({employeeId: "emp-native-1", campaignId: "0192f0e0-0000-7000-8000-00000000e002",
        openedAt: time:utcAddSeconds(now, -600), detectedAt: now});
    http:Response mine = check send("GET", "/me/native-intents", (), emp);
    test:assertEquals(mine.statusCode, 200);
    check assertShape(mine, "NativeIntentList");
    json[] items = check (check (check mine.getJsonPayload()).items).ensureType();
    map<string> byCampaign = {};
    map<json> pointsOf = {};
    foreach json i in items {
        byCampaign[(check i.campaignId).toString()] = (check i.nativeStatus).toString();
        pointsOf[(check i.campaignId).toString()] = check i.points;
    }
    test:assertEquals(pointsOf[SCORED_CAMPAIGN], 5, "found and scored: the points it earned");
    test:assertEquals(pointsOf["0192f0e0-0000-7000-8000-00000000e002"], (), "found, not scored yet");
    test:assertEquals(pointsOf[SAMPLE_UUID], (), "not found");
    test:assertEquals(byCampaign[id], "LOOKING");
    test:assertEquals(byCampaign[SAMPLE_UUID], "NOT_FOUND");
    test:assertEquals(byCampaign[SCORED_CAMPAIGN], "DETECTED");
}
