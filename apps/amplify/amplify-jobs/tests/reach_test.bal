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


// `POST /reach/refresh` wiring on fakes: the switch, consent, the per-employee token (opened once, refreshed near
// expiry), the analytics mapping, and the scheduler key's access to the route.

import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/test;
import ballerina/time;

final time:Utc REACH_T0 = [1790100000, 0];

isolated class FakeAnalytics {
    *linkedin:MemberAnalyticsPort;
    private string[] calls = [];
    private linkedin:ProviderErrorCode? refreshFails = ();

    isolated function failRefresh(linkedin:ProviderErrorCode code) {
        lock {
            self.refreshFails = code;
        }
    }

    isolated function log() returns string[] {
        lock {
            return self.calls.clone();
        }
    }

    public isolated function memberAuthorizationUrl(string state, string redirectUri)
            returns string|linkedin:ProviderError => "https://x/" + state;

    public isolated function exchangeMemberCode(string code, string redirectUri)
            returns linkedin:TokenGrant|linkedin:ProviderError => {accessToken: "a", expiresInSeconds: 1, scopes: []};

    public isolated function refresh(string refreshToken) returns linkedin:TokenGrant|linkedin:ProviderError {
        lock {
            self.calls.push("refresh " + refreshToken);
        }
        linkedin:ProviderErrorCode? fails;
        lock {
            fails = self.refreshFails;
        }
        if fails is linkedin:ProviderErrorCode {
            return error linkedin:ProviderError("refresh refused", code = fails, httpStatus = 400,
                serviceErrorCode = (), retryable = false);
        }
        return {accessToken: "reach-access-2", expiresInSeconds: 5184000, scopes: []};
    }

    public isolated function revokeToken(string token) returns linkedin:ProviderError? => ();

    public isolated function memberPostMetric(string accessToken, string postUrn, linkedin:AnalyticsMetric metric)
            returns int|linkedin:ProviderError {
        lock {
            self.calls.push(string `${metric} ${accessToken} ${postUrn}`);
        }
        if postUrn == "urn:li:share:gone" {
            return error linkedin:ProviderError("404", code = linkedin:REJECTED, httpStatus = 404, serviceErrorCode = (),
                retryable = false);
        }
        return metric == linkedin:IMPRESSION ? 900 : 400;
    }
}

isolated class MemoryReachStore {
    *sharing:ReachStore;
    private final readonly & sharing:ReachTarget[] queue;
    private sharing:ReachReading[] saved = [];

    isolated function init(sharing:ReachTarget[] queue) {
        self.queue = queue.cloneReadOnly();
    }

    public isolated function targets(time:Utc since, string today) returns sharing:ReachTarget[]|error => self.queue;

    public isolated function takeCall(time:Utc now, int budget) returns boolean|error => true;

    public isolated function saveReading(sharing:ReachTarget target, sharing:ReachReading reading, time:Utc now)
            returns error? {
        lock {
            self.saved.push(reading.clone());
        }
    }

    isolated function readings() returns sharing:ReachReading[] {
        lock {
            return self.saved.clone();
        }
    }
}

isolated class FakeReachJobStore {
    *ReachJobStore;
    private final ReachSettings & readonly s;
    private connection:ReachConnection[] conns;
    private final map<connection:StoredToken> tokens;
    private final MemoryReachStore inner;
    private int saves = 0;
    private string[] refreshFailures = [];

    isolated function init(ReachSettings s, connection:ReachConnection[] conns, connection:StoredToken[] tokens,
            sharing:ReachTarget[] targets) {
        self.s = s.cloneReadOnly();
        self.conns = conns.clone();
        map<connection:StoredToken> m = {};
        foreach connection:StoredToken t in tokens {
            m[t.tokenId] = t.clone();
        }
        self.tokens = m.clone();
        self.inner = new (targets);
    }

    isolated function settings() returns ReachSettings|error => self.s;

    isolated function connections() returns connection:ReachConnection[]|error {
        lock {
            return self.conns.clone();
        }
    }

    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error? {
        lock {
            return self.tokens[ref.tokenId].clone();
        }
    }

    isolated function saveReach(connection:ReachChange change, int expectedVersion) returns error? {
        connection:StoredToken[] & readonly fresh = change.tokensToInsert.cloneReadOnly();
        lock {
            foreach connection:StoredToken t in fresh {
                self.tokens[t.tokenId] = t.clone();
            }
            self.saves += 1;
        }
    }

    isolated function recordRefreshFailure(types:EmployeeId employeeId, string errorCode) returns error? {
        lock {
            self.refreshFailures.push(employeeId + " " + errorCode);
        }
    }

    isolated function audits() returns string[] {
        lock {
            return self.refreshFailures.clone();
        }
    }

    isolated function reachStore(types:EmployeeId[] employeeIds) returns sharing:ReachStore => self.inner;

    isolated function savedCount() returns int {
        lock {
            return self.saves;
        }
    }

    isolated function readings() returns sharing:ReachReading[] => self.inner.readings();
}

function reachConn(string employee, int accessSeconds, boolean withRefresh)
        returns [connection:ReachConnection, connection:StoredToken[]]|error {
    connection:StoredToken access = check connection:sealReachToken(syncCipher, "reach-access-" + employee, employee,
            "ACCESS", time:utcAddSeconds(REACH_T0, <decimal>accessSeconds), REACH_T0);
    connection:StoredToken? refresh = withRefresh ? check connection:sealReachToken(syncCipher, "reach-refresh-" + employee,
            employee, "REFRESH", time:utcAddSeconds(REACH_T0, 30000000), REACH_T0) : ();
    connection:ReachChange c = connection:connectReach((), employee, ["r_member_postAnalytics"], access, refresh,
            REACH_T0);
    connection:StoredToken[] rows = [access];
    if refresh is connection:StoredToken {
        rows.push(refresh);
    }
    return [c.connection, rows];
}

@test:Config {}
function testReachOffAndNotConfigured() returns error? {
    FakeReachJobStore off = new ({}, [], [], []);
    test:assertEquals((check runReachRefresh(off, new FakeAnalytics(), syncCipher, 10, REACH_T0)).status, "OFF");
    FakeReachJobStore enabledStore = new ({enabled: true}, [], [], []);
    test:assertEquals((check runReachRefresh(enabledStore, (), syncCipher, 10, REACH_T0)).status, "NOT_CONFIGURED");
    test:assertEquals((check runReachRefresh(enabledStore, new FakeAnalytics(), (), 10, REACH_T0)).status, "NOT_CONFIGURED");
    test:assertEquals((check runReachRefresh(enabledStore, new FakeAnalytics(), syncCipher, 10, REACH_T0)).status, "NO_CONSENT");
}

@test:Config {}
function testReachReadsWithEachEmployeesOwnToken() returns error? {
    var [a, aTokens] = check reachConn("emp-a", 5184000, false);
    // b's token expires within the refresh lead: renewed once, before the first read.
    var [b, bTokens] = check reachConn("emp-b", 3600, true);
    // c's token expired and cannot be renewed: skipped without a call.
    var [c, cTokens] = check reachConn("emp-c", -10, false);
    FakeReachJobStore st = new ({enabled: true}, [a, b, c], [...aTokens, ...bTokens, ...cTokens], [
        {engagementId: "e1", employeeId: "emp-a", postUrn: "urn:li:share:1"},
        {engagementId: "e2", employeeId: "emp-b", postUrn: "urn:li:share:2"},
        {engagementId: "e3", employeeId: "emp-b", postUrn: "urn:li:share:gone"},
        {engagementId: "e4", employeeId: "emp-c", postUrn: "urn:li:share:4"}
    ]);
    FakeAnalytics analytics = new;
    ReachRefreshResult r = check runReachRefresh(st, analytics, syncCipher, 10, REACH_T0);
    test:assertEquals(r.status, "DONE");
    test:assertEquals(r.consenting, 3);
    test:assertEquals(r.tokensRefreshed, 1);
    sharing:ReachReport report = check r.report.ensureType();
    test:assertEquals(report.measured, 2);
    test:assertEquals(report.skippedNotReadable, 1);
    test:assertEquals(report.skippedNoToken, 1);
    test:assertEquals(st.readings()[0], {impressions: 900, membersReached: 400});
    test:assertEquals(st.savedCount(), 1, "the renewed token is saved");
    string[] calls = analytics.log();
    test:assertEquals(calls[0], "IMPRESSION reach-access-emp-a urn:li:share:1");
    test:assertEquals(calls[2], "refresh reach-refresh-emp-b");
    test:assertEquals(calls[3], "IMPRESSION reach-access-2 urn:li:share:2", "b reads with the renewed token");
    test:assertFalse(calls.toString().includes("share:4"), "c is never called");
}

@test:Config {}
function testReachSettingsAndSchedulerKey() {
    ReachSettings s = toReachSettings([
        {key: "reach.enabled", value: true, updatedBy: "x", updatedAt: REACH_T0, version: 1},
        {key: "reach.window_days", value: 7, updatedBy: "x", updatedAt: REACH_T0, version: 1},
        {key: "engagement.daily_call_budget", value: 100, updatedBy: "x", updatedAt: REACH_T0, version: 1}
    ]);
    test:assertEquals(s, {enabled: true, windowDays: 7, dailyBudget: 100});
    store:Setting[] bad = [{key: "reach.window_days", value: 500, updatedBy: "x", updatedAt: REACH_T0, version: 1}];
    test:assertEquals(toReachSettings(bad).windowDays, 30);
    test:assertTrue(schedulerMayCall("POST", ["reach", "refresh"]));
    test:assertFalse(schedulerMayCall("GET", ["reach", "refresh"]));
}

@test:Config {}
function testReachProviderErrorMapping() {
    linkedin:ProviderError limited = error linkedin:ProviderError("x", code = linkedin:RATE_LIMITED, httpStatus = 429,
        serviceErrorCode = (), retryable = true);
    test:assertEquals(reachSourceError(limited).detail().reason, "RATE_LIMITED");
    linkedin:ProviderError expired = error linkedin:ProviderError("x", code = linkedin:UNAUTHORIZED, httpStatus = 401,
        serviceErrorCode = (), retryable = false);
    test:assertEquals(reachSourceError(expired).detail().reason, "UNAUTHORIZED");
    linkedin:ProviderError forbidden = error linkedin:ProviderError("x", code = linkedin:FORBIDDEN, httpStatus = 403,
        serviceErrorCode = (), retryable = false);
    test:assertEquals(reachSourceError(forbidden).detail().reason, "REJECTED", "another member's post is skipped");
    linkedin:ProviderError down = error linkedin:ProviderError("x", code = linkedin:UNAVAILABLE, httpStatus = 503,
        serviceErrorCode = (), retryable = true);
    test:assertEquals(reachSourceError(down).detail().reason, "UNAVAILABLE");
}

@test:Config {}
function testReachAuditsARefusedRefreshButNotAnOutage() returns error? {
    var [b, bTokens] = check reachConn("emp-b", 3600, true);
    sharing:ReachTarget[] targets = [{engagementId: "e2", employeeId: "emp-b", postUrn: "urn:li:share:2"}];
    FakeAnalytics refused = new;
    refused.failRefresh(linkedin:UNAUTHORIZED);
    FakeReachJobStore st = new ({enabled: true}, [b], bTokens, targets);
    _ = check runReachRefresh(st, refused, syncCipher, 10, REACH_T0);
    test:assertEquals(st.audits(), ["emp-b UNAUTHORIZED"], "a refused Reach refresh is audited, without a token");
    test:assertEquals(st.savedCount(), 0);

    FakeAnalytics down = new;
    down.failRefresh(linkedin:UNAVAILABLE);
    FakeReachJobStore st2 = new ({enabled: true}, [b], bTokens, targets);
    _ = check runReachRefresh(st2, down, syncCipher, 10, REACH_T0);
    test:assertEquals(st2.audits().length(), 0, "an outage is not audited");
}
