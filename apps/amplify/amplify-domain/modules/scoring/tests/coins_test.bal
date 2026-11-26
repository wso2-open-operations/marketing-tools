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

// The Coins conversion (ADR-048) on fakes: the arithmetic (whole blocks, carry, caps), the period keys, the three
// steps per employee, every failure path (refused, unknown, reconcile) and the re-run of a period.

import amplify_common.coins;
import amplify_common.resilience;
import amplify_common.types;

import ballerina/test;
import ballerina/time;

// 2026-12-01T02:00:00Z
final time:Utc DEC1 = [1796090400, 0];

type FakeRow record {|
    string reference;
    string employeeId;
    int points;
    types:LedgerStatus? status;
    string? coinReference;
    int seq;
|};

type FakeIssue record {|
    *CoinIssue;
    int seq;
|};

// In-memory scoring tables with the same rules as the PostgreSQL repository.
isolated class FakeCoinRepo {
    *CoinRepository;
    *CoinWalletRepository;

    private map<FakeRow> ledger = {};
    private map<FakeIssue> issueRows = {};
    private map<string> runs = {};
    private map<string> runStatus = {};
    private map<CoinWallet> wallets = {};
    private int seq = 0;
    private boolean failMarkSent = false;
    private boolean failBegin = false;

    isolated function addRow(string employeeId, int points, types:LedgerStatus? status = types:HELD) returns string {
        lock {
            self.seq += 1;
            string reference = string `ADJ-${employeeId}-${self.seq}`;
            self.ledger[reference] = {reference, employeeId, points, status, coinReference: (), seq: self.seq};
            return reference;
        }
    }

    isolated function addWallet(string employeeId, string address) {
        lock {
            self.wallets[employeeId] = {employeeId, walletAddress: address, capturedAt: DEC1};
        }
    }

    isolated function setFailMarkSent(boolean v) {
        lock {
            self.failMarkSent = v;
        }
    }

    isolated function setFailBegin(boolean v) {
        lock {
            self.failBegin = v;
        }
    }

    isolated function row(string reference) returns FakeRow {
        lock {
            return <FakeRow>self.ledger[reference].clone();
        }
    }

    isolated function issueOf(string employeeId, string period) returns CoinIssue? {
        lock {
            string? runId = self.runs[period];
            foreach FakeIssue i in self.issueRows {
                if i.runId == runId && i.employeeId == employeeId {
                    CoinIssue c = {id: i.id, runId: i.runId, employeeId: i.employeeId, pointsIn: i.pointsIn,
                        carryIn: i.carryIn, coins: i.coins, carryOut: i.carryOut, walletAddress: i.walletAddress,
                        reference: i.reference, transferReference: i.transferReference, status: i.status,
                        attempts: i.attempts, lastErrorCode: i.lastErrorCode, nextAttemptAt: i.nextAttemptAt,
                        attemptedAt: i.attemptedAt};
                    return c.clone();
                }
            }
            return ();
        }
    }

    isolated function setAttemptedAt(string issueId, time:Utc atIn) {
        final time:Utc & readonly at = atIn.cloneReadOnly();
        lock {
            FakeIssue? i = self.issueRows[issueId];
            if i is FakeIssue {
                i.attemptedAt = at;
            }
        }
    }

    isolated function runStatusOf(string period) returns string? {
        lock {
            string? id = self.runs[period];
            return id is () ? () : self.runStatus[id];
        }
    }

    public isolated function openRun(string period, time:Utc now) returns CoinRun|error {
        lock {
            string? id = self.runs[period];
            string runId = id ?: "run-" + period;
            self.runs[period] = runId;
            self.runStatus[runId] = "RUNNING";
            return {id: runId, period};
        }
    }

    public isolated function openIssues() returns CoinIssue[]|error {
        lock {
            CoinIssue[] out = [];
            foreach FakeIssue i in self.issueRows {
                if i.status == COIN_PENDING || i.status == COIN_UNKNOWN {
                    out.push(toCoinIssue(i));
                }
            }
            return out.clone();
        }
    }

    public isolated function issuesOf(string runId) returns map<CoinIssue>|error {
        lock {
            map<CoinIssue> out = {};
            foreach FakeIssue i in self.issueRows {
                if i.runId == runId {
                    out[i.employeeId] = toCoinIssue(i);
                }
            }
            return out.clone();
        }
    }

    public isolated function candidates() returns CoinCandidate[]|error {
        lock {
            map<CoinCandidate> byEmp = {};
            string[] arrival = [];
            FakeRow[] rows = self.ledger.toArray();
            rows = rows.sort("ascending", isolated function(FakeRow r) returns int => r.seq);
            foreach FakeRow r in rows {
                if r.status != types:HELD || r.coinReference !is () {
                    continue;
                }
                CoinCandidate? c = byEmp[r.employeeId];
                if c is () {
                    byEmp[r.employeeId] = {employeeId: r.employeeId, carryIn: 0, rows: [{reference: r.reference,
                        points: r.points}], walletAddress: ()};
                    arrival.push(r.employeeId);
                } else {
                    c.rows.push({reference: r.reference, points: r.points});
                }
            }
            map<FakeIssue> lastSent = {};
            foreach FakeIssue i in self.issueRows {
                FakeIssue? prev = lastSent[i.employeeId];
                if i.status == COIN_SENT && (prev is () || prev.seq < i.seq) {
                    lastSent[i.employeeId] = i;
                }
            }
            string[] carryOnly = [];
            foreach FakeIssue i in lastSent {
                CoinCandidate? c = byEmp[i.employeeId];
                if c is CoinCandidate {
                    c.carryIn = i.carryOut;
                } else if i.carryOut > 0 {
                    byEmp[i.employeeId] = {employeeId: i.employeeId, carryIn: i.carryOut, rows: [], walletAddress: ()};
                    carryOnly.push(i.employeeId);
                }
            }
            foreach CoinWallet w in self.wallets {
                CoinCandidate? c = byEmp[w.employeeId];
                if c is CoinCandidate {
                    c.walletAddress = w.walletAddress;
                }
            }
            CoinCandidate[] out = [];
            foreach string id in [...carryOnly, ...arrival] {
                out.push(<CoinCandidate>byEmp[id]);
            }
            return out.clone();
        }
    }

    public isolated function committedCoins(string runId) returns int|error {
        lock {
            int sum = 0;
            foreach FakeIssue i in self.issueRows {
                if i.runId == runId && (i.status == COIN_SENT || i.status == COIN_PENDING || i.status == COIN_UNKNOWN) {
                    sum += i.coins;
                }
            }
            return sum;
        }
    }

    public isolated function transferTaken(string transferReference) returns boolean|error {
        lock {
            foreach FakeIssue i in self.issueRows {
                if i.transferReference == transferReference {
                    return true;
                }
            }
            return false;
        }
    }

    public isolated function begin(CoinPlan planIn, string runId, time:Utc nowIn) returns CoinIssue|error {
        final CoinPlan & readonly plan = planIn.cloneReadOnly();
        final time:Utc & readonly now = nowIn.cloneReadOnly();
        lock {
            if self.failBegin {
                return error("The ledger rows changed since the plan");
            }
            if plan.walletAddress is () {
                return error("A transfer needs a wallet");
            }
            foreach string ref in plan.references {
                FakeRow? r = self.ledger[ref];
                if r is () || r.status != types:HELD || r.coinReference !is () || r.employeeId != plan.employeeId {
                    return error("The ledger rows changed since the plan");
                }
            }
            FakeIssue? existing = ();
            foreach FakeIssue i in self.issueRows {
                if i.runId == runId && i.employeeId == plan.employeeId {
                    existing = i;
                }
            }
            self.seq += 1;
            FakeIssue issue;
            if existing is FakeIssue {
                if existing.status != COIN_FAILED && existing.status != COIN_SKIPPED_NO_WALLET {
                    return error("The employee's issue in this run is not open to a retry");
                }
                issue = existing;
                issue.attempts += 1;
            } else {
                issue = {id: "issue-" + self.seq.toString(), runId, employeeId: plan.employeeId, pointsIn: 0,
                    carryIn: 0, coins: 0, carryOut: 0, walletAddress: (), reference: newCoinReference(),
                    transferReference: (), status: COIN_PENDING, attempts: 1, lastErrorCode: (), nextAttemptAt: (),
                    attemptedAt: (), seq: self.seq};
                self.issueRows[issue.id] = issue;
            }
            issue.pointsIn = plan.pointsIn;
            issue.carryIn = plan.carryIn;
            issue.coins = plan.coins;
            issue.carryOut = plan.carryOut;
            issue.walletAddress = plan.walletAddress;
            issue.status = COIN_PENDING;
            issue.lastErrorCode = ();
            issue.nextAttemptAt = ();
            issue.attemptedAt = now;
            issue.seq = self.seq;
            foreach string ref in plan.references {
                FakeRow r = <FakeRow>self.ledger[ref];
                r.coinReference = issue.reference;
            }
            return toCoinIssue(issue).clone();
        }
    }

    public isolated function skipNoWallet(CoinPlan planIn, string runId, time:Utc now) returns error? {
        final CoinPlan & readonly plan = planIn.cloneReadOnly();
        lock {
            foreach FakeIssue i in self.issueRows {
                if i.runId == runId && i.employeeId == plan.employeeId {
                    i.status = COIN_SKIPPED_NO_WALLET;
                    i.walletAddress = ();
                    i.coins = plan.coins;
                    return;
                }
            }
            self.seq += 1;
            string id = "issue-" + self.seq.toString();
            self.issueRows[id] = {id, runId, employeeId: plan.employeeId, pointsIn: plan.pointsIn, carryIn: plan.carryIn,
                coins: plan.coins, carryOut: plan.carryOut, walletAddress: (), reference: newCoinReference(),
                transferReference: (), status: COIN_SKIPPED_NO_WALLET, attempts: 0, lastErrorCode: (),
                nextAttemptAt: (), attemptedAt: (), seq: self.seq};
        }
    }

    public isolated function markSent(CoinIssue issueIn, string transferReference, time:Utc now) returns error? {
        final CoinIssue & readonly issue = issueIn.cloneReadOnly();
        lock {
            if self.failMarkSent {
                return error("database down");
            }
            FakeIssue? found = self.issueRows[issue.id];
            if found is () || (found.status != COIN_PENDING && found.status != COIN_UNKNOWN) {
                return error("The issue is no longer open");
            }
            FakeIssue i = found;
            foreach FakeRow r in self.ledger {
                if r.coinReference == i.reference && r.status == types:HELD {
                    r.status = types:PAID;
                }
            }
            i.status = COIN_SENT;
            i.transferReference = transferReference;
            i.lastErrorCode = ();
        }
    }

    public isolated function markFailed(CoinIssue issueIn, string errorCode, time:Utc nextAttemptAtIn, time:Utc now)
            returns error? {
        final CoinIssue & readonly issue = issueIn.cloneReadOnly();
        final time:Utc & readonly nextAttemptAt = nextAttemptAtIn.cloneReadOnly();
        lock {
            FakeIssue? found = self.issueRows[issue.id];
            if found is () || (found.status != COIN_PENDING && found.status != COIN_UNKNOWN) {
                return error("The issue is no longer open");
            }
            FakeIssue i = found;
            foreach FakeRow r in self.ledger {
                if r.coinReference == i.reference && r.status == types:HELD {
                    r.coinReference = ();
                }
            }
            i.status = COIN_FAILED;
            i.lastErrorCode = errorCode;
            i.nextAttemptAt = nextAttemptAt;
        }
    }

    public isolated function markUnknown(CoinIssue issueIn, string errorCode, time:Utc now) returns error? {
        final CoinIssue & readonly issue = issueIn.cloneReadOnly();
        lock {
            FakeIssue? found = self.issueRows[issue.id];
            if found is () || (found.status != COIN_PENDING && found.status != COIN_UNKNOWN) {
                return error("The issue is no longer open");
            }
            FakeIssue i = found;
            i.status = COIN_UNKNOWN;
            i.lastErrorCode = errorCode;
        }
    }

    public isolated function finishRun(string runId, string status, string? stopReason, time:Utc now)
            returns CoinRunTotals|error {
        lock {
            self.runStatus[runId] = status;
            CoinRunTotals t = {};
            foreach FakeIssue i in self.issueRows {
                if i.runId != runId {
                    continue;
                }
                match i.status {
                    COIN_SENT => {
                        t.issuesSent += 1;
                        t.coinsSent += i.coins;
                    }
                    COIN_FAILED => {
                        t.issuesFailed += 1;
                    }
                    COIN_SKIPPED_NO_WALLET => {
                        t.issuesSkipped += 1;
                    }
                    _ => {
                        t.issuesUnknown += 1;
                    }
                }
            }
            return t.clone();
        }
    }

    public isolated function walletOf(types:EmployeeId employeeId) returns CoinWallet|error? {
        lock {
            return self.wallets[employeeId].clone();
        }
    }

    public isolated function saveWallet(types:EmployeeId employeeId, string walletAddress, time:Utc nowIn)
            returns CoinWallet|error {
        final time:Utc & readonly now = nowIn.cloneReadOnly();
        lock {
            CoinWallet w = {employeeId, walletAddress, capturedAt: now};
            self.wallets[employeeId] = w;
            return w.clone();
        }
    }
}

isolated function toCoinIssue(FakeIssue i) returns CoinIssue => {id: i.id, runId: i.runId, employeeId: i.employeeId,
    pointsIn: i.pointsIn, carryIn: i.carryIn, coins: i.coins, carryOut: i.carryOut, walletAddress: i.walletAddress,
    reference: i.reference, transferReference: i.transferReference, status: i.status, attempts: i.attempts,
    lastErrorCode: i.lastErrorCode, nextAttemptAt: i.nextAttemptAt, attemptedAt: i.attemptedAt};

// The Coins service: a balance, scripted failures per wallet, a recorded ledger of transfers.
isolated class FakeCoins {
    *coins:CoinsPort;

    private string balance = "100000";
    private boolean balanceDown = false;
    private boolean searchDown = false;
    private map<coins:CoinsError> failures = {};
    private coins:Transaction[] recorded = [];
    private coins:Wallet[] userWallets = [];
    private int n = 0;

    isolated function setBalance(string b) {
        lock {
            self.balance = b;
        }
    }

    isolated function setBalanceDown(boolean v) {
        lock {
            self.balanceDown = v;
        }
    }

    isolated function setSearchDown(boolean v) {
        lock {
            self.searchDown = v;
        }
    }

    isolated function failFor(string wallet, coins:CoinsErrorCode code, coins:Delivery delivered = "NO",
            boolean alsoRecord = false) {
        lock {
            self.failures[wallet] = coins:coinsError(code, "scripted", (), delivered);
            if alsoRecord {
                self.failures[wallet + "#record"] = coins:coinsError(code, "record", (), delivered);
            }
        }
    }

    isolated function clearFailures() {
        lock {
            self.failures = {};
        }
    }

    # A transfer the service recorded outside Amplify's view (what a timed-out call may have done).
    isolated function recordExtra(string to, string amount) returns string {
        lock {
            self.n += 1;
            string ref = "tx-extra-" + self.n.toString();
            self.recorded.push({reference: ref, fromAddress: "0xmaster", toAddress: to, amount,
                timestamp: "2026-12-01T02:00:05Z"});
            return ref;
        }
    }

    isolated function setUserWallets(coins:Wallet[] wIn) {
        final coins:Wallet[] & readonly w = wIn.cloneReadOnly();
        lock {
            self.userWallets = w.clone();
        }
    }

    isolated function transfers() returns coins:Transaction[] {
        lock {
            return self.recorded.clone();
        }
    }

    public isolated function transfer(string toAddress, int amount, string? correlationId = ())
            returns coins:Transfer|coins:CoinsError {
        lock {
            coins:CoinsError? f = self.failures[toAddress];
            if self.failures.hasKey(toAddress + "#record") {
                self.n += 1;
                self.recorded.push({reference: "tx-" + self.n.toString(), fromAddress: "0xmaster", toAddress,
                    amount: amount.toString(), timestamp: "2026-12-01T02:00:05Z"});
            }
            if f is coins:CoinsError {
                return f;
            }
            self.n += 1;
            string ref = "tx-" + self.n.toString();
            self.recorded.push({reference: ref, fromAddress: "0xmaster", toAddress, amount: amount.toString(),
                timestamp: "2026-12-01T02:00:05Z"});
            return {reference: ref, fromAddress: "0xmaster", toAddress, amount: amount.toString()};
        }
    }

    public isolated function walletsOf(string userAssertion, string? correlationId = ())
            returns coins:Wallet[]|coins:CoinsError {
        lock {
            if userAssertion == "refused" {
                return coins:coinsError(coins:UNAUTHORIZED, "scripted");
            }
            return self.userWallets.clone();
        }
    }

    public isolated function masterBalance(string? correlationId = ()) returns coins:MasterBalance|coins:CoinsError {
        lock {
            if self.balanceDown {
                return coins:coinsError(coins:UNAVAILABLE, "scripted");
            }
            return {walletAddress: "0xmaster", balance: self.balance};
        }
    }

    public isolated function transactionByReference(string reference, string? correlationId = ())
            returns coins:Transaction|coins:CoinsError? {
        lock {
            foreach coins:Transaction t in self.recorded {
                if t.reference == reference {
                    return t.clone();
                }
            }
            return ();
        }
    }

    public isolated function searchTransfers(coins:SearchFilter filterIn, string? correlationId = ())
            returns coins:TransactionPage|coins:CoinsError {
        final coins:SearchFilter & readonly filter = filterIn.cloneReadOnly();
        lock {
            if self.searchDown {
                return coins:coinsError(coins:UNAVAILABLE, "scripted");
            }
            coins:Transaction[] hits = [];
            foreach coins:Transaction t in self.recorded {
                if filter.toAddresses.indexOf(t.toAddress) !is () && filter.fromAddresses.indexOf(t.fromAddress) !is () {
                    hits.push(t);
                }
            }
            return {transactions: hits.clone(), total: hits.length()};
        }
    }

    public isolated function breaker() returns resilience:BreakerState => "CLOSED";
}

final CoinSettings ON = {walletsEnabled: true};

function later(int seconds) returns time:Utc => time:utcAddSeconds(DEC1, <decimal>seconds);

// ---- pure rules ----

@test:Config
function periodsAreUtcMonthsIsoWeeksAndDays() returns error? {
    test:assertEquals(coinPeriod("MONTHLY", DEC1), "2026-12");
    test:assertEquals(coinPeriod("DAILY", DEC1), "2026-12-01");
    test:assertEquals(coinPeriod("WEEKLY", DEC1), "2026-W49");
    test:assertEquals(coinPeriod("WEEKLY", check time:utcFromString("2026-01-01T00:00:00Z")), "2026-W01");
    test:assertEquals(coinPeriod("WEEKLY", check time:utcFromString("2026-12-31T23:00:00Z")), "2026-W53");
    test:assertEquals(coinPeriod("WEEKLY", check time:utcFromString("2027-01-01T00:00:00Z")), "2026-W53",
            "a week belongs to the year of its Thursday");
    test:assertEquals(coinPeriod("WEEKLY", check time:utcFromString("2024-12-30T00:00:00Z")), "2025-W01");
    test:assertEquals(coinPeriod("anything", check time:utcFromString("2027-03-09T00:00:00Z")), "2027-03",
            "unknown schedules fall back to MONTHLY");
}

function cand(int carryIn, int[] points, string? wallet = "0xw") returns CoinCandidate =>
    {employeeId: "e", carryIn, rows: from int i in 0 ..< points.length() select {reference: "ADJ-" + i.toString(),
        points: points[i]}, walletAddress: wallet};

@test:Config
function onlyWholeBlocksConvertAndTheRestCarries() {
    CoinPlan p = <CoinPlan>planConversion(cand(40, [100, 90]), ON, ());
    test:assertEquals([p.pointsIn, p.carryIn, p.coins, p.carryOut], [190, 40, 20, 30]);
    test:assertEquals(p.references, ["ADJ-0", "ADJ-1"]);
    test:assertEquals([p.blockPoints, p.blockCoins], [100, 10], "the rate is recorded with the issue");
    test:assertEquals(planConversion(cand(0, [99]), ON, ()), (), "no whole block");
    test:assertEquals(planConversion(cand(50, [80, -40]), ON, ()), (), "a reversal counts negative");
    test:assertEquals(planConversion(cand(0, [-30]), ON, ()), (), "a negative total converts nothing");
    CoinPlan carry = <CoinPlan>planConversion(cand(120, []), ON, ());
    test:assertEquals([carry.coins, carry.carryOut], [10, 20], "a carry above a block converts on its own");
    test:assertEquals(planConversion(cand(500, []), {walletsEnabled: true, blockPoints: 0}, ()), ());
}

@test:Config
function capsHoldBackWholeBlocksAsCarry() {
    CoinSettings capped = {walletsEnabled: true, maxCoinsPerPerson: 25};
    CoinPlan p = <CoinPlan>planConversion(cand(0, [1000]), capped, ());
    test:assertEquals([p.coins, p.carryOut], [20, 800], "25 Coins is two whole blocks; 800 points carry");
    CoinPlan r = <CoinPlan>planConversion(cand(0, [1000]), ON, 35);
    test:assertEquals([r.coins, r.carryOut], [30, 700], "what is left of the run cap");
    test:assertEquals(planConversion(cand(0, [1000]), ON, 5), (), "less than a block left");
    test:assertEquals(planConversion(cand(0, [1000]), ON, -10), ());
}

@test:Config
function retriesBackOffUpToADay() {
    test:assertEquals(time:utcDiffSeconds(retryAt(1, DEC1), DEC1), 900d);
    test:assertEquals(time:utcDiffSeconds(retryAt(3, DEC1), DEC1), 3600d);
    test:assertEquals(time:utcDiffSeconds(retryAt(40, DEC1), DEC1), 86400d);
}

@test:Config
function amountsWalletsAndReferences() {
    test:assertTrue(sameAmount("10.000000000", 10));
    test:assertTrue(sameAmount(" 10 ", 10));
    test:assertFalse(sameAmount("10.5", 10));
    test:assertFalse(sameAmount("ten", 10));
    test:assertEquals(maskWallet("0x12ab34cd56ef9f3c"), "0x12ab…9f3c");
    test:assertEquals(maskWallet("0x12345"), "0x…");
    test:assertEquals(maskWallet("abc"), "…");
    test:assertTrue(newCoinReference().startsWith("CNV-"));
}

function entry(types:LedgerStatus? status, string? coinReference = ()) returns types:LedgerEntry => {
    reference: "ADJ-1", employeeId: "e1", campaignId: (), sourceType: types:ADJUSTMENT, sourceId: (), action: (),
    points: 100, ruleId: (), reversesReference: (), reason: "r", actorId: "po", correlationId: (), createdAt: DEC1,
    status, statusChangedAt: (), paidAt: (), coinReference
};

@test:Config
function convertibleMeansHeldAndUntaken() {
    test:assertTrue(isConvertible(entry(types:HELD)));
    test:assertFalse(isConvertible(entry(types:HELD, "CNV-x")), "taken by an open conversion");
    test:assertFalse(isConvertible(entry(())), "action required (the pre-coin verification seam)");
    test:assertFalse(isConvertible(entry(types:PAID, "CNV-x")));
}

@test:Config
function paidComesFromAConversionAndIsFinal() returns error? {
    types:LedgerEntry paid = check changeSettlement(entry(types:HELD), types:PAID, DEC1, "CNV-1");
    test:assertEquals([paid.status, paid.coinReference], [types:PAID, "CNV-1"]);
    test:assertEquals(paid.paidAt, DEC1);
    test:assertEquals(paid.statusChangedAt, DEC1);
    test:assertEquals(code(changeSettlement(paid, types:HELD, DEC1)), types:ERR_ALREADY_PAID);
    test:assertEquals(code(changeSettlement(paid, (), DEC1)), types:ERR_ALREADY_PAID);
    test:assertEquals(code(changeSettlement(entry(types:HELD), types:PAID, DEC1)), types:ERR_PAID_NOT_ALLOWED,
            "a payout names its conversion");
    test:assertEquals(code(changeSettlement(entry(types:HELD), types:PAID, DEC1, "ADJ-1")), types:ERR_PAID_NOT_ALLOWED);
    test:assertEquals(code(changeSettlement(entry(()), types:PAID, DEC1, "CNV-1")), types:ERR_PAID_NOT_ALLOWED,
            "action required rows don't convert");
    types:LedgerEntry held = check changeSettlement(entry(()), types:HELD, DEC1);
    test:assertEquals([held.status, held.paidAt], [types:HELD, ()]);
}

// ---- the run ----

@test:Config
function walletsOffRunsNothing() returns error? {
    FakeCoinRepo repo = new;
    _ = repo.addRow("e1", 500);
    CoinRunReport r = check convertCoins(repo, new FakeCoins(), {}, {}, DEC1);
    test:assertEquals(r.status, RUN_WALLETS_OFF);
    test:assertEquals(repo.runStatusOf("2026-12"), (), "no run row");
}

@test:Config
function noMasterBalanceStopsBeforeAnything() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    string row = repo.addRow("e1", 500);
    FakeCoins svc = new;
    svc.setBalanceDown(true);
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, DEC1);
    test:assertEquals([r.status, r.stopReason], [RUN_STOPPED, STOP_COINS_UNAVAILABLE]);
    test:assertEquals(repo.row(row).coinReference, ());
    test:assertEquals(svc.transfers().length(), 0);
}

@test:Config
function aRunPaysWholeBlocksAndARerunSendsNothingNew() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("alice", "0xalice");
    repo.addWallet("bob", "0xbob");
    string a1 = repo.addRow("alice", 150);
    string a2 = repo.addRow("alice", 80);
    string b1 = repo.addRow("bob", 100);
    string c1 = repo.addRow("carol", 300);
    string d1 = repo.addRow("dave", 40);
    repo.addWallet("dave", "0xdave");
    string flagged = repo.addRow("alice", 500, ());
    FakeCoins svc = new;

    CoinRunReport r = check convertCoins(repo, svc, ON, {correlationId: "c-1"}, DEC1);
    test:assertEquals(r.status, RUN_DONE);
    test:assertEquals(r.period, "2026-12");
    test:assertEquals([r.sent, r.coinsSent, r.skippedNoWallet, r.failed, r.unknown], [2, 30, 1, 0, 0]);
    test:assertEquals(r.totals, {issuesSent: 2, coinsSent: 30, issuesFailed: 0, issuesUnknown: 0, issuesSkipped: 1});
    test:assertEquals(repo.runStatusOf("2026-12"), RUN_DONE);

    CoinIssue alice = <CoinIssue>repo.issueOf("alice", "2026-12");
    test:assertEquals([alice.pointsIn, alice.carryIn, alice.coins, alice.carryOut], [230, 0, 20, 30]);
    test:assertEquals(alice.status, COIN_SENT);
    test:assertEquals(alice.transferReference, "tx-1");
    test:assertEquals([repo.row(a1).status, repo.row(a2).status], [types:PAID, types:PAID]);
    test:assertEquals(repo.row(a1).coinReference, alice.reference);
    test:assertEquals(repo.row(flagged).status, (), "action required rows are left alone");
    test:assertEquals(repo.row(b1).status, types:PAID);
    test:assertEquals((<CoinIssue>repo.issueOf("carol", "2026-12")).status, COIN_SKIPPED_NO_WALLET);
    test:assertEquals([repo.row(c1).status, repo.row(c1).coinReference], [types:HELD, ()], "carol's points wait");
    test:assertEquals(repo.issueOf("dave", "2026-12"), (), "below a block: no issue");
    test:assertEquals(repo.row(d1).status, types:HELD);

    // The same period again: SENT issues send nothing; new points of a paid person wait for the next period.
    _ = repo.addRow("bob", 200);
    CoinRunReport again = check convertCoins(repo, svc, ON, {}, later(3600));
    test:assertEquals([again.sent, again.passedOver, again.skippedNoWallet], [0, 2, 1]);
    test:assertEquals(svc.transfers().length(), 2);

    // Next month: alice's carry (30) plus new points; carol captured a wallet meanwhile.
    _ = repo.addRow("alice", 70);
    repo.addWallet("carol", "0xcarol");
    time:Utc jan1 = check time:utcFromString("2027-01-01T02:00:00Z");
    CoinRunReport jan = check convertCoins(repo, svc, ON, {}, jan1);
    test:assertEquals(jan.period, "2027-01");
    CoinIssue aliceJan = <CoinIssue>repo.issueOf("alice", "2027-01");
    test:assertEquals([aliceJan.carryIn, aliceJan.pointsIn, aliceJan.coins, aliceJan.carryOut], [30, 70, 10, 0]);
    test:assertEquals((<CoinIssue>repo.issueOf("carol", "2027-01")).coins, 30);
    test:assertEquals((<CoinIssue>repo.issueOf("bob", "2027-01")).coins, 20);
}

@test:Config
function theMasterWalletMustCoverTheWholeRun() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    repo.addWallet("e2", "0xb");
    string r1 = repo.addRow("e1", 300);
    _ = repo.addRow("e2", 300);
    _ = repo.addRow("e3", 300);
    FakeCoins svc = new;
    svc.setBalance("59.999999999");
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, DEC1);
    test:assertEquals([r.status, r.stopReason], [RUN_STOPPED, STOP_INSUFFICIENT_BALANCE]);
    test:assertEquals(svc.transfers().length(), 0, "no partial sends");
    test:assertEquals(repo.row(r1).coinReference, ());
    test:assertEquals(repo.issueOf("e3", "2026-12"), (), "nothing written at all");
    svc.setBalance("60");
    CoinRunReport ok = check convertCoins(repo, svc, ON, {}, later(60));
    test:assertEquals([ok.status, ok.sent], [RUN_DONE, 2]);
}

@test:Config
function capsLimitThePersonAndTheRun() returns error? {
    FakeCoinRepo repo = new;
    foreach string e in ["e1", "e2", "e3"] {
        repo.addWallet(e, "0x" + e);
        _ = repo.addRow(e, 1000);
    }
    FakeCoins svc = new;
    CoinRunReport r = check convertCoins(repo, svc, {walletsEnabled: true, maxCoinsPerPerson: 60, maxCoinsPerRun: 100},
            {}, DEC1);
    test:assertEquals(r.coinsSent, 100);
    test:assertEquals((<CoinIssue>repo.issueOf("e1", "2026-12")).coins, 60);
    test:assertEquals((<CoinIssue>repo.issueOf("e2", "2026-12")).coins, 40, "what the run cap left");
    test:assertEquals((<CoinIssue>repo.issueOf("e2", "2026-12")).carryOut, 600);
    test:assertEquals(repo.issueOf("e3", "2026-12"), (), "the run cap is spent; e3 keeps every point");
}

@test:Config
function aRefusedTransferGivesThePointsBackAndRetriesLater() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xgone");
    repo.addWallet("e2", "0xok");
    string row = repo.addRow("e1", 200);
    _ = repo.addRow("e2", 200);
    FakeCoins svc = new;
    svc.failFor("0xgone", coins:RECIPIENT_NOT_FOUND);
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, DEC1);
    test:assertEquals([r.status, r.failed, r.sent], [RUN_DONE, 1, 1], "one refusal does not stop the run");
    CoinIssue failed = <CoinIssue>repo.issueOf("e1", "2026-12");
    test:assertEquals([failed.status, failed.lastErrorCode, failed.attempts], [COIN_FAILED, coins:RECIPIENT_NOT_FOUND, 1]);
    test:assertEquals([repo.row(row).status, repo.row(row).coinReference], [types:HELD, ()], "HELD and untagged");

    CoinRunReport early = check convertCoins(repo, svc, ON, {}, later(60));
    test:assertEquals([early.sent, early.failed], [0, 0], "not before the retry is due");
    svc.clearFailures();
    CoinRunReport due = check convertCoins(repo, svc, ON, {}, later(901));
    test:assertEquals(due.sent, 1);
    CoinIssue retried = <CoinIssue>repo.issueOf("e1", "2026-12");
    test:assertEquals([retried.status, retried.attempts, retried.reference], [COIN_SENT, 2, failed.reference],
            "the same issue, tried again");
}

@test:Config
function refusalsThatHitEveryoneStopTheRun() returns error? {
    [coins:CoinsErrorCode, string][] cases = [[coins:INSUFFICIENT_FUNDS, STOP_INSUFFICIENT_BALANCE],
        [coins:UNAVAILABLE, STOP_COINS_UNAVAILABLE], [coins:UNAUTHORIZED, STOP_COINS_UNAVAILABLE],
        [coins:RATE_LIMITED, STOP_COINS_UNAVAILABLE]];
    foreach [coins:CoinsErrorCode, string] [failure, reason] in cases {
        FakeCoinRepo repo = new;
        repo.addWallet("e1", "0xa");
        repo.addWallet("e2", "0xb");
        _ = repo.addRow("e1", 200);
        string second = repo.addRow("e2", 200);
        FakeCoins svc = new;
        svc.failFor("0xa", failure);
        CoinRunReport r = check convertCoins(repo, svc, ON, {}, DEC1);
        test:assertEquals([r.status, r.stopReason, r.failed], [RUN_STOPPED, reason, 1], failure);
        test:assertEquals(repo.row(second).coinReference, (), "nobody after it is touched");
        test:assertEquals(svc.transfers().length(), 0);
    }
}

@test:Config
function anUnknownOutcomeIsReconciledBeforeAnythingIsResent() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    repo.addWallet("e2", "0xb");
    string row = repo.addRow("e1", 250);
    _ = repo.addRow("e2", 100);
    FakeCoins svc = new;
    // The call timed out, but the service did record it.
    svc.failFor("0xa", coins:OUTCOME_UNKNOWN, "UNKNOWN", alsoRecord = true);
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, DEC1);
    test:assertEquals([r.status, r.stopReason, r.unknown], [RUN_STOPPED, STOP_OUTCOME_UNKNOWN, 1]);
    CoinIssue open = <CoinIssue>repo.issueOf("e1", "2026-12");
    test:assertEquals(open.status, COIN_UNKNOWN);
    test:assertEquals([repo.row(row).status, repo.row(row).coinReference], [types:HELD, open.reference],
            "the rows stay tagged: nothing can take them twice");
    svc.clearFailures();

    // Too soon: left open, the employee is passed over.
    CoinRunReport soon = check convertCoins(repo, svc, ON, {}, later(60));
    test:assertEquals([soon.stillOpen, soon.reconciledSent], [1, 0]);
    test:assertEquals(svc.transfers().length(), 2, "e2 was sent; e1 was not sent again");

    // Old enough: the transfer is found and the issue is SENT with the service's reference.
    CoinRunReport settled = check convertCoins(repo, svc, ON, {}, later(700));
    test:assertEquals(settled.reconciledSent, 1);
    CoinIssue sent = <CoinIssue>repo.issueOf("e1", "2026-12");
    test:assertEquals([sent.status, sent.transferReference], [COIN_SENT, "tx-1"]);
    test:assertEquals(repo.row(row).status, types:PAID);
    test:assertEquals(svc.transfers().length(), 2, "never resent");
}

@test:Config
function aTransferThatNeverHappenedConvertsAgain() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    string row = repo.addRow("e1", 200);
    FakeCoins svc = new;
    svc.failFor("0xa", coins:OUTCOME_UNKNOWN, "UNKNOWN");
    _ = check convertCoins(repo, svc, ON, {}, DEC1);
    svc.clearFailures();
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, later(700));
    test:assertEquals([r.reconciledNotSent, r.sent], [1, 1], "not found -> FAILED, then planned and sent again");
    CoinIssue issue = <CoinIssue>repo.issueOf("e1", "2026-12");
    test:assertEquals([issue.status, issue.attempts], [COIN_SENT, 2]);
    test:assertEquals(repo.row(row).status, types:PAID);
    test:assertEquals(svc.transfers().length(), 1);
}

@test:Config
function anAmbiguousReconcileWaitsForAnOperator() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    _ = repo.addRow("e1", 200);
    FakeCoins svc = new;
    svc.failFor("0xa", coins:OUTCOME_UNKNOWN, "UNKNOWN");
    _ = check convertCoins(repo, svc, ON, {}, DEC1);
    svc.clearFailures();
    _ = svc.recordExtra("0xa", "20");
    _ = svc.recordExtra("0xa", "20.000000000");
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, later(700));
    test:assertEquals([r.stillOpen, r.reconciledSent, r.sent], [1, 0, 0]);
    CoinIssue issue = <CoinIssue>repo.issueOf("e1", "2026-12");
    test:assertEquals([issue.status, issue.lastErrorCode], [COIN_UNKNOWN, ERR_RECONCILE_AMBIGUOUS]);
    // Again: still waiting, the code is kept.
    CoinRunReport again = check convertCoins(repo, svc, ON, {}, later(800));
    test:assertEquals(again.stillOpen, 1);
}

@test:Config
function aFailedSearchLeavesTheIssueOpen() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    _ = repo.addRow("e1", 200);
    FakeCoins svc = new;
    svc.failFor("0xa", coins:BAD_RESPONSE, "UNKNOWN");
    _ = check convertCoins(repo, svc, ON, {}, DEC1);
    svc.clearFailures();
    svc.setSearchDown(true);
    // New points meanwhile: the employee is passed over while the issue is open (its own rows stay tagged).
    _ = repo.addRow("e1", 300);
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, later(700));
    test:assertEquals([r.stillOpen, r.passedOver, r.sent], [1, 1, 0]);
}

@test:Config
function sentButNotRecordedIsReconciledLater() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    string row = repo.addRow("e1", 200);
    FakeCoins svc = new;
    repo.setFailMarkSent(true);
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, DEC1);
    test:assertEquals(r.sent, 1);
    test:assertEquals((<CoinIssue>repo.issueOf("e1", "2026-12")).status, COIN_PENDING);
    repo.setFailMarkSent(false);
    CoinRunReport next = check convertCoins(repo, svc, ON, {}, later(700));
    test:assertEquals([next.reconciledSent, next.sent], [1, 0]);
    test:assertEquals(repo.row(row).status, types:PAID);
}

@test:Config
function rowsThatChangedUnderThePlanAreLeftForTheNextRun() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    _ = repo.addRow("e1", 200);
    repo.setFailBegin(true);
    FakeCoins svc = new;
    CoinRunReport r = check convertCoins(repo, svc, ON, {}, DEC1);
    test:assertEquals([r.status, r.sent, r.passedOver], [RUN_DONE, 0, 1]);
    test:assertEquals(svc.transfers().length(), 0);
}

@test:Config
function theTimeLimitLeavesTheRestForARerun() returns error? {
    FakeCoinRepo repo = new;
    repo.addWallet("e1", "0xa");
    _ = repo.addRow("e1", 200);
    FakeCoins svc = new;
    CoinRunReport r = check convertCoins(repo, svc, ON, {maxSeconds: -1}, DEC1);
    test:assertEquals([r.status, r.sent], [RUN_PARTIAL, 0]);
    test:assertEquals(repo.runStatusOf("2026-12"), RUN_PARTIAL);
    CoinRunReport rest = check convertCoins(repo, svc, ON, {}, later(60));
    test:assertEquals([rest.status, rest.sent], [RUN_DONE, 1]);
}

// ---- wallet capture ----

@test:Config
function captureTakesTheDefaultWalletElseTheFirst() returns error? {
    FakeCoinRepo repo = new;
    FakeCoins svc = new;
    svc.setUserWallets([{address: "0xfirst", balance: "0", isDefault: false},
        {address: "0xdefault", balance: "3", isDefault: true}]);
    CoinWallet? w = check captureWallet(repo, svc, "e1", "jwt", (), DEC1);
    test:assertEquals((<CoinWallet>w).walletAddress, "0xdefault");
    svc.setUserWallets([{address: "0xonly", balance: "0", isDefault: false}]);
    w = check captureWallet(repo, svc, "e1", "jwt", (), DEC1);
    test:assertEquals((<CoinWallet>w).walletAddress, "0xonly");
    test:assertEquals((<CoinWallet>check repo.walletOf("e1")).walletAddress, "0xonly");
    svc.setUserWallets([]);
    test:assertEquals(check captureWallet(repo, svc, "e2", "jwt", (), DEC1), (), "no wallet at the service");
    CoinWallet|error? refused = captureWallet(repo, svc, "e2", "refused", (), DEC1);
    test:assertTrue(refused is coins:CoinsError);
}
