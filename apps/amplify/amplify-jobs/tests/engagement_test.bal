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

// `POST /engagement/sync` wiring on fakes: the setting switch, the page connection and its token (refresh near
// expiry), the Community Management source mapping, and the scheduler key's access to the route.

import amplify_common.crypto;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.sharing;

import ballerina/test;
import ballerina/time;

const string SYNC_PAGE = "urn:li:organization:1477";
const string SYNC_POST = "urn:li:share:7300";
const string SYNC_MEMBER = "urn:li:person:syncA";
final time:Utc SYNC_T0 = [1790100000, 0];

final crypto:TokenCipher syncCipher = check new ([check crypto:keyFromBase64("k1",
    "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")], "k1");

isolated class FakeCommunity {
    *linkedin:CommunityPort;
    private string[] calls = [];
    private boolean limited = false;
    private linkedin:ProviderErrorCode? refreshFails = ();

    isolated function failRefresh(linkedin:ProviderErrorCode code) {
        lock {
            self.refreshFails = code;
        }
    }

    isolated function rateLimit() {
        lock {
            self.limited = true;
        }
    }

    isolated function log() returns string[] {
        lock {
            return self.calls.clone();
        }
    }

    public isolated function authorizationUrl(string state) returns string|linkedin:ProviderError => "https://x/" + state;

    public isolated function exchangeCode(string code) returns linkedin:TokenGrant|linkedin:ProviderError =>
        {accessToken: "a", expiresInSeconds: 1, scopes: []};

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
        return {accessToken: "page-access-2", expiresInSeconds: 5184000, scopes: [], refreshToken: refreshToken,
            refreshExpiresInSeconds: 30000000};
    }

    public isolated function revokeToken(string token) returns linkedin:ProviderError? => ();

    public isolated function isAdmin(string accessToken, string orgUrn) returns boolean|linkedin:ProviderError => true;

    public isolated function listReactions(string accessToken, string entityUrn, int 'start, int count)
            returns linkedin:ReactionPage|linkedin:ProviderError {
        lock {
            self.calls.push(string `reactions ${accessToken} ${'start}`);
            if self.limited {
                return error linkedin:ProviderError("429", code = linkedin:RATE_LIMITED, httpStatus = 429,
                    serviceErrorCode = 101, retryable = true);
            }
        }
        return 'start > 0 ? {items: [], fetched: 0} : {items: [{actorUrn: SYNC_MEMBER, rootUrn: entityUrn,
            reactionType: "LIKE", createdAtMs: 1790050000000}], fetched: 1};
    }

    public isolated function listComments(string accessToken, string entityUrn, int 'start, int count)
            returns linkedin:CommentPage|linkedin:ProviderError =>
        'start > 0 ? {items: [], fetched: 0} : {items: [{actorUrn: SYNC_MEMBER, commentUrn: "urn:li:comment:(x,1)",
            objectUrn: entityUrn, createdAtMs: 1790050001000}], fetched: 1};

    public isolated function listShareNotifications(string accessToken, string orgUrn, int startMs, int endMs,
            int 'start = 0, int count = 50) returns linkedin:NotificationPage|linkedin:ProviderError =>
        'start > 0 ? {items: [], fetched: 0} : {items: [
            {action: "SHARE", activityUrn: "urn:li:activity:1", actorUrn: SYNC_MEMBER, hasCommentary: false,
                sourcePostUrn: SYNC_POST, occurredAtMs: 1790050002000},
            {action: "SHARE_MENTION", activityUrn: "urn:li:activity:2", actorUrn: SYNC_MEMBER, hasCommentary: false,
                sourcePostUrn: "urn:li:share:999", occurredAtMs: 1790050003000}
        ], fetched: 2};
}

isolated class MemorySyncStore {
    *sharing:SyncStore;
    private map<string> cursors = {};
    private sharing:Engagement[] rows = [];

    public isolated function openCampaigns(time:Utc now) returns sharing:SyncCampaign[]|error =>
        [{id: "0192f0e0-0000-7000-8000-00000000d001", resourceUrn: SYNC_POST, opensAt: [1790000000, 0],
            closesAt: [1790900000, 0]}];

    public isolated function employeesOf(string[] memberUrns) returns map<types:EmployeeId>|error =>
        memberUrns.indexOf(SYNC_MEMBER) is () ? {} : {[SYNC_MEMBER]: "emp-sync"};

    public isolated function cursor(string resourceUrn, sharing:SyncEndpoint endpoint) returns string|error? {
        lock {
            return self.cursors[resourceUrn + endpoint];
        }
    }

    public isolated function saveCursor(string resourceUrn, sharing:SyncEndpoint endpoint, string cursor, time:Utc now)
            returns error? {
        lock {
            self.cursors[resourceUrn + endpoint] = cursor;
        }
    }

    public isolated function takeCall(time:Utc now, int budget) returns boolean|error => true;

    public isolated function recordSynced(sharing:Engagement engagement, time:Utc now) returns boolean|error {
        lock {
            self.rows.push(engagement.clone());
            return true;
        }
    }

    isolated function recorded() returns sharing:Engagement[] {
        lock {
            return self.rows.clone();
        }
    }
}

isolated class FakeEngagementStore {
    *EngagementStore;
    private EngagementSettings current;
    private connection:OrgConnection? org;
    private map<connection:StoredToken> tokens = {};
    private int saves = 0;
    private string[] refreshFailures = [];
    private final MemorySyncStore sync = new;

    isolated function init(boolean enabled, connection:OrgConnection? org, connection:StoredToken[] tokens) {
        self.current = {enabled, dailyBudget: 450};
        self.org = org.clone();
        map<connection:StoredToken> byId = {};
        foreach connection:StoredToken t in tokens {
            byId[t.tokenId] = t.clone();
        }
        self.tokens = byId.clone();
    }

    isolated function settings() returns EngagementSettings|error {
        lock {
            return self.current.clone();
        }
    }

    isolated function orgConnection() returns connection:OrgConnection|error? {
        lock {
            return self.org.clone();
        }
    }

    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error? {
        lock {
            return self.tokens[ref.tokenId].clone();
        }
    }

    isolated function saveOrg(connection:OrgConnectionChange change, int expectedVersion) returns error? {
        final readonly & connection:OrgConnectionChange c = change.cloneReadOnly();
        lock {
            foreach connection:StoredToken t in c.tokensToInsert {
                self.tokens[t.tokenId] = t.clone();
            }
            self.org = c.connection.clone();
            self.saves += 1;
        }
    }

    isolated function saveCount() returns int {
        lock {
            return self.saves;
        }
    }

    isolated function recordRefreshFailure(string orgUrn, string errorCode) returns error? {
        lock {
            self.refreshFailures.push(orgUrn + " " + errorCode);
        }
    }

    isolated function audits() returns string[] {
        lock {
            return self.refreshFailures.clone();
        }
    }

    isolated function syncStore(string orgUrn) returns sharing:SyncStore => self.sync;

    isolated function recorded() returns sharing:Engagement[] => self.sync.recorded();
}

function pageConnection(int accessSecondsLeft) returns [connection:OrgConnection, connection:StoredToken[]]|error {
    connection:StoredToken access = check connection:sealOrgToken(syncCipher, "page-access-1", SYNC_PAGE, "ACCESS",
            time:utcAddSeconds(SYNC_T0, <decimal>accessSecondsLeft), SYNC_T0);
    connection:StoredToken refresh = check connection:sealOrgToken(syncCipher, "page-refresh-1", SYNC_PAGE, "REFRESH",
            time:utcAddSeconds(SYNC_T0, 30000000), SYNC_T0);
    connection:OrgConnectionChange c = connection:connectOrg((), {orgUrn: SYNC_PAGE, connectedBy: "admin",
        scopes: linkedin:PAGE_SCOPES, access, refresh}, SYNC_T0);
    return [c.connection, [access, refresh]];
}

@test:Config
function testEngagementSyncSwitchAndConnection() returns error? {
    FakeCommunity community = new;
    test:assertEquals((check runEngagementSync(new FakeEngagementStore(false, (), []), community, syncCipher, SYNC_T0)).status,
            "OFF", "off by default");
    test:assertEquals((check runEngagementSync(new FakeEngagementStore(true, (), []), (), syncCipher, SYNC_T0)).status,
            "NOT_CONFIGURED");
    test:assertEquals((check runEngagementSync(new FakeEngagementStore(true, (), []), community, syncCipher, SYNC_T0)).status,
            "NOT_CONNECTED");
    [connection:OrgConnection, connection:StoredToken[]] [org, tokens] = check pageConnection(5184000);
    connection:OrgConnection revoked = connection:revokeOrg(org, SYNC_T0).connection;
    test:assertEquals((check runEngagementSync(new FakeEngagementStore(true, revoked, tokens), community, syncCipher,
            SYNC_T0)).status, "NEEDS_RECONNECT");
    test:assertEquals(community.log(), [], "no LinkedIn call without a usable page connection");
}

@test:Config
function testEngagementSyncRecordsWithThePageToken() returns error? {
    FakeCommunity community = new;
    [connection:OrgConnection, connection:StoredToken[]] [org, tokens] = check pageConnection(5184000);
    FakeEngagementStore st = new (true, org, tokens);
    EngagementSyncResult result = check runEngagementSync(st, community, syncCipher, SYNC_T0);
    test:assertEquals(result.status, "DONE");
    test:assertFalse(result.tokenRefreshed);
    sharing:SyncReport report = <sharing:SyncReport>result.sync;
    test:assertEquals([report.reactions, report.comments, report.reposts], [1, 1, 1], "the page mention is not a reshare");
    test:assertEquals(community.log()[0], "reactions page-access-1 0", "the decrypted page token");
    foreach sharing:Engagement e in st.recorded() {
        test:assertEquals(e.employeeId, "emp-sync");
        test:assertEquals(e.providerApi, types:COMMUNITY_MANAGEMENT);
        test:assertEquals(e.origin, types:API_SYNC);
    }
}

@test:Config
function testEngagementSyncRefreshesNearExpiryAndStopsOnRateLimit() returns error? {
    FakeCommunity community = new;
    [connection:OrgConnection, connection:StoredToken[]] [org, tokens] = check pageConnection(3600);
    FakeEngagementStore st = new (true, org, tokens);
    community.rateLimit();
    EngagementSyncResult result = check runEngagementSync(st, community, syncCipher, SYNC_T0);
    test:assertTrue(result.tokenRefreshed);
    test:assertEquals(st.saveCount(), 1, "the new token rows are stored");
    string[] log = community.log();
    test:assertEquals(log[0], "refresh page-refresh-1");
    test:assertEquals(log[1], "reactions page-access-2 0", "the sync uses the refreshed token");
    test:assertEquals(result.status, "RATE_LIMITED");
    test:assertEquals(st.recorded().length(), 0);
}

@test:Config
function testSchedulerKeyMayCallTheSync() {
    test:assertTrue(schedulerMayCall("POST", ["engagement", "sync"]));
    test:assertFalse(schedulerMayCall("GET", ["engagement", "sync"]));
    test:assertEquals(toEngagementSettings([]), {enabled: false, dailyBudget: 450});
    test:assertEquals(toEngagementSettings([
        {key: "engagement.sync_enabled", value: true, updatedBy: "x", updatedAt: SYNC_T0, version: 1},
        {key: "engagement.daily_call_budget", value: 100, updatedBy: "x", updatedAt: SYNC_T0, version: 1}
    ]), {enabled: true, dailyBudget: 100});
}

@test:Config
function testEngagementSyncAuditsARefusedRefresh() returns error? {
    FakeCommunity community = new;
    community.failRefresh(linkedin:UNAUTHORIZED);
    [connection:OrgConnection, connection:StoredToken[]] [org, tokens] = check pageConnection(-10);
    FakeEngagementStore st = new (true, org, tokens);
    EngagementSyncResult result = check runEngagementSync(st, community, syncCipher, SYNC_T0);
    test:assertEquals(result.status, "NEEDS_RECONNECT");
    test:assertEquals(st.audits(), [SYNC_PAGE + " UNAUTHORIZED"], "a refused refresh is audited once, without a token");
}

@test:Config
function testEngagementSyncDoesNotAuditAnOutage() returns error? {
    FakeCommunity community = new;
    community.failRefresh(linkedin:UNAVAILABLE);
    [connection:OrgConnection, connection:StoredToken[]] [org, tokens] = check pageConnection(-10);
    FakeEngagementStore st = new (true, org, tokens);
    EngagementSyncResult result = check runEngagementSync(st, community, syncCipher, SYNC_T0);
    test:assertEquals(result.status, "UNAVAILABLE");
    test:assertEquals(st.audits().length(), 0, "an outage is retried, not audited");
}
