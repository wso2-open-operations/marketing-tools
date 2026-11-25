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

// The engagement sync use case on in-memory ports: matching, windows, de-duplication, cursors, the call budget and
// stopping on a rate limit.

import amplify_common.types;

import ballerina/test;
import ballerina/time;

const string PAGE = "urn:li:organization:1477";
const string POST = "urn:li:share:7001";
const string MEMBER_A = "urn:li:person:aaa";
const string MEMBER_B = "urn:li:person:bbb";
final time:Utc SYNC_NOW = [1790100000, 0];
final SyncCampaign CAMPAIGN = {id: "0192f0e0-0000-7000-8000-00000000c001", resourceUrn: POST,
    opensAt: [1790000000, 0], closesAt: [1790900000, 0]};

isolated class FakeSource {
    *EngagementSource;
    private Observed[] reactionItems = [];
    private Observed[] commentItems = [];
    private Observed[] reshareItems = [];
    private string? failWith = ();
    private string[] calls = [];

    isolated function init(Observed[] reactions, Observed[] comments, Observed[] reshares) {
        self.reactionItems = reactions.clone();
        self.commentItems = comments.clone();
        self.reshareItems = reshares.clone();
    }

    isolated function failNext(string? reason) {
        lock {
            self.failWith = reason;
        }
    }

    isolated function callLog() returns string[] {
        lock {
            return self.calls.clone();
        }
    }

    public isolated function reactions(string targetUrn, int 'start, int count) returns ObservedPage|SourceError {
        lock {
            self.calls.push(string `reactions ${'start}`);
            return self.page(self.reactionItems, 'start, count).clone();
        }
    }

    public isolated function comments(string targetUrn, int 'start, int count) returns ObservedPage|SourceError {
        lock {
            self.calls.push(string `comments ${'start}`);
            return self.page(self.commentItems, 'start, count).clone();
        }
    }

    public isolated function reshares(int startMs, int endMs, int 'start, int count) returns ObservedPage|SourceError {
        lock {
            self.calls.push(string `reshares ${startMs}-${endMs}`);
            return self.page(self.reshareItems, 'start, count).clone();
        }
    }

    private isolated function page(Observed[] all, int 'start, int count) returns ObservedPage|SourceError {
        lock {
            string? reason = self.failWith;
            if reason is string {
                return error SourceError("stop", reason = <SourceStop>reason);
            }
        }
        int end = 'start + count < all.length() ? 'start + count : all.length();
        Observed[] items = 'start >= all.length() ? [] : all.slice('start, end);
        return {items, fetched: items.length()};
    }
}

isolated class FakeSyncStore {
    *SyncStore;
    private map<string> cursors = {};
    private int used = 0;
    private Engagement[] recorded = [];
    private string[] detected = [];
    private final SyncCampaign[] campaigns;

    isolated function init(SyncCampaign[] campaigns, int used = 0) {
        self.campaigns = campaigns.clone();
        self.used = used;
    }

    public isolated function openCampaigns(time:Utc now) returns SyncCampaign[]|error {
        lock {
            return self.campaigns.clone();
        }
    }

    public isolated function employeesOf(string[] memberUrns) returns map<types:EmployeeId>|error {
        map<types:EmployeeId> found = {};
        foreach string m in memberUrns {
            if m == MEMBER_A {
                found[m] = "emp-a";
            }
        }
        return found;
    }

    public isolated function cursor(string resourceUrn, SyncEndpoint endpoint) returns string|error? {
        lock {
            return self.cursors[resourceUrn + "|" + endpoint];
        }
    }

    public isolated function saveCursor(string resourceUrn, SyncEndpoint endpoint, string cursor, time:Utc now)
            returns error? {
        lock {
            self.cursors[resourceUrn + "|" + endpoint] = cursor;
        }
    }

    public isolated function takeCall(time:Utc now, int budget) returns boolean|error {
        lock {
            if self.used >= budget {
                return false;
            }
            self.used += 1;
            return true;
        }
    }

    public isolated function recordSynced(Engagement engagement, time:Utc now) returns boolean|error {
        lock {
            boolean reshare = engagement.action == types:REPOST || engagement.action == types:REPOST_COMMENTARY;
            foreach Engagement e in self.recorded {
                boolean sameAction = e.action == engagement.action;
                boolean bothShares = reshare && (e.action == types:REPOST || e.action == types:REPOST_COMMENTARY);
                if e.employeeId == engagement.employeeId && e.targetResourceUrn == engagement.targetResourceUrn
                        && (sameAction || bothShares) {
                    if reshare {
                        self.detected.push(engagement.employeeId);
                    }
                    return false;
                }
            }
            self.recorded.push(engagement.clone());
            if reshare {
                self.detected.push(engagement.employeeId);
            }
            return true;
        }
    }

    isolated function all() returns Engagement[] {
        lock {
            return self.recorded.clone();
        }
    }

    isolated function cursorOf(string key) returns string? {
        lock {
            return self.cursors[key];
        }
    }

    isolated function detections() returns string[] {
        lock {
            return self.detected.clone();
        }
    }
}

function observed(ObservedKind kind, string actor, int atSeconds, string? activity = (), boolean words = false)
        returns Observed =>
    {kind, actorUrn: actor, targetUrn: POST, activityUrn: activity, hasCommentary: words, occurredAt: [atSeconds, 0]};

function settings(int budget = 450) returns SyncSettings => {pageUrn: PAGE, dailyBudget: budget, pageSize: 2};

@test:Config {}
function testSyncRecordsReactionCommentAndRepost() returns error? {
    FakeSource linkedIn = new ([
        observed("REACTION", MEMBER_A, 1790050000),
        observed("REACTION", MEMBER_B, 1790050001),                          // not connected: dropped
        observed("REACTION", "urn:li:organization:1477", 1790050002)         // the page itself: dropped
    ], [
        observed("COMMENT", MEMBER_A, 1790050010, "urn:li:comment:(urn:li:share:7001,1)"),
        observed("COMMENT", MEMBER_A, 1789000000, "urn:li:comment:(urn:li:share:7001,2)")  // before the window
    ], [
        observed("RESHARE", MEMBER_A, 1790050020, "urn:li:share:9001", true)
    ]);
    FakeSyncStore store = new ([CAMPAIGN]);
    SyncReport report = check syncEngagement(linkedIn, store, settings(), SYNC_NOW);
    test:assertEquals(report.status, "DONE");
    test:assertEquals([report.reactions, report.comments, report.reposts], [1, 1, 1]);
    test:assertEquals(report.dropped, 3);

    Engagement[] rows = store.all();
    test:assertEquals(rows.length(), 3);
    foreach Engagement e in rows {
        test:assertEquals(e.providerApi, types:COMMUNITY_MANAGEMENT);
        test:assertEquals(e.origin, types:API_SYNC);
        test:assertEquals(e.employeeId, "emp-a");
        test:assertEquals(e.campaignId, CAMPAIGN.id);
        test:assertEquals(e.targetResourceUrn, POST);
    }
    test:assertEquals(rows[0].action, types:REACTION);
    test:assertEquals(rows[0].activityUrn, (), "a reaction keeps no activity URN (it embeds the member URN)");
    test:assertEquals(rows[1].action, types:COMMENT);
    test:assertEquals(rows[2].action, types:REPOST_COMMENTARY, "a reshare with words");
    test:assertEquals(store.detections(), ["emp-a"], "the reshare marks the native intent");

    // Cursors: three reactions read (two pages of two), two comments; the notifications end at the run time.
    test:assertEquals(store.cursorOf(POST + "|REACTIONS"), "3");
    test:assertEquals(store.cursorOf(POST + "|COMMENTS"), "2");
    test:assertEquals(store.cursorOf(PAGE + "|SHARE_NOTIFICATIONS"), epochMillis(SYNC_NOW).toString());

    // A rerun reads from the cursors, records nothing new, and reads notifications again with an hour's overlap.
    SyncReport again = check syncEngagement(linkedIn, store, settings(), [1790103600, 0]);
    test:assertEquals([again.reactions, again.comments, again.reposts], [0, 0, 0]);
    test:assertEquals(again.alreadyRecorded, 1, "the reshare seen again is already covered");
    string[] log = linkedIn.callLog();
    test:assertEquals(log[log.length() - 1],
            string `reshares ${epochMillis(SYNC_NOW) - 3600000}-${epochMillis([1790103600, 0])}`);
}

@test:Config {}
function testReshareAfterInAppShareIsSkipped() returns error? {
    FakeSyncStore store = new ([CAMPAIGN]);
    // The in-app REPOST is already there.
    _ = check store.recordSynced({id: "x", provider: types:LINKEDIN, providerApi: types:SHARE_ON_LINKEDIN,
        origin: types:IN_APP, targetResourceUrn: POST, campaignId: CAMPAIGN.id, actorMemberUrn: MEMBER_A,
        employeeId: "emp-a", action: types:REPOST, activityUrn: "urn:li:share:8000", occurredAt: SYNC_NOW,
        observedAt: SYNC_NOW, lastVerifiedAt: (), deletedAt: ()}, SYNC_NOW);
    FakeSource linkedIn = new ([], [], [observed("RESHARE", MEMBER_A, 1790050020, "urn:li:share:8000")]);
    SyncReport report = check syncEngagement(linkedIn, store, settings(), SYNC_NOW);
    test:assertEquals(report.reposts, 0);
    test:assertEquals(report.alreadyRecorded, 1);
    test:assertEquals(store.all().length(), 1, "no second share engagement");
}

@test:Config {}
function testBudgetAndRateLimitStopKeepingCursors() returns error? {
    FakeSource linkedIn = new ([observed("REACTION", MEMBER_A, 1790050000), observed("REACTION", MEMBER_A, 1790050001),
        observed("REACTION", MEMBER_A, 1790050002)], [], []);
    // One call left today: one page of reactions, then the budget stops the run.
    FakeSyncStore store = new ([CAMPAIGN], 449);
    SyncReport report = check syncEngagement(linkedIn, store, settings(), SYNC_NOW);
    test:assertEquals(report.status, "BUDGET_REACHED");
    test:assertEquals(report.calls, 1);
    test:assertEquals(store.cursorOf(POST + "|REACTIONS"), "2");
    test:assertEquals(store.cursorOf(PAGE + "|SHARE_NOTIFICATIONS"), (), "notifications not read");

    FakeSyncStore fresh = new ([CAMPAIGN]);
    linkedIn.failNext("RATE_LIMITED");
    SyncReport limited = check syncEngagement(linkedIn, fresh, settings(), SYNC_NOW);
    test:assertEquals(limited.status, "RATE_LIMITED");
    test:assertEquals(fresh.cursorOf(POST + "|REACTIONS"), (), "the cursor stays");
    test:assertEquals(fresh.all().length(), 0);

    FakeSyncStore none = new ([]);
    SyncReport idle = check syncEngagement(linkedIn, none, settings(), SYNC_NOW);
    test:assertEquals(idle, {status: "DONE", campaigns: 0, calls: 0, reactions: 0, comments: 0, reposts: 0,
        alreadyRecorded: 0, dropped: 0}, "no open campaign, no call");
}

@test:Config {}
function testSyncedActionAndTimeHelpers() {
    test:assertEquals(syncedAction(observed("RESHARE", MEMBER_A, 1)), types:REPOST);
    test:assertEquals(syncedAction(observed("RESHARE", MEMBER_A, 1, (), true)), types:REPOST_COMMENTARY);
    test:assertEquals(epochMillis([1790000000, 0.25]), 1790000000250);
    test:assertEquals(fromEpochMillis(1790000000250), <time:Utc>[1790000000, 0.25]);
    test:assertFalse(inWindow(observed("REACTION", MEMBER_A, 1790900000), CAMPAIGN), "closesAt is outside");
}

@test:Config {}
function testNativeStatus() {
    NativeIntent intent = {employeeId: "emp-a", campaignId: "c", openedAt: [1790000000, 0], detectedAt: ()};
    test:assertEquals(nativeStatus(intent, [1790000000 + 3600, 0]), LOOKING);
    test:assertEquals(nativeStatus(intent, [1790000000 + 86400, 0]), NOT_FOUND, "24 hours or more");
    intent.detectedAt = [1790000100, 0];
    test:assertEquals(nativeStatus(intent, [1790000000 + 999999, 0]), DETECTED);
}
