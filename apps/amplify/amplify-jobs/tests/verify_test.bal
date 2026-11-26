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

// `POST /coins/verify` wiring on fakes (V027): which token and which LinkedIn read per engagement, the page-token
// fallback, what is recorded on the sharing side, the budgets and stops, and the scheduler key's access. The
// verification rules themselves are covered in amplify_domain.scoring (verification_test.bal).

import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.scoring;
import amplify_domain.sharing;

import ballerina/test;
import ballerina/time;

final time:Utc VERIFY_T0 = [1796086800, 0];

// Ledger rows to check and what the verification marked on each.
isolated class FakeVerifyLedger {
    *scoring:VerificationRepository;

    private final scoring:VerifyCandidate[] rows;
    private map<string> marks = {};

    isolated function init(scoring:VerifyCandidate[] rows) {
        self.rows = rows.clone();
    }

    isolated function marked() returns map<string> {
        lock {
            return self.marks.clone();
        }
    }

    public isolated function dueForCheck(time:Utc staleBefore, int 'limit) returns scoring:VerifyCandidate[]|error {
        lock {
            scoring:VerifyCandidate[] due = [];
            foreach scoring:VerifyCandidate c in self.rows {
                if !self.marks.hasKey(c.reference) && due.length() < 'limit {
                    due.push(c.clone());
                }
            }
            return due.clone();
        }
    }

    public isolated function markVerified(types:LedgerReference reference, time:Utc now) returns error? {
        lock {
            self.marks[reference] = "VERIFIED";
        }
    }

    public isolated function markUnverifiable(types:LedgerReference reference, string reason, time:Utc now)
            returns error? {
        lock {
            self.marks[reference] = "UNVERIFIABLE " + reason;
        }
    }

    public isolated function reverseRemoved(types:LedgerReference reference, string? correlationId, time:Utc now)
            returns boolean|error {
        lock {
            self.marks[reference] = "REVERSED";
        }
        return true;
    }
}

isolated class FakeVerifyStore {
    *VerifyStore;

    private final VerifySettings & readonly s;
    private final FakeVerifyLedger ledgerRepo;
    private final map<sharing:Engagement> & readonly engagements;
    private final map<connection:LinkedInConnection> & readonly members;
    private final connection:OrgConnection? & readonly org;
    private final map<connection:StoredToken> & readonly tokens;
    private string[] checks = [];
    private map<int> calls = {};

    isolated function init(VerifySettings s, FakeVerifyLedger ledgerRepo, sharing:Engagement[] engagements,
            connection:LinkedInConnection[] members, connection:OrgConnection? org, connection:StoredToken[] tokens) {
        self.s = s.cloneReadOnly();
        self.ledgerRepo = ledgerRepo;
        self.engagements = map from sharing:Engagement e in engagements select [e.id, e].cloneReadOnly();
        self.members = map from connection:LinkedInConnection m in members select [m.employeeId, m].cloneReadOnly();
        self.org = org.cloneReadOnly();
        self.tokens = map from connection:StoredToken t in tokens select [t.tokenId, t].cloneReadOnly();
    }

    isolated function checkLog() returns string[] {
        lock {
            return self.checks.clone();
        }
    }

    isolated function settings() returns VerifySettings|error => self.s;

    isolated function ledger() returns scoring:VerificationRepository => self.ledgerRepo;

    isolated function engagement(string id) returns sharing:Engagement|error? => self.engagements[id];

    isolated function recordCheck(string engagementId, types:ProviderApi providerApi, boolean stillExists, time:Utc now)
            returns error? {
        lock {
            self.checks.push(string `${engagementId} ${providerApi} ${stillExists}`);
        }
    }

    isolated function takeCall(types:ProviderApi providerApi, time:Utc now, int budget) returns boolean|error {
        lock {
            int used = self.calls[providerApi] ?: 0;
            if used >= budget {
                return false;
            }
            self.calls[providerApi] = used + 1;
            return true;
        }
    }

    isolated function memberConnection(types:EmployeeId employeeId) returns connection:LinkedInConnection|error? =>
        self.members[employeeId];

    isolated function orgConnection() returns connection:OrgConnection|error? => self.org;

    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error? => self.tokens[ref.tokenId];
}

// Answers by URN: "gone", "forbidden", "expired", "slow" (429), "down"; anything else is present.
isolated function presenceFor(string urn) returns linkedin:Presence|linkedin:ProviderError {
    [string, linkedin:ProviderErrorCode][] failures = [["forbidden", linkedin:FORBIDDEN],
        ["expired", linkedin:UNAUTHORIZED], ["slow", linkedin:RATE_LIMITED], ["down", linkedin:UNAVAILABLE]];
    foreach [string, linkedin:ProviderErrorCode] [word, code] in failures {
        if urn.includes(word) {
            return error linkedin:ProviderError("refused", code = code, httpStatus = (), serviceErrorCode = (),
                retryable = false);
        }
    }
    return urn.includes("gone") ? linkedin:GONE : linkedin:PRESENT;
}

isolated class FakeMemberPosts {
    *linkedin:PostPresencePort;

    private string[] calls = [];

    isolated function log() returns string[] {
        lock {
            return self.calls.clone();
        }
    }

    public isolated function postPresence(string accessToken, string postUrn) returns linkedin:Presence|linkedin:ProviderError {
        lock {
            self.calls.push(string `post ${accessToken} ${postUrn}`);
        }
        return presenceFor(postUrn);
    }
}

isolated class FakePagePresence {
    *linkedin:CommunityPresencePort;

    private string[] calls = [];
    private final boolean refusePosts;

    isolated function init(boolean refusePosts = false) {
        self.refusePosts = refusePosts;
    }

    isolated function log() returns string[] {
        lock {
            return self.calls.clone();
        }
    }

    public isolated function postPresence(string accessToken, string postUrn) returns linkedin:Presence|linkedin:ProviderError {
        lock {
            self.calls.push(string `post ${accessToken} ${postUrn}`);
        }
        return self.refusePosts ? presenceFor("forbidden") : presenceFor(postUrn);
    }

    public isolated function reactionPresence(string accessToken, string actorUrn, string entityUrn)
            returns linkedin:Presence|linkedin:ProviderError {
        lock {
            self.calls.push(string `reaction ${accessToken} ${actorUrn} ${entityUrn}`);
        }
        return presenceFor(actorUrn);
    }

    public isolated function commentPresence(string accessToken, string commentUrn)
            returns linkedin:Presence|linkedin:ProviderError {
        lock {
            self.calls.push(string `comment ${accessToken} ${commentUrn}`);
        }
        return presenceFor(commentUrn);
    }
}

function verifyEngagementOf(string id, types:EngagementAction action, string? activityUrn, string employeeId = "emp-v",
        string actor = "urn:li:person:v", time:Utc? deletedAt = ()) returns sharing:Engagement => {
    id, provider: types:LINKEDIN, providerApi: types:SHARE_ON_LINKEDIN, origin: types:IN_APP,
    targetResourceUrn: "urn:li:share:7300", campaignId: (), actorMemberUrn: actor, employeeId, action, activityUrn,
    occurredAt: VERIFY_T0, observedAt: VERIFY_T0, lastVerifiedAt: (), deletedAt
};

function row(string reference, string engagementId, string employeeId = "emp-v") returns scoring:VerifyCandidate =>
    {reference, employeeId, engagementId, action: types:REPOST};

function memberOf(string employeeId, time:Utc now, int expiresInDays = 50)
        returns [connection:LinkedInConnection, connection:StoredToken]|error {
    connection:StoredToken token = check connection:sealToken(syncCipher, "member-" + employeeId, employeeId,
            time:utcAddSeconds(now, <decimal>(expiresInDays * 86400)), now);
    return [{
        employeeId, provider: types:LINKEDIN, memberUrn: "urn:li:person:" + employeeId,
        providerApi: types:SHARE_ON_LINKEDIN, scopes: ["openid", "profile", "w_member_social"],
        currentToken: connection:tokenRef(token), accessExpiresAt: time:utcAddSeconds(now, <decimal>(expiresInDays * 86400)),
        connectedAt: time:utcAddSeconds(now, -86400 * 70), revokedAt: (), removedAt: (), lastRemindedAt: (), version: 1
    }, token];
}

@test:Config
function testVerifySwitchAndConfiguration() returns error? {
    FakeVerifyLedger ledger = new ([row("AMP-1", "e-1")]);
    FakeVerifyStore off = new ({}, ledger, [], [], (), []);
    test:assertEquals(check runCoinVerification(off, new FakeMemberPosts(), (), syncCipher, (), VERIFY_T0),
            <VerifySkipped>{reason: "WALLETS_OFF"});
    FakeVerifyStore enabled = new ({walletsEnabled: true}, ledger, [], [], (), []);
    test:assertEquals(check runCoinVerification(enabled, (), (), syncCipher, (), VERIFY_T0),
            <VerifySkipped>{reason: "NOT_CONFIGURED"});
    test:assertEquals(check runCoinVerification(enabled, new FakeMemberPosts(), (), (), (), VERIFY_T0),
            <VerifySkipped>{reason: "NOT_CONFIGURED"});
    test:assertEquals(ledger.marked(), {}, "a configuration gap flags nothing");
}

@test:Config
function testVerifyReadsEachKindWithTheRightToken() returns error? {
    [connection:LinkedInConnection, connection:StoredToken] [m, mt] = check memberOf("emp-v", VERIFY_T0);
    [connection:OrgConnection, connection:StoredToken[]] [org, pageTokens] = check pageConnection(5184000);
    FakeVerifyLedger ledger = new ([
        row("AMP-post", "e-post"),
        row("AMP-gone", "e-gone"),
        row("AMP-native", "e-native", "emp-none"),
        row("AMP-react", "e-react", "emp-none"),
        row("AMP-comment", "e-comment", "emp-none"),
        row("AMP-erased", "e-erased", "emp-none"),
        row("AMP-missing", "e-missing"),
        row("AMP-known", "e-known")
    ]);
    FakeVerifyStore st = new ({walletsEnabled: true}, ledger, [
        verifyEngagementOf("e-post", types:REPOST, "urn:li:share:8001"),
        verifyEngagementOf("e-gone", types:REPOST_COMMENTARY, "urn:li:share:gone1"),
        verifyEngagementOf("e-native", types:REPOST, "urn:li:share:8003", "emp-none"),
        verifyEngagementOf("e-react", types:REACTION, (), "emp-none", "urn:li:person:x"),
        verifyEngagementOf("e-comment", types:COMMENT, "urn:li:comment:(urn:li:share:gone,5)", "emp-none"),
        verifyEngagementOf("e-erased", types:REACTION, (), "emp-none", "urn:li:person:erased"),
        verifyEngagementOf("e-known", types:REPOST, "urn:li:share:8004", deletedAt = VERIFY_T0)
    ], [m], org, [mt, ...pageTokens]);
    FakeMemberPosts member = new;
    FakePagePresence page = new;
    scoring:VerifyReport r = <scoring:VerifyReport>check runCoinVerification(st, member, page, syncCipher, "cid-1",
            VERIFY_T0);
    test:assertEquals(r.status, scoring:VERIFY_DONE);
    test:assertEquals(ledger.marked(), {
        "AMP-post": "VERIFIED",
        "AMP-gone": "REVERSED",
        "AMP-native": "VERIFIED",
        "AMP-react": "VERIFIED",
        "AMP-comment": "REVERSED",
        "AMP-erased": "UNVERIFIABLE MEMBER_ERASED",
        "AMP-missing": "UNVERIFIABLE SOURCE_NOT_FOUND",
        "AMP-known": "REVERSED"
    });
    test:assertEquals(member.log(), ["post member-emp-v urn:li:share:8001", "post member-emp-v urn:li:share:gone1"],
            "the employee's own decrypted token");
    test:assertEquals(page.log(), ["post page-access-1 urn:li:share:8003",
        "reaction page-access-1 urn:li:person:x urn:li:share:7300",
        "comment page-access-1 urn:li:comment:(urn:li:share:gone,5)"], "the page token for the rest");
    test:assertEquals(st.checkLog(), ["e-post SHARE_ON_LINKEDIN true", "e-gone SHARE_ON_LINKEDIN false",
        "e-native COMMUNITY_MANAGEMENT true", "e-react COMMUNITY_MANAGEMENT true", "e-comment COMMUNITY_MANAGEMENT false"],
            "only answers are recorded on the sharing side; a known deletion makes no call");
}

@test:Config
function testVerifyCantCheckMeansActionRequired() returns error? {
    [connection:LinkedInConnection, connection:StoredToken] [expired, et] = check memberOf("emp-exp", VERIFY_T0, -1);
    [connection:LinkedInConnection, connection:StoredToken] [m, mt] = check memberOf("emp-v", VERIFY_T0);
    [connection:OrgConnection, connection:StoredToken[]] [org, pageTokens] = check pageConnection(5184000);
    FakeVerifyLedger ledger = new ([
        row("AMP-exp", "e-exp", "emp-exp"),
        row("AMP-forbid", "e-forbid"),
        row("AMP-old", "e-old"),
        row("AMP-react", "e-react")
    ]);
    sharing:Engagement[] engagements = [
        verifyEngagementOf("e-exp", types:REPOST, "urn:li:share:9001", "emp-exp"),
        verifyEngagementOf("e-forbid", types:REPOST, "urn:li:share:forbidden"),
        verifyEngagementOf("e-old", types:SHARE, ()),
        verifyEngagementOf("e-react", types:REACTION, ())
    ];
    // No page connection: the expired member token can't fall back, and the reaction can't be read.
    FakeVerifyStore st = new ({walletsEnabled: true}, ledger, engagements, [expired, m], (), [et, mt]);
    _ = check runCoinVerification(st, new FakeMemberPosts(), new FakePagePresence(), syncCipher, (), VERIFY_T0);
    test:assertEquals(ledger.marked(), {
        "AMP-exp": "UNVERIFIABLE TOKEN_EXPIRED",
        "AMP-forbid": "UNVERIFIABLE NOT_PERMITTED",
        "AMP-old": "UNVERIFIABLE NO_ACTIVITY",
        "AMP-react": "UNVERIFIABLE NO_TOKEN"
    });

    // With the page connected but refusing member posts too, the employee's reason is kept.
    FakeVerifyLedger again = new ([row("AMP-exp", "e-exp", "emp-exp")]);
    FakeVerifyStore withPage = new ({walletsEnabled: true}, again, engagements, [expired], org, [et, ...pageTokens]);
    FakePagePresence refusing = new (true);
    _ = check runCoinVerification(withPage, new FakeMemberPosts(), refusing, syncCipher, (), VERIFY_T0);
    test:assertEquals(again.marked(), {"AMP-exp": "UNVERIFIABLE TOKEN_EXPIRED"});
    test:assertEquals(refusing.log().length(), 1, "the page token was tried");
}

@test:Config
function testVerifyStopsOnBudgetAndRateLimit() returns error? {
    [connection:LinkedInConnection, connection:StoredToken] [m, mt] = check memberOf("emp-v", VERIFY_T0);
    sharing:Engagement[] engagements = [
        verifyEngagementOf("e-1", types:REPOST, "urn:li:share:1"),
        verifyEngagementOf("e-2", types:REPOST, "urn:li:share:2"),
        verifyEngagementOf("e-slow", types:REPOST, "urn:li:share:slow"),
        verifyEngagementOf("e-down", types:REPOST, "urn:li:share:down")
    ];
    FakeVerifyLedger ledger = new ([row("AMP-1", "e-1"), row("AMP-2", "e-2")]);
    FakeVerifyStore st = new ({walletsEnabled: true, memberBudget: 1}, ledger, engagements, [m], (), [mt]);
    FakeMemberPosts member = new;
    scoring:VerifyReport r = <scoring:VerifyReport>check runCoinVerification(st, member, (), syncCipher, (), VERIFY_T0);
    test:assertEquals([r.status, r.stopReason, r.checked], [scoring:VERIFY_STOPPED, scoring:VERIFY_STOP_BUDGET, 1]);
    test:assertEquals(member.log().length(), 1, "no call past the budget");
    test:assertEquals(ledger.marked(), {"AMP-1": "VERIFIED"}, "the rest waits for the next run");

    FakeVerifyLedger limited = new ([row("AMP-s", "e-slow"), row("AMP-1", "e-1")]);
    FakeVerifyStore st2 = new ({walletsEnabled: true}, limited, engagements, [m], (), [mt]);
    scoring:VerifyReport r2 = <scoring:VerifyReport>check runCoinVerification(st2, new FakeMemberPosts(), (), syncCipher,
            (), VERIFY_T0);
    test:assertEquals([r2.status, r2.stopReason], [scoring:VERIFY_STOPPED, scoring:VERIFY_STOP_RATE_LIMITED]);
    test:assertEquals(limited.marked(), {});

    FakeVerifyLedger down = new ([row("AMP-d", "e-down")]);
    FakeVerifyStore st3 = new ({walletsEnabled: true}, down, engagements, [m], (), [mt]);
    scoring:VerifyReport r3 = <scoring:VerifyReport>check runCoinVerification(st3, new FakeMemberPosts(), (), syncCipher,
            (), VERIFY_T0);
    test:assertEquals(r3.stopReason, scoring:VERIFY_STOP_UNAVAILABLE);
}

@test:Config
function testVerifySettingsAndSchedulerKey() {
    VerifySettings s = toVerifySettings([
        setting("coin.wallets_enabled", true), setting("coin.verify_max_age_hours", 24),
        setting("engagement.daily_call_budget", 100), setting("coin.verify_member_daily_call_budget", 5)
    ]);
    test:assertEquals(s, {walletsEnabled: true, maxAgeHours: 24, pageBudget: 100, memberBudget: 5});
    test:assertEquals(toVerifySettings([setting("coin.verify_max_age_hours", 0),
        setting("coin.verify_member_daily_call_budget", "x")]), <VerifySettings>{});
    test:assertEquals(toCoinSettings([setting("coin.verify_max_age_hours", 72)]).verifyMaxAgeHours, 72);
    test:assertTrue(schedulerMayCall("POST", ["coins", "verify"]));
    test:assertFalse(schedulerMayCall("GET", ["coins", "verify"]));
}

