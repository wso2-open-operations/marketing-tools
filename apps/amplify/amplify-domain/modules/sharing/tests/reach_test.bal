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


// The reach refresh rules on fakes: budget, skips, stops and the post cap.

import ballerina/test;
import ballerina/time;

isolated class FakeReachStore {
    *ReachStore;

    private ReachTarget[] queue;
    private int budgetLeft;
    private ReachReading[] saved = [];

    isolated function init(ReachTarget[] queue, int budgetLeft) {
        self.queue = queue.clone();
        self.budgetLeft = budgetLeft;
    }

    public isolated function targets(time:Utc since, string today) returns ReachTarget[]|error {
        lock {
            return self.queue.clone();
        }
    }

    public isolated function takeCall(time:Utc now, int budget) returns boolean|error {
        lock {
            if self.budgetLeft <= 0 {
                return false;
            }
            self.budgetLeft -= 1;
            return true;
        }
    }

    public isolated function saveReading(ReachTarget target, ReachReading reading, time:Utc now) returns error? {
        lock {
            self.saved.push(reading.clone());
        }
    }

    isolated function savedCount() returns int {
        lock {
            return self.saved.length();
        }
    }
}

isolated class FakeReachReader {
    *ReachReader;

    private final map<string> & readonly outcomes;

    isolated function init(map<string> outcomes) {
        self.outcomes = outcomes.cloneReadOnly();
    }

    public isolated function read(ReachTarget target) returns ReachReading|ReachSkip|SourceError {
        string outcome = self.outcomes[target.postUrn] ?: "OK";
        match outcome {
            "OK" => {
                return {impressions: 100, membersReached: 60};
            }
            "NO_TOKEN" => {
                return "NO_TOKEN";
            }
            "FORBIDDEN" => {
                return error SourceError("refused", reason = "REJECTED");
            }
            "UNAUTHORIZED" => {
                return error SourceError("refused", reason = "UNAUTHORIZED");
            }
            _ => {
                return error SourceError("stop", reason = "RATE_LIMITED");
            }
        }
    }
}

function reachTarget(string id, string employee) returns ReachTarget =>
    {engagementId: id, employeeId: employee, postUrn: "urn:li:share:" + id};

final time:Utc REACH_NOW = [1795000000, 0];

@test:Config {}
function testReachReadsEveryTargetWithinTheBudget() returns error? {
    FakeReachStore st = new ([reachTarget("1", "a"), reachTarget("2", "b")], 10);
    ReachReport r = check refreshReach(st, new FakeReachReader({}), {}, REACH_NOW);
    test:assertEquals(r, {status: "DONE", targets: 2, measured: 2, skippedNoToken: 0, skippedNotReadable: 0, calls: 4});
    test:assertEquals(st.savedCount(), 2);
}

@test:Config {}
function testReachStopsWhenTheBudgetIsSpent() returns error? {
    FakeReachStore st = new ([reachTarget("1", "a"), reachTarget("2", "b")], 3);
    ReachReport r = check refreshReach(st, new FakeReachReader({}), {}, REACH_NOW);
    test:assertEquals(r.status, "BUDGET_REACHED");
    test:assertEquals(r.measured, 1, "the second post needs two calls, one is left");
}

@test:Config {}
function testReachSkipsAnEmployeeWithoutAUsableToken() returns error? {
    FakeReachStore st = new ([reachTarget("1", "a"), reachTarget("2", "a"), reachTarget("3", "b"),
        reachTarget("4", "c"), reachTarget("5", "d")], 100);
    ReachReport r = check refreshReach(st, new FakeReachReader({"urn:li:share:1": "NO_TOKEN",
        "urn:li:share:4": "FORBIDDEN", "urn:li:share:5": "UNAUTHORIZED"}), {}, REACH_NOW);
    test:assertEquals(r.status, "DONE");
    test:assertEquals(r.measured, 1);
    test:assertEquals(r.skippedNoToken, 3, "a's second post is skipped without a call; d's token was refused");
    test:assertEquals(r.skippedNotReadable, 1);
    test:assertEquals(r.calls, 8);
}

@test:Config {}
function testReachStopsOnARateLimitAndCapsPosts() returns error? {
    FakeReachStore st = new ([reachTarget("1", "a"), reachTarget("2", "b")], 100);
    ReachReport limited = check refreshReach(st, new FakeReachReader({"urn:li:share:1": "LIMIT"}), {}, REACH_NOW);
    test:assertEquals(limited.status, "RATE_LIMITED");
    test:assertEquals(limited.measured, 0);
    ReachReport capped = check refreshReach(new FakeReachStore([reachTarget("1", "a"), reachTarget("2", "b")], 100),
            new FakeReachReader({}), {maxPosts: 1}, REACH_NOW);
    test:assertEquals(capped.status, "POST_LIMIT");
    test:assertEquals(capped.measured, 1);
}
