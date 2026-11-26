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

// The Coins conversion repositories against PostgreSQL (V026, ADR-048): begin tags exactly the planned rows, SENT pays
// them (and they are final), FAILED gives them back, a retry reuses the issue, the run totals, the carry, the wallet,
// and the Coins summary. The database is shared with the other integration tests, so every read is filtered to this
// test's employees and period.

import amplify_common.types;
import amplify_domain.scoring;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

function find(scoring:CoinCandidate[] all, string employeeId) returns scoring:CoinCandidate? {
    foreach scoring:CoinCandidate c in all {
        if c.employeeId == employeeId {
            return c;
        }
    }
    return ();
}

function ledgerStatus(postgresql:Client db, string reference) returns [string?, string?]|error {
    record {|string? status; string? coin_reference;|} r = check db->queryRow(`
        SELECT status, coin_reference FROM scoring_points_ledger WHERE reference = ${reference}`);
    return [r.status, r.coin_reference];
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testCoinRepositoryRoundTrip() returns error? {
    postgresql:Client db = check jobs();
    string po = check newEmployee(db, "coin-po");
    string alice = check newEmployee(db, "coin-alice");
    string bob = check newEmployee(db, "coin-bob");
    scoring:PgLedgerRepository ledger = new (db, poActor(po));
    time:Utc now = time:utcNow();
    types:LedgerEntry a1 = check scoring:adjustPoints(ledger, alice, 150, "it", po, (), (), now);
    types:LedgerEntry a2 = check scoring:adjustPoints(ledger, alice, 80, "it", po, (), (), now);
    types:LedgerEntry b1 = check scoring:adjustPoints(ledger, bob, 120, "it", po, (), (), now);

    scoring:PgCoinWalletRepository wallets = new (db, poActor(alice));
    scoring:CoinWallet w = check wallets.saveWallet(alice, "0xalice0000aaaa", now);
    test:assertEquals(w.walletAddress, "0xalice0000aaaa");
    scoring:CoinWallet again = check wallets.saveWallet(alice, "0xalice0000aaaa", time:utcAddSeconds(now, 60));
    test:assertEquals(again.capturedAt, w.capturedAt, "the same address keeps its capture time");
    scoring:CoinWallet changed = check wallets.saveWallet(alice, "0xalice1111bbbb", time:utcAddSeconds(now, 120));
    test:assertNotEquals(changed.capturedAt, w.capturedAt, "a new address restarts it");
    test:assertEquals((<scoring:CoinWallet>check wallets.walletOf(alice)).walletAddress, "0xalice1111bbbb");
    test:assertEquals(check wallets.walletOf(bob), ());
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit_log WHERE action = 'CoinWalletCaptured'
        AND entity_id = ${alice} AND after::text LIKE '%…%'`), 3, "audited with the masked address only");

    scoring:PgCoinRepository repo = new (db);
    // A period of its own: the shared database may hold others, and a rerun on the same database must not reuse it.
    int n = check int:fromHexString(uniq().substring(0, 4));
    string period = string `2091-${(n / 100 % 100).toString().padZero(2)}-${(n % 100).toString().padZero(2)}`;
    scoring:CoinRun run = check repo.openRun(period, now);
    scoring:CoinRun reopened = check repo.openRun(period, now);
    test:assertEquals(reopened.id, run.id, "one run per period");

    scoring:CoinCandidate ca = <scoring:CoinCandidate>find(check repo.candidates(now), alice);
    test:assertEquals(ca.walletAddress, "0xalice1111bbbb");
    test:assertEquals(ca.carryIn, 0);
    test:assertEquals(from scoring:ConvertibleRow r in ca.rows select r.reference, [a1.reference, a2.reference]);
    scoring:CoinCandidate cb = <scoring:CoinCandidate>find(check repo.candidates(now), bob);
    test:assertEquals(cb.walletAddress, ());

    scoring:CoinSettings settings = {walletsEnabled: true};
    scoring:CoinPlan pa = <scoring:CoinPlan>scoring:planConversion(ca, settings, 1000);
    scoring:CoinIssue ia = check repo.begin(pa, run.id, now);
    test:assertEquals([ia.status, ia.attempts, ia.coins, ia.carryOut], [scoring:COIN_PENDING, 1, 20, 30]);
    test:assertEquals(check ledgerStatus(db, a1.reference), ["HELD", ia.reference], "tagged, still HELD");
    test:assertEquals(check repo.committedCoins(run.id), 20);
    test:assertTrue(find(check repo.candidates(now), alice) is (), "tagged rows are no longer convertible");
    test:assertTrue(repo.begin(pa, run.id, now) is error, "an open issue is never overwritten");
    boolean openFound = false;
    foreach scoring:CoinIssue i in check repo.openIssues() {
        openFound = openFound || i.id == ia.id;
    }
    test:assertTrue(openFound);

    // Refused: the rows come back, then the same issue is tried again with the same reference.
    check repo.markFailed(ia, "RECIPIENT_NOT_FOUND", time:utcAddSeconds(now, 900), now);
    test:assertEquals(check ledgerStatus(db, a1.reference), ["HELD", ()]);
    scoring:CoinIssue failed = <scoring:CoinIssue>(check repo.issuesOf(run.id))[alice];
    test:assertEquals([failed.status, failed.lastErrorCode], [scoring:COIN_FAILED, "RECIPIENT_NOT_FOUND"]);
    scoring:CoinIssue retried = check repo.begin(pa, run.id, time:utcAddSeconds(now, 1000));
    test:assertEquals([retried.id, retried.reference, retried.attempts], [ia.id, ia.reference, 2]);

    // Unknown, then sent: the rows are PAID and final.
    check repo.markUnknown(retried, "OUTCOME_UNKNOWN", now);
    test:assertFalse(check repo.transferTaken("tx-it-" + alice));
    check repo.markSent(retried, "tx-it-" + alice, now);
    test:assertTrue(check repo.transferTaken("tx-it-" + alice));
    test:assertEquals(check ledgerStatus(db, a2.reference), ["PAID", ia.reference]);
    test:assertTrue(repo.markSent(retried, "tx-it-2", now) is error, "a SENT issue is closed");
    error? repaid = ledger.updateSettlement(a1.reference, (), now);
    test:assertTrue(repaid is types:DomainError && repaid.detail().code == types:ERR_ALREADY_PAID, "PAID is final");
    error? paidDirect = ledger.updateSettlement(b1.reference, types:PAID, now);
    test:assertTrue(paidDirect is types:DomainError && paidDirect.detail().code == types:ERR_PAID_NOT_ALLOWED);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit_log WHERE entity_id = ${ia.id}
        AND action IN ('CoinIssueFailed', 'CoinIssueUnknown', 'CoinsIssued')`), 3);

    // Bob has no wallet: skipped, his row untouched; a second skip updates the same issue.
    scoring:CoinPlan pb = <scoring:CoinPlan>scoring:planConversion(cb, settings, ());
    check repo.skipNoWallet(pb, run.id, now);
    check repo.skipNoWallet(pb, run.id, now);
    test:assertEquals(check ledgerStatus(db, b1.reference), ["HELD", ()]);
    test:assertEquals((<scoring:CoinIssue>(check repo.issuesOf(run.id))[bob]).status, scoring:COIN_SKIPPED_NO_WALLET);

    scoring:CoinRunTotals totals = check repo.finishRun(run.id, scoring:RUN_DONE, (), now);
    test:assertEquals(totals, {issuesSent: 1, coinsSent: 20, issuesFailed: 0, issuesUnknown: 0, issuesSkipped: 1});
    _ = check repo.finishRun(run.id, scoring:RUN_STOPPED, scoring:STOP_INSUFFICIENT_BALANCE, now);
    test:assertTrue(repo.finishRun(run.id, scoring:RUN_STOPPED, (), now) is error, "STOPPED needs a reason");

    // The carry feeds the next run; the summary shows what the person got.
    scoring:CoinCandidate? carryOnly = find(check repo.candidates(now), alice);
    test:assertEquals(carryOnly, {employeeId: alice, carryIn: 30, rows: [], walletAddress: "0xalice1111bbbb"});
    scoring:CoinSummary summary = check scoring:coinSummaryOf(db, alice);
    test:assertEquals([summary.coinsReceived, summary.carryPoints], [20, 30]);
    test:assertEquals(summary.walletAddress, "0xalice1111bbbb");
    scoring:PointsSummary points = check scoring:pointsSummaryOf(db, alice);
    test:assertEquals([points.held, points.paid], [0, 230]);
    scoring:CoinSummary none = check scoring:coinSummaryOf(db, bob);
    test:assertEquals([none.coinsReceived, none.carryPoints], [0, 0]);
    test:assertEquals(none.walletAddress, ());

    // History: the conversion is a row of its own next to the ledger rows; a skipped issue moved nothing and is not.
    scoring:TimelinePage timeline = check scoring:timelineOf(db, alice, 0, 10);
    test:assertEquals(timeline.total, 3);
    scoring:CoinConversion[] conversions = from scoring:TimelineEntry e in timeline.items
        where e is scoring:CoinConversion select e;
    test:assertEquals(conversions.length(), 1);
    test:assertEquals([conversions[0].points, conversions[0].coins], [200, 20], "blocks x block points, not points in");
    test:assertEquals(conversions[0].status, scoring:COIN_SENT);
    test:assertEquals(conversions[0].transferReference, "tx-it-" + alice);
    test:assertEquals(conversions[0].reference, ia.reference);
    scoring:TimelinePage second = check scoring:timelineOf(db, alice, 1, 2);
    test:assertEquals([second.total, second.items.length()], [3, 1], "paged across both kinds");
    scoring:TimelinePage past = check scoring:timelineOf(db, alice, 5, 2);
    test:assertEquals([past.total, past.items.length()], [3, 0]);
    scoring:TimelinePage bobs = check scoring:timelineOf(db, bob, 0, 10);
    test:assertEquals(bobs.total, 1, "SKIPPED_NO_WALLET is not a history row");
    check db.close();
}
