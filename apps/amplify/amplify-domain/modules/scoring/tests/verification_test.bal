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

// Pre-coin verification (V027) on fakes: the outcomes, stops, batching, the time limit, the conversion cutoff and
// the PO clearing an action-required row.

import amplify_common.types;

import ballerina/test;
import ballerina/time;

// In-memory ledger with the PostgreSQL repository's verification rules.
isolated class FakeVerifyRepo {
    *VerificationRepository;

    private map<types:LedgerEntry> rows = {};
    private string[] seqOrder = [];

    isolated function add(string reference, string employeeId, types:LedgerSourceType sourceType = types:ENGAGEMENT,
            types:LedgerStatus? status = types:HELD, types:LedgerVerification? verification = (),
            time:Utc? verifiedAt = ()) {
        lock {
            self.rows[reference] = {
                reference, employeeId, campaignId: (), sourceType,
                sourceId: sourceType == types:ENGAGEMENT ? "0190a1b2-0000-7000-8000-00000000000" + self.seqOrder.length().toString() : (),
                action: sourceType == types:ENGAGEMENT ? types:REACTION : (), points: 5, ruleId: (),
                reversesReference: (), reason: (), actorId: types:SYSTEM_ACTOR, correlationId: (), createdAt: DEC1,
                status, statusChangedAt: (), paidAt: (), coinReference: (), verification, verifiedAt
            };
            self.seqOrder.push(reference);
        }
    }

    isolated function row(string reference) returns types:LedgerEntry? {
        lock {
            return self.rows[reference].clone();
        }
    }

    isolated function reversalOf(string reference) returns types:LedgerEntry? {
        lock {
            foreach types:LedgerEntry r in self.rows {
                if r.reversesReference == reference {
                    return r.clone();
                }
            }
            return ();
        }
    }

    public isolated function dueForCheck(time:Utc staleBefore, int 'limit) returns VerifyCandidate[]|error {
        lock {
            VerifyCandidate[] out = [];
            foreach string ref in self.seqOrder {
                types:LedgerEntry r = self.rows.get(ref);
                time:Utc? at = r.verifiedAt;
                boolean due = r.verification is () || (r.verification == types:VERIFIED && at is time:Utc
                    && types:isBefore(at, staleBefore));
                string? sourceId = r.sourceId;
                if r.sourceType != types:ENGAGEMENT || r.status != types:HELD || r.coinReference !is ()
                        || sourceId is () || !due || hasReversalIn(self.rows, ref) {
                    continue;
                }
                if out.length() < 'limit {
                    out.push({reference: ref, employeeId: r.employeeId, engagementId: sourceId, action: r.action});
                }
            }
            return out.clone();
        }
    }

    public isolated function markVerified(types:LedgerReference reference, time:Utc now) returns error? {
        lock {
            types:LedgerEntry r = self.rows.get(reference);
            r.verification = types:VERIFIED;
            r.verifiedAt = now.clone();
            r.verificationReason = ();
        }
    }

    public isolated function markUnverifiable(types:LedgerReference reference, string reason, time:Utc now)
            returns error? {
        lock {
            types:LedgerEntry r = self.rows.get(reference);
            r.status = ();
            r.verification = types:UNVERIFIABLE;
            r.verifiedAt = now.clone();
            r.verificationReason = reason;
        }
    }

    public isolated function reverseRemoved(types:LedgerReference reference, string? correlationId, time:Utc now)
            returns boolean|error {
        lock {
            types:LedgerEntry r = self.rows.get(reference);
            if hasReversalIn(self.rows, reference) {
                return false;
            }
            LedgerAppend a = check reversal(r, (), REASON_NO_LONGER_ON_LINKEDIN, types:SYSTEM_ACTOR, types:newUuidV7(),
                    correlationId.clone(), now.clone());
            r.verification = types:REMOVED;
            r.verifiedAt = now.clone();
            self.rows[a.entry.reference] = a.entry;
            self.seqOrder.push(a.entry.reference);
            return true;
        }
    }

}

isolated function hasReversalIn(map<types:LedgerEntry> rows, string reference) returns boolean {
    foreach types:LedgerEntry r in rows {
        if r.reversesReference == reference {
            return true;
        }
    }
    return false;
}

// Answers per reference; the default is PRESENT.
isolated class FakeChecker {
    *EngagementChecker;

    private final map<CheckResult|string> & readonly answers;
    private int calls = 0;

    isolated function init(map<CheckResult|string> answers = {}) {
        self.answers = answers.cloneReadOnly();
    }

    public isolated function verify(VerifyCandidate candidate, time:Utc now) returns CheckResult|VerifyStop|error {
        lock {
            self.calls += 1;
        }
        CheckResult|string? a = self.answers[candidate.reference];
        if a is string {
            return a == "boom" ? error("database down") : verifyStop(a);
        }
        return a ?: {outcome: CHECK_PRESENT};
    }

    isolated function callCount() returns int {
        lock {
            return self.calls;
        }
    }
}

@test:Config
function verificationRecordsEachOutcome() returns error? {
    FakeVerifyRepo repo = new;
    repo.add("AMP-a", "e1");
    repo.add("AMP-b", "e1");
    repo.add("AMP-c", "e2");
    repo.add("ADJ-1", "e2", types:ADJUSTMENT);
    repo.add("AMP-held-po", "e2", verification = types:PO_CLEARED, verifiedAt = DEC1);
    VerifyReport r = check verifyForCoins(repo, new FakeChecker({
        "AMP-b": {outcome: CHECK_GONE},
        "AMP-c": {outcome: CHECK_UNVERIFIABLE, reason: VERIFY_NO_TOKEN}
    }), {}, DEC1);
    test:assertEquals(r.status, VERIFY_DONE);
    test:assertEquals([r.checked, r.verified, r.removed, r.actionRequired], [3, 1, 1, 1]);
    test:assertEquals(r.unverifiableByReason, {"NO_TOKEN": 1});

    types:LedgerEntry a = <types:LedgerEntry>repo.row("AMP-a");
    test:assertEquals([a.verification, a.status], [types:VERIFIED, types:HELD]);
    test:assertEquals(a.verifiedAt, DEC1);

    types:LedgerEntry b = <types:LedgerEntry>repo.row("AMP-b");
    test:assertEquals([b.verification, b.status], [types:REMOVED, types:HELD], "the original stays HELD");
    types:LedgerEntry rev = <types:LedgerEntry>repo.reversalOf("AMP-b");
    test:assertEquals([rev.points, rev.reason, rev.actorId, rev.status], [-5, REASON_NO_LONGER_ON_LINKEDIN,
        types:SYSTEM_ACTOR, types:HELD]);

    types:LedgerEntry c = <types:LedgerEntry>repo.row("AMP-c");
    test:assertEquals([c.verification, c.status, c.verificationReason], [types:UNVERIFIABLE, (), VERIFY_NO_TOKEN],
            "action required for the PO team");

    // Nothing is due any more: a re-run checks nothing.
    FakeChecker again = new;
    VerifyReport r2 = check verifyForCoins(repo, again, {}, DEC1);
    test:assertEquals([r2.checked, again.callCount()], [0, 0]);
}

@test:Config
function verificationRechecksOnlyStaleRows() returns error? {
    FakeVerifyRepo repo = new;
    repo.add("AMP-fresh", "e1", verification = types:VERIFIED, verifiedAt = time:utcAddSeconds(DEC1, -3600 * 23));
    repo.add("AMP-stale", "e1", verification = types:VERIFIED, verifiedAt = time:utcAddSeconds(DEC1, -3600 * 25));
    FakeChecker checker = new;
    VerifyReport r = check verifyForCoins(repo, checker, {maxAgeHours: 48}, DEC1);
    test:assertEquals([r.checked, checker.callCount()], [1, 1], "half the max age: 24 h");
    test:assertEquals((<types:LedgerEntry>repo.row("AMP-stale")).verifiedAt, DEC1);
}

@test:Config
function verificationStopsAndLeavesTheRowForTheNextRun() returns error? {
    FakeVerifyRepo repo = new;
    repo.add("AMP-1", "e1");
    repo.add("AMP-2", "e1");
    repo.add("AMP-3", "e1");
    VerifyReport r = check verifyForCoins(repo, new FakeChecker({"AMP-2": VERIFY_STOP_BUDGET}), {}, DEC1);
    test:assertEquals([r.status, r.stopReason, r.checked], [VERIFY_STOPPED, VERIFY_STOP_BUDGET, 1]);
    test:assertEquals((<types:LedgerEntry>repo.row("AMP-2")).verification, (), "nothing recorded");
    test:assertEquals((<types:LedgerEntry>repo.row("AMP-3")).verification, ());

    VerifyReport next = check verifyForCoins(repo, new FakeChecker(), {}, DEC1);
    test:assertEquals([next.status, next.checked], [VERIFY_DONE, 2], "the next run carries on");
}

@test:Config
function verificationBatchesAndTimeLimit() returns error? {
    FakeVerifyRepo repo = new;
    foreach int i in 1 ... 5 {
        repo.add("AMP-" + i.toString(), "e1");
    }
    VerifyReport r = check verifyForCoins(repo, new FakeChecker(), {batchSize: 2}, DEC1);
    test:assertEquals([r.status, r.checked], [VERIFY_DONE, 5], "reads batch after batch");

    FakeVerifyRepo slow = new;
    slow.add("AMP-x", "e1");
    VerifyReport p = check verifyForCoins(slow, new FakeChecker(), {maxSeconds: -1}, DEC1);
    test:assertEquals([p.status, p.checked], [VERIFY_PARTIAL, 0]);
}

@test:Config
function verificationErrorEndsTheRun() {
    FakeVerifyRepo repo = new;
    repo.add("AMP-1", "e1");
    VerifyReport|error r = verifyForCoins(repo, new FakeChecker({"AMP-1": "boom"}), {}, DEC1);
    test:assertTrue(r is error && r !is VerifyStop);
}

@test:Config
function unverifiableWithoutReasonDefaultsToNoActivity() returns error? {
    FakeVerifyRepo repo = new;
    repo.add("AMP-1", "e1");
    _ = check verifyForCoins(repo, new FakeChecker({"AMP-1": {outcome: CHECK_UNVERIFIABLE}}), {}, DEC1);
    test:assertEquals((<types:LedgerEntry>repo.row("AMP-1")).verificationReason, VERIFY_NO_ACTIVITY);
}

function engagementEntry(types:LedgerVerification? verification, time:Utc? verifiedAt,
        types:LedgerStatus? status = types:HELD) returns types:LedgerEntry => {
    reference: "AMP-1", employeeId: "e1", campaignId: (), sourceType: types:ENGAGEMENT, sourceId: "s", action: types:REACTION,
    points: 1, ruleId: "r", reversesReference: (), reason: (), actorId: "system", correlationId: (), createdAt: DEC1,
    status, statusChangedAt: (), paidAt: (), coinReference: (), verification, verifiedAt
};

@test:Config
function conversionTakesOnlyRecentlyVerifiedEngagementRows() {
    time:Utc cutoff = verifiedSince({verifyMaxAgeHours: 48}, DEC1);
    test:assertEquals(time:utcDiffSeconds(DEC1, cutoff), 172800d);
    test:assertEquals(time:utcDiffSeconds(DEC1, verifiedSince({verifyMaxAgeHours: 0}, DEC1)), 172800d,
            "a nonsense value falls back to 48");
    test:assertEquals(time:utcDiffSeconds(DEC1, recheckBefore(48, DEC1)), 86400d);

    test:assertTrue(isConvertible(engagementEntry(types:VERIFIED, time:utcAddSeconds(DEC1, -3600)), cutoff));
    test:assertTrue(isConvertible(engagementEntry(types:VERIFIED, cutoff), cutoff), "exactly at the cutoff");
    test:assertFalse(isConvertible(engagementEntry(types:VERIFIED, time:utcAddSeconds(cutoff, -1)), cutoff), "too old");
    test:assertFalse(isConvertible(engagementEntry((), ()), cutoff), "never checked");
    test:assertTrue(isConvertible(engagementEntry(types:PO_CLEARED, time:utcAddSeconds(DEC1, -86400 * 90)), cutoff),
            "a PO clearance does not age");
    test:assertFalse(isConvertible(engagementEntry(types:UNVERIFIABLE, DEC1, ()), cutoff), "action required");
    test:assertTrue(isConvertible(engagementEntry((), ())), "no cutoff: verification not considered");
    test:assertTrue(isConvertible(entry(types:HELD), cutoff), "adjustments are not checked");
}

@test:Config
function poClearsAnActionRequiredRow() returns error? {
    InMemoryLedger ledger = new;
    string ref = check types:awardReference(types:LINKEDIN, "urn:li:share:1", "e1", types:REACTION);
    string other = check types:awardReference(types:LINKEDIN, "urn:li:share:2", "e1", types:REACTION);
    types:LedgerEntry flagged = engagementEntry(types:UNVERIFIABLE, DEC1, ());
    flagged.reference = ref;
    _ = check ledger.append({entry: flagged, event: pointsChangedEvent(flagged)});
    types:LedgerEntry cleared = check settleEntry(ledger, ref, types:HELD, "po-1", DEC1);
    test:assertEquals(cleared.status, types:HELD);

    test:assertEquals(code(settleEntry(ledger, ref, types:HELD, "e1", DEC1)), types:ERR_SELF_REVIEW);
    test:assertEquals(code(settleEntry(ledger, other, types:HELD, "po-1", DEC1)), types:ERR_NOT_FOUND);
    test:assertEquals(code(settleEntry(ledger, ref, types:PAID, "po-1", DEC1)), types:ERR_PAID_NOT_ALLOWED);
    test:assertTrue(settleEntry(ledger, "bad ref", types:HELD, "po-1", DEC1) is error);

    types:LedgerEntry flaggedAgain = check settleEntry(ledger, ref, (), "po-1", DEC1);
    test:assertEquals(flaggedAgain.status, (), "a PO can set a row action required too");
}
