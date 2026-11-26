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

@test:Config
function removalReversesTheAwardWithItsReasonCode() returns error? {
    InMemoryLedger ledger = new;
    LedgerAppend a = check awardForEngagement(rules(), engagement(), (), T0);
    _ = check appendAward(ledger, a);
    Removal r = check removeInvalidActivity(ledger, a.entry.reference, types:REMOVAL_DUPLICATE, "  same repost twice ",
            "po-1", "req-9", types:addDays(T0, 1));
    test:assertEquals(r.entry.points, -10);
    test:assertEquals(r.entry.sourceType, types:REVERSAL);
    test:assertEquals(r.entry.reversesReference, a.entry.reference);
    test:assertEquals(r.entry.action, types:REPOST, "the action follows the award (recognition counts)");
    test:assertEquals(r.entry.removalReason, types:REMOVAL_DUPLICATE);
    test:assertEquals(r.entry.reason, "Duplicate: same repost twice");
    test:assertEquals(r.entry.status, types:HELD);
    test:assertTrue(r.entry.reference.startsWith(types:REVERSAL_PREFIX));
    test:assertEquals(r.removed, {reference: r.entry.reference, reversesReference: a.entry.reference, engagementId: "g1",
        employeeId: "emp-1", removalReason: types:REMOVAL_DUPLICATE, removedAt: time:utcToString(types:addDays(T0, 1))});
    test:assertEquals(ledger.total("emp-1"), 0);
    test:assertEquals(code(removeInvalidActivity(ledger, a.entry.reference, types:REMOVAL_SPAM, (), "po-1", (), T0)),
            types:ERR_ALREADY_REVERSED, "removed at most once");
    test:assertEquals(code(reverseEntry(ledger, a.entry.reference, "again", "po-1", (), T0)), types:ERR_ALREADY_REVERSED,
            "and a removed award can't be reversed again");
}

@test:Config
function removalBuildsBothEventsForOneTransaction() returns error? {
    LedgerAppend a = check awardForEngagement(rules(), engagement(), (), T0);
    LedgerAppend r = check removal(a.entry, (), types:REMOVAL_NOT_A_REAL_REPOST, (), "po-1",
            "01900000-0000-7000-8000-0000000000aa", (), T0);
    test:assertEquals(r.event.eventType, events:POINTS_REVERSED);
    test:assertEquals(r.extraEvents.length(), 1);
    test:assertEquals(r.extraEvents[0].eventType, events:ACTIVITY_REMOVED);
    test:assertEquals(r.extraEvents[0].idempotencyKey, "ActivityRemoved:g1");
    test:assertEquals(r.entry.reason, "Not a real repost", "the code's label when there is no note");
    test:assertEquals(r.entry.reference, "REV-01900000-0000-7000-8000-0000000000aa");
}

@test:Config
function removalRules() returns error? {
    InMemoryLedger ledger = new;
    LedgerAppend a = check awardForEngagement(rules(), engagement(), (), T0);
    _ = check appendAward(ledger, a);
    string ref = a.entry.reference;
    test:assertEquals(code(removeInvalidActivity(ledger, ref, types:REMOVAL_DUPLICATE, (), "emp-1", (), T0)),
            types:ERR_SELF_REVIEW, "a PO can't remove their own activity");
    test:assertEquals(code(removeInvalidActivity(ledger, ref, types:REMOVAL_OTHER, "  ", "po-1", (), T0)),
            types:ERR_REASON_REQUIRED, "OTHER needs a note");
    test:assertEquals(code(removeInvalidActivity(ledger, "AMP-nope", types:REMOVAL_SPAM, (), "po-1", (), T0)),
            types:ERR_INVALID_LEDGER_REFERENCE);
    test:assertEquals(code(removeInvalidActivity(ledger, "REV-01900000-0000-7000-8000-0000000000bb", types:REMOVAL_SPAM,
            (), "po-1", (), T0)), types:ERR_NOT_FOUND);
    test:assertEquals(ledger.total("emp-1"), 10, "nothing is written");

    types:LedgerEntry adj = check adjustPoints(ledger, "emp-1", 5, "Bonus", "po-1", (), (), T0);
    test:assertEquals(code(removeInvalidActivity(ledger, adj.reference, types:REMOVAL_SPAM, (), "po-1", (), T0)),
            types:ERR_NOT_REMOVABLE, "an adjustment is reversed, not removed");
    LedgerAppend own = check awardForExternalShare(rules(), externalShare(), (), T0);
    _ = check appendAward(ledger, own);
    test:assertEquals(code(removeInvalidActivity(ledger, own.entry.reference, types:REMOVAL_SPAM, (), "po-1", (), T0)),
            types:ERR_NOT_REMOVABLE, "an own-post claim is reviewed in external sharing");
    types:LedgerEntry rev = check reverseEntry(ledger, adj.reference, "Undo", "po-1", (), T0);
    test:assertEquals(code(removeInvalidActivity(ledger, rev.reference, types:REMOVAL_SPAM, (), "po-1", (), T0)),
            types:ERR_NOT_REMOVABLE, "a reversal is never removed");

    Removal other = check removeInvalidActivity(ledger, ref, types:REMOVAL_OTHER, "Bot account", "po-1", (), T0);
    test:assertEquals(other.entry.reason, "Other: Bot account");
}

@test:Config
function aPaidAwardIsRemovedByANegativeHeldRow() returns error? {
    InMemoryLedger ledger = new;
    LedgerAppend a = check awardForEngagement(rules(), engagement(), (), T0);
    types:LedgerEntry paid = a.entry.clone();
    paid.status = types:PAID;
    paid.paidAt = T0;
    paid.coinReference = "CNV-1";
    _ = check appendAward(ledger, {entry: paid, event: a.event});
    Removal r = check removeInvalidActivity(ledger, paid.reference, types:REMOVAL_SPAM, (), "po-1", (), T0);
    test:assertEquals(r.entry.status, types:HELD, "the next Coins conversion takes the negative row");
    test:assertEquals(r.entry.points, -10);
    test:assertTrue(isConvertible(r.entry));
    types:LedgerEntry? original = check ledger.findByReference(paid.reference);
    test:assertEquals(original, paid, "the PAID row itself never changes");
}

@test:Config
function everyReasonHasALabel() {
    test:assertEquals(removalReasonLabel(types:REMOVAL_DUPLICATE), "Duplicate");
    test:assertEquals(removalReasonLabel(types:REMOVAL_NOT_A_REAL_REPOST), "Not a real repost");
    test:assertEquals(removalReasonLabel(types:REMOVAL_SPAM), "Spam or abuse");
    test:assertEquals(removalReasonLabel(types:REMOVAL_OTHER), "Other");
}
