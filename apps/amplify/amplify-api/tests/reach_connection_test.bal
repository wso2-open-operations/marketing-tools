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


// The Reach connection (post analytics, #1781) on fakes: Reach states vs member and page states, the member callback
// page, the scope check, tokens sealed as MEMBER_ANALYTICS, status and disconnect.

import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.store;

import ballerina/http;
import ballerina/test;

isolated string[] reachRevoked = [];

function reachRevokedSoFar() returns string[] {
    lock {
        return reachRevoked.clone();
    }
}

isolated class FakeReachPort {
    *linkedin:MemberAnalyticsPort;

    public isolated function memberAuthorizationUrl(string state, string redirectUri)
            returns string|linkedin:ProviderError =>
        "https://www.linkedin.com/oauth/v2/authorization?scope=r_member_postAnalytics&redirect_uri=" + redirectUri
            + "&state=" + state;

    public isolated function exchangeMemberCode(string code, string redirectUri)
            returns linkedin:TokenGrant|linkedin:ProviderError =>
        code == "c-noscope" ? {accessToken: "reach-token-" + code, expiresInSeconds: 5184000, scopes: ["openid"]}
            : {accessToken: "reach-token-" + code, expiresInSeconds: 5184000, scopes: linkedin:REACH_SCOPES,
                refreshToken: "reach-refresh-" + code, refreshExpiresInSeconds: 31536000};

    public isolated function refresh(string refreshToken) returns linkedin:TokenGrant|linkedin:ProviderError =>
        error linkedin:ProviderError("not in api tests", code = linkedin:UNAVAILABLE, httpStatus = 503,
            serviceErrorCode = (), retryable = true);

    public isolated function revokeToken(string token) returns linkedin:ProviderError? {
        lock {
            reachRevoked.push(token);
        }
    }

    public isolated function memberPostMetric(string accessToken, string postUrn, linkedin:AnalyticsMetric metric)
            returns int|linkedin:ProviderError => 0;
}

isolated class FakeReachConnections {
    *connection:ReachConnectionRepository;
    private map<connection:ReachConnection> rows = {};
    private connection:ReachChange[] changes = [];
    private string[] deleted = [];

    public isolated function find(types:EmployeeId employeeId) returns connection:ReachConnection|error? {
        lock {
            return self.rows[employeeId].clone();
        }
    }

    public isolated function save(connection:ReachChange change, int? expectedVersion) returns error? {
        lock {
            connection:ReachConnection? existing = self.rows[change.connection.employeeId];
            int? current = existing is () ? () : existing.version;
            if current != expectedVersion {
                return store:versionConflict("reach connection");
            }
            self.rows[change.connection.employeeId] = change.connection.clone();
            self.changes.push(change.clone());
        }
    }

    public isolated function delete(connection:ReachConnection existing) returns boolean|error {
        lock {
            self.deleted.push(existing.employeeId);
            return self.rows.removeIfHasKey(existing.employeeId) is connection:ReachConnection;
        }
    }

    isolated function lastChange() returns connection:ReachChange? {
        lock {
            return self.changes.length() == 0 ? () : self.changes[self.changes.length() - 1].clone();
        }
    }

    isolated function deletedSoFar() returns string[] {
        lock {
            return self.deleted.clone();
        }
    }
}

final FakeReachPort fakeReach = new;
final FakeReachConnections fakeReachConnections = new;

@test:Mock {functionName: "reachProvider"}
isolated function mockReachProvider() returns linkedin:MemberAnalyticsPort? => fakeReach;

@test:Mock {functionName: "reachConnectionRepository"}
isolated function mockReachConnectionRepository(store:Actor actor) returns connection:ReachConnectionRepository|error =>
    fakeReachConnections;

@test:Config {groups: ["reach"]}
function testReachStatesAreTheirOwnFlow() returns error? {
    string emp = check employee("emp-reach-1");
    http:Response started = check send("POST", "/me/connections/reach/start", (), emp);
    test:assertEquals(started.statusCode, 200);
    check assertShape(started, "ConnectAuthorization");
    json body = check started.getJsonPayload();
    string state = (check body.state).toString();
    test:assertTrue(state.startsWith("reach-"), "the callback page routes on the prefix");
    string url = (check body.authorizationUrl).toString();
    test:assertTrue(url.includes("r_member_postAnalytics"));
    test:assertTrue(url.includes(TEST_REDIRECT_URI), "back to the member callback page");

    // A Reach state never completes a member or a page connect ...
    http:Response asMember = check send("POST", "/connections/linkedin/complete",
            {code: "c-r", state, redirectUri: TEST_REDIRECT_URI}, emp);
    test:assertEquals(check codeIn(asMember), "OAUTH_STATE_INVALID");
    string adm = check admin("adm-reach-1");
    string reachOfAdmin = check stateOf(check send("POST", "/me/connections/reach/start", (), adm));
    http:Response asPage = check send("POST", "/admin/linkedin-page/connect/complete",
            {code: "c-r", state: reachOfAdmin, redirectUri: TEST_PAGE_REDIRECT_URI}, adm);
    test:assertEquals(check codeIn(asPage), "OAUTH_STATE_INVALID");

    // ... and neither a member nor a page state completes Reach.
    string memberState = check stateOf(check send("POST", "/connections/linkedin/start", {}, emp));
    http:Response fromMember = check send("POST", "/me/connections/reach/complete",
            {code: "c-r", state: memberState, redirectUri: TEST_REDIRECT_URI}, emp);
    test:assertEquals(fromMember.statusCode, 409);
    test:assertEquals(check codeIn(fromMember), "OAUTH_STATE_INVALID");
    string pageState = check stateOf(check send("POST", "/admin/linkedin-page/connect/start", (), adm));
    http:Response fromPage = check send("POST", "/me/connections/reach/complete",
            {code: "c-r", state: pageState, redirectUri: TEST_REDIRECT_URI}, adm);
    test:assertEquals(check codeIn(fromPage), "OAUTH_STATE_INVALID");

    // Wrong callback page.
    string s2 = check stateOf(check send("POST", "/me/connections/reach/start", (), emp));
    http:Response wrongPage = check send("POST", "/me/connections/reach/complete",
            {code: "c-r", state: s2, redirectUri: TEST_PAGE_REDIRECT_URI}, emp);
    test:assertEquals(check codeIn(wrongPage), "OAUTH_REDIRECT_MISMATCH");

    // A grant without the analytics scope goes back to LinkedIn.
    string s3 = check stateOf(check send("POST", "/me/connections/reach/start", (), emp));
    http:Response noScope = check send("POST", "/me/connections/reach/complete",
            {code: "c-noscope", state: s3, redirectUri: TEST_REDIRECT_URI}, emp);
    test:assertEquals(noScope.statusCode, 422);
    test:assertEquals(check codeIn(noScope), "REACH_SCOPE_MISSING");
    test:assertTrue(reachRevokedSoFar().indexOf("reach-token-c-noscope") !is ());
}

@test:Config {groups: ["reach"], dependsOn: [testReachStatesAreTheirOwnFlow]}
function testReachConnectStatusAndDisconnect() returns error? {
    string emp = check employee("emp-reach-2");
    json before = check (check send("GET", "/me/connections/reach", (), emp)).getJsonPayload();
    test:assertEquals(before, {connected: false, status: "NOT_CONNECTED", connectedAt: (), accessExpiresAt: ()});

    string state = check stateOf(check send("POST", "/me/connections/reach/start", (), emp));
    http:Response done = check send("POST", "/me/connections/reach/complete",
            {code: "c-ok", state, redirectUri: TEST_REDIRECT_URI}, emp);
    test:assertEquals(done.statusCode, 200);
    check assertShape(done, "ReachConnection");
    json body = check done.getJsonPayload();
    test:assertEquals(check body.connected, true);
    test:assertEquals(check body.status, "CONNECTED");
    test:assertFalse(body.toJsonString().includes("reach-token"), "no token reaches the caller");

    connection:ReachChange change = <connection:ReachChange>fakeReachConnections.lastChange();
    test:assertEquals(change.connection.employeeId, "emp-reach-2", "the caller, from the token");
    test:assertEquals(change.tokensToInsert.length(), 2);
    foreach connection:StoredToken t in change.tokensToInsert {
        test:assertEquals(t.ownerType, "MEMBER_ANALYTICS");
        test:assertEquals(t.ownerId, "emp-reach-2");
    }
    test:assertEquals(check connection:openToken(testCipher, change.tokensToInsert[0]), "reach-token-c-ok");
    test:assertEquals(change.auditAction, connection:REACH_CONNECTED_AUDIT);

    http:Response status = check send("GET", "/me/connections/reach", (), emp);
    check assertShape(status, "ReachConnection");

    // Reconnect replaces the rows.
    string again = check stateOf(check send("POST", "/me/connections/reach/start", (), emp));
    test:assertEquals((check send("POST", "/me/connections/reach/complete",
            {code: "c-ok2", state: again, redirectUri: TEST_REDIRECT_URI}, emp)).statusCode, 200);
    test:assertEquals((<connection:ReachChange>fakeReachConnections.lastChange()).tokensToDelete.length(), 2);

    // Disconnect deletes the row (the fake token repository has no row, so nothing is revoked); idempotent.
    test:assertEquals((check send("DELETE", "/me/connections/reach", (), emp)).statusCode, 204);
    test:assertTrue(fakeReachConnections.deletedSoFar().indexOf("emp-reach-2") !is ());
    json after = check (check send("GET", "/me/connections/reach", (), emp)).getJsonPayload();
    test:assertEquals(check after.connected, false);
    test:assertEquals((check send("DELETE", "/me/connections/reach", (), emp)).statusCode, 204);
}
