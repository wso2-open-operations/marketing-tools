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

import amplify_common.events;
import amplify_common.types;

import ballerina/test;
import ballerina/time;

final time:Utc T0 = [1790000000, 0];

// Append-only fake: `append` is insert-if-absent; there is no way to change a fact.
isolated class InMemoryLedger {
    *LedgerRepository;
    private map<types:LedgerEntry> rows = {};
    private events:OutboxEvent[] outbox = [];

    public isolated function append(LedgerAppend append) returns boolean|error {
        lock {
            types:LedgerEntry entry = append.entry.clone();
            if self.rows.hasKey(entry.reference) {
                return false;
            }
            types:LedgerReference? reverses = entry.reversesReference;
            if reverses is string {
                foreach types:LedgerEntry row in self.rows {
                    if row.reversesReference == reverses {
                        return false;
                    }
                }
            }
            self.rows[entry.reference] = entry;
            self.outbox.push(append.event.clone());
            return true;
        }
    }

    public isolated function findByReference(types:LedgerReference reference) returns types:LedgerEntry|error? {
        lock {
            return self.rows[reference].clone();
        }
    }

    public isolated function findReversalOf(types:LedgerReference reference) returns types:LedgerEntry|error? {
        lock {
            foreach types:LedgerEntry row in self.rows {
                if row.reversesReference == reference {
                    return row.clone();
                }
            }
            return ();
        }
    }

    public isolated function updateSettlement(types:LedgerReference reference, types:LedgerStatus? status, time:Utc changedAt)
            returns error? {
        lock {
            types:LedgerEntry? row = self.rows[reference];
            if row is types:LedgerEntry {
                row.status = status;
                row.statusChangedAt = changedAt;
            }
        }
    }

    public isolated function total(string employeeId) returns int {
        lock {
            int sum = 0;
            foreach types:LedgerEntry row in self.rows {
                if row.employeeId == employeeId {
                    sum += row.points;
                }
            }
            return sum;
        }
    }

    public isolated function size() returns int {
        lock {
            return self.rows.length();
        }
    }
}

isolated class InMemoryRules {
    *PointRuleRepository;
    private PointRule[] rows = [];

    public isolated function all() returns PointRule[]|error {
        lock {
            return self.rows.clone();
        }
    }

    public isolated function insert(PointRule rule) returns error? {
        lock {
            self.rows.push(rule.clone());
        }
    }
}

function rules() returns PointRule[] => [
    rule("r1", types:REPOST, 10, T0),
    rule("r2", types:REPOST_COMMENTARY, 20, T0),
    rule("r3", types:OWN_POST, 30, T0),
    rule("r4", types:OWN_POST_AMPLIFIED, 50, T0),
    rule("r5", types:REPOST, 15, types:addDays(T0, 10))
];

function rule(string id, types:PointAction action, int points, time:Utc effectiveFrom) returns PointRule =>
    {id, action, points, effectiveFrom, createdBy: "po-1", createdAt: T0};

function engagement() returns EngagementFact => {engagementId: "g1", provider: types:LINKEDIN,
    targetResourceUrn: "urn:li:share:6999", employeeId: "emp-1", action: types:REPOST, campaignId: "c1"};

function externalShare() returns ExternalShareFact => {externalShareId: "x1", provider: "medium",
    evidenceUrl: "https://medium.com/@avery/wso2", employeeId: "emp-1", campaignId: (), approvedAt: types:addDays(T0, 1)};

isolated function code(any|error result) returns string {
    if result is types:DomainError {
        return result.detail().code;
    }
    return result is error ? "ERROR" : "OK";
}

@test:Config
function ruleVersionInForce() returns error? {
    test:assertEquals((check ruleInForce(rules(), types:REPOST, types:addDays(T0, 9))).points, 10);
    test:assertEquals((check ruleInForce(rules(), types:REPOST, types:addDays(T0, 10))).points, 15, "new version applies from effective_from");
    test:assertEquals(code(ruleInForce(rules(), types:REPOST, types:addDays(T0, -1))), types:ERR_RULE_NOT_FOUND);
    test:assertEquals(code(ruleInForce(rules(), types:SHARE, T0)), types:ERR_RULE_NOT_FOUND);
}

@test:Config
function ruleVersionsAreForwardOnlyAndUnique() returns error? {
    InMemoryRules repo = new;
    PointRule first = check setPointRule(repo, types:REPOST, 10, (), "po-1", T0);
    test:assertEquals(first.effectiveFrom, T0);
    test:assertEquals(code(setPointRule(repo, types:REPOST, 12, T0, "po-1", T0)), types:ERR_RULE_VERSION_EXISTS);
    test:assertEquals(code(setPointRule(repo, types:REPOST, 12, types:addDays(T0, -1), "po-1", T0)), types:ERR_RULE_BACKDATED);
    test:assertEquals(code(setPointRule(repo, types:REPOST, -1, (), "po-1", T0)), types:ERR_INVALID_POINTS);
    _ = check setPointRule(repo, types:REPOST, 12, types:addDays(T0, 1), "po-1", T0);
    test:assertEquals((check repo.all()).length(), 2, "versioned: old rows stay");
}

@test:Config
function engagementAwardIsHeldAndDeterministic() returns error? {
    LedgerAppend a = check awardForEngagement(rules(), engagement(), "run-1", T0);
    test:assertEquals(a.entry.points, 10);
    test:assertEquals(a.entry.status, types:HELD, "phase 1 default");
    test:assertEquals(a.entry.ruleId, "r1");
    test:assertEquals(a.entry.reference.length(), types:AWARD_REFERENCE_LENGTH);
    test:assertEquals(a.entry.reference,
            check types:awardReference(types:LINKEDIN, "urn:li:share:6999", "emp-1", types:REPOST));
    test:assertEquals(a.event.eventType, events:POINTS_AWARDED);
    LedgerAppend later = check awardForEngagement(rules(), engagement(), "run-2", types:addDays(T0, 11));
    test:assertEquals(later.entry.reference, a.entry.reference, "same fact, same key");
}

@test:Config
function oncePerPostPerPersonPerAction() returns error? {
    InMemoryLedger ledger = new;
    test:assertTrue(check appendAward(ledger, check awardForEngagement(rules(), engagement(), (), T0)));
    test:assertFalse(check appendAward(ledger, check awardForEngagement(rules(), engagement(), (), T0)), "re-run is a no-op");
    test:assertEquals(ledger.size(), 1);
    test:assertEquals(ledger.total("emp-1"), 10);
}

@test:Config
function externalShareAwardAndAmplifiedTopUp() returns error? {
    InMemoryLedger ledger = new;
    LedgerAppend own = check awardForExternalShare(rules(), externalShare(), (), types:addDays(T0, 1));
    test:assertEquals(own.entry.action, types:OWN_POST);
    test:assertEquals(own.entry.sourceType, types:EXTERNAL_SHARE);
    test:assertEquals(own.entry.points, 30);
    _ = check appendAward(ledger, own);

    LedgerAppend topUp = check amplifiedTopUp(rules(), externalShare(), check ownPostNet(ledger, externalShare()), (),
            types:addDays(T0, 2));
    test:assertEquals(topUp.entry.action, types:OWN_POST_AMPLIFIED);
    test:assertEquals(topUp.entry.points, 20, "C4: 50 - 30, a top-up row, not an update");
    test:assertNotEquals(topUp.entry.reference, own.entry.reference);
    _ = check appendAward(ledger, topUp);
    test:assertEquals(ledger.size(), 2, "original OWN_POST row stays");
    test:assertEquals(ledger.total("emp-1"), 50, "employee ends on the amplified tier");
    test:assertFalse(check appendAward(ledger,
            check amplifiedTopUp(rules(), externalShare(), check ownPostNet(ledger, externalShare()), (), T0)), "top-up once");
}

@test:Config
function topUpNeedsHigherTier() {
    PointRule[] flat = [rule("a", types:OWN_POST, 30, T0), rule("b", types:OWN_POST_AMPLIFIED, 30, T0)];
    test:assertEquals(code(amplifiedTopUp(flat, externalShare(), 30, (), T0)), types:ERR_TOP_UP_NOT_POSITIVE);
}

// Round 2: the top-up is priced against the ledger, not the rules, so reversing the own post doesn't leave
// the employee short of the amplified tier.
@test:Config
function topUpAfterOwnPostReversalPaysTheWholeTier() returns error? {
    InMemoryLedger ledger = new;
    LedgerAppend own = check awardForExternalShare(rules(), externalShare(), (), types:addDays(T0, 1));
    _ = check appendAward(ledger, own);
    _ = check reverseEntry(ledger, own.entry.reference, "Reassessing", "po-1", (), types:addDays(T0, 2));
    test:assertEquals(ledger.total("emp-1"), 0, "own post reversed to 0");
    int net = check ownPostNet(ledger, externalShare());
    test:assertEquals(net, 0, "nothing left for OWN_POST on the ledger");
    LedgerAppend topUp = check amplifiedTopUp(rules(), externalShare(), net, (), types:addDays(T0, 2));
    test:assertEquals(topUp.entry.points, 50, "0 awarded + 50 = the amplified tier, not the 20 rule gap");
    _ = check appendAward(ledger, topUp);
    test:assertEquals(ledger.total("emp-1"), 50, "the employee ends on the amplified tier after all");
}

@test:Config
function reversalCancelsOnceWithReason() returns error? {
    InMemoryLedger ledger = new;
    LedgerAppend a = check awardForEngagement(rules(), engagement(), (), T0);
    _ = check appendAward(ledger, a);
    test:assertEquals(code(reverseEntry(ledger, a.entry.reference, " ", "po-1", (), T0)), types:ERR_REASON_REQUIRED);
    types:LedgerEntry rev = check reverseEntry(ledger, a.entry.reference, "Duplicate", "po-1", "req-1", T0);
    test:assertEquals(rev.points, -10);
    test:assertEquals(rev.sourceType, types:REVERSAL);
    test:assertEquals(rev.reversesReference, a.entry.reference);
    test:assertEquals(rev.actorId, "po-1");
    test:assertTrue(rev.reference.startsWith(types:REVERSAL_PREFIX));
    test:assertEquals(ledger.total("emp-1"), 0);
    test:assertEquals(code(reverseEntry(ledger, a.entry.reference, "again", "po-1", (), T0)), types:ERR_ALREADY_REVERSED);
    test:assertEquals(code(reverseEntry(ledger, rev.reference, "undo", "po-1", (), T0)), types:ERR_CANNOT_REVERSE_REVERSAL);
    test:assertEquals(code(reverseEntry(ledger, "AMP-nope", "x", "po-1", (), T0)), types:ERR_INVALID_LEDGER_REFERENCE);
    test:assertEquals(ledger.size(), 2, "corrections are new rows; the award row is untouched");
    types:LedgerEntry? original = check ledger.findByReference(a.entry.reference);
    test:assertEquals(original, a.entry);
}

@test:Config
function adjustmentNeedsReasonAndNonZeroPoints() returns error? {
    InMemoryLedger ledger = new;
    test:assertEquals(code(adjustPoints(ledger, "emp-1", 0, "x", "po-1", (), (), T0)), types:ERR_INVALID_POINTS);
    test:assertEquals(code(adjustPoints(ledger, "emp-1", 5, "", "po-1", (), (), T0)), types:ERR_REASON_REQUIRED);
    types:LedgerEntry adj = check adjustPoints(ledger, "emp-1", -5, "Correction", "po-1", (), (), T0);
    test:assertTrue(adj.reference.startsWith(types:ADJUSTMENT_PREFIX));
    test:assertEquals(adj.sourceType, types:ADJUSTMENT);
    test:assertEquals(ledger.total("emp-1"), -5);
}

@test:Config
function aPoCannotAdjustOrReverseTheirOwnPoints() returns error? {
    InMemoryLedger ledger = new;
    test:assertEquals(code(adjustPoints(ledger, "po-1", 10, "Top up", "po-1", (), (), T0)), types:ERR_SELF_REVIEW);
    test:assertEquals(ledger.total("po-1"), 0, "nothing is written");
    types:LedgerEntry own = check adjustPoints(ledger, "emp-1", 10, "Correction", "po-1", (), (), T0);
    test:assertEquals(code(reverseEntry(ledger, own.reference, "Undo", "emp-1", (), T0)), types:ERR_SELF_REVIEW,
        "the person the points belong to can't reverse them either");
    test:assertEquals(ledger.total("emp-1"), 10);
    types:LedgerEntry rev = check reverseEntry(ledger, own.reference, "Undo", "po-1", (), T0);
    test:assertEquals(rev.points, -10);
}

@test:Config
function settlementChangesOnlyStatusAndNoPaidInPhase1() returns error? {
    LedgerAppend a = check awardForEngagement(rules(), engagement(), (), T0);
    types:LedgerEntry flagged = check changeSettlement(a.entry, (), types:addDays(T0, 1));
    test:assertEquals(flagged.status, (), "null = action required");
    types:LedgerEntry expected = a.entry.clone();
    expected.status = ();
    expected.statusChangedAt = types:addDays(T0, 1);
    test:assertEquals(flagged, expected, "every fact is unchanged");
    test:assertEquals(code(changeSettlement(a.entry, types:PAID, T0)), types:ERR_PAID_NOT_ALLOWED);
}
