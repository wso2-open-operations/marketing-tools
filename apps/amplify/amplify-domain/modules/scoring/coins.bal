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

// Automatic Coins conversion (phase 2, ADR-048). Once a period (`coin.schedule`), every employee's HELD ledger points
// not yet taken by a conversion, plus the carry of their last paid conversion, become Coins in whole blocks
// (`coin.block_points` points = `coin.block_coins` Coins); the rest carries over. Caps: `coin.max_coins_per_person`
// per run and `coin.max_coins_per_run` for the period; what a cap holds back carries over too.
//
// Per employee, three steps (the jobs' `POST /coins/convert` runs them):
//   1. `begin` (one transaction): the issue row PENDING, and its `CNV-` reference set on the ledger rows it takes;
//   2. the transfer from Amplify's master wallet, outside any transaction;
//   3. `markSent` (one transaction): the rows PAID, the issue SENT with the service's transfer reference.
// A definite refusal (nothing moved) marks the issue FAILED and gives the rows back (untagged, HELD): the next run
// takes them again. No clear answer marks it UNKNOWN and keeps the rows tagged, so nothing can take them twice; the
// next run reconciles it against the service's ledger (`POST /transactions/search`) before anything is sent again.
// The service takes no caller reference, so the reconcile matches master wallet -> employee wallet, amount, after the
// attempt, and a transfer reference no other issue holds.
//
// Pre-coin verification (verification.bal, V027) runs before: an engagement row converts only while its LinkedIn
// activity was seen within `coin.verify_max_age_hours` (or a PO cleared it); a row it could not check is action
// required (status NULL, not HELD); a row whose activity is gone is reversed, and the pair nets to zero. The candidate
// query applies the same rule (`isConvertible`), with the cutoff `verifiedSince` the run passes.

import amplify_common.coins;
import amplify_common.resilience;
import amplify_common.types;

import ballerina/log;
import ballerina/time;

# Prefix of our reference for one conversion of one employee (`scoring_coin_issue.reference`, the ledger rows'
# `coin_reference`).
public const string COIN_REFERENCE_PREFIX = "CNV-";

# Issue written, transfer not yet confirmed.
public const COIN_PENDING = "PENDING";
# The service recorded the transfer; the rows are PAID.
public const COIN_SENT = "SENT";
# The service refused; nothing moved, the rows are HELD again.
public const COIN_FAILED = "FAILED";
# No clear answer; the rows stay tagged until the reconcile settles it.
public const COIN_UNKNOWN = "UNKNOWN";
# The employee has captured no wallet; the rows stay HELD.
public const COIN_SKIPPED_NO_WALLET = "SKIPPED_NO_WALLET";

# State of one issue.
public type CoinIssueStatus COIN_PENDING|COIN_SENT|COIN_FAILED|COIN_UNKNOWN|COIN_SKIPPED_NO_WALLET;

# Run finished every candidate.
public const RUN_DONE = "DONE";
# Run stopped at the time limit; a re-run of the period carries on.
public const RUN_PARTIAL = "PARTIAL";
# Run stopped early (`stopReason`).
public const RUN_STOPPED = "STOPPED";
# `coin.wallets_enabled` is false: nothing ran, points keep counting.
public const RUN_WALLETS_OFF = "WALLETS_OFF";

# Why a run stopped.
public const STOP_INSUFFICIENT_BALANCE = "INSUFFICIENT_BALANCE";
# The Coins service could not be reached or refused Amplify's credentials.
public const STOP_COINS_UNAVAILABLE = "COINS_UNAVAILABLE";
# A transfer got no clear answer; the run stops so a degraded service does not leave a trail of UNKNOWN issues.
public const STOP_OUTCOME_UNKNOWN = "OUTCOME_UNKNOWN";

# Reconcile found no transfer for the issue: nothing moved.
public const ERR_NOT_SENT = "NOT_SENT";
# Reconcile found more than one possible transfer: an operator decides (docs/runbooks/operations.md).
public const ERR_RECONCILE_AMBIGUOUS = "RECONCILE_AMBIGUOUS";

# First wait before a FAILED issue is retried in the same period, seconds (doubles per attempt).
const decimal RETRY_BASE_SECONDS = 900;
# Longest wait before a retry in the same period, seconds.
const decimal RETRY_MAX_SECONDS = 86400;
# How far before the attempt the reconcile searches, seconds (clock skew between Amplify and the service).
const decimal RECONCILE_SKEW_SECONDS = 120;

# The conversion settings (`config_app_setting` `coin.*`).
public type CoinSettings record {|
    # `coin.wallets_enabled`
    boolean walletsEnabled = false;
    # `coin.block_points`
    int blockPoints = 100;
    # `coin.block_coins`
    int blockCoins = 10;
    # `coin.max_coins_per_person`
    int maxCoinsPerPerson = 500;
    # `coin.max_coins_per_run`
    int maxCoinsPerRun = 50000;
    # `coin.schedule`: `MONTHLY`, `WEEKLY` or `DAILY`; names the period
    string schedule = "MONTHLY";
    # `coin.verify_max_age_hours`: an engagement row converts only when verified this recently (V027)
    int verifyMaxAgeHours = DEFAULT_VERIFY_MAX_AGE_HOURS;
|};

# A ledger row the conversion may take.
public type ConvertibleRow record {|
    # Ledger reference
    types:LedgerReference reference;
    # Signed points (a reversal is negative)
    int points;
|};

# What one employee brings to a run.
public type CoinCandidate record {|
    # Employee
    types:EmployeeId employeeId;
    # carry_out of their last SENT issue
    int carryIn;
    # Their HELD rows no conversion has taken
    ConvertibleRow[] rows;
    # Captured wallet, `()` when none
    string? walletAddress;
|};

# The conversion of one employee in one run.
public type CoinPlan record {|
    # Employee
    types:EmployeeId employeeId;
    # Sum of the rows taken
    int pointsIn;
    # Carry in
    int carryIn;
    # Coins, whole blocks
    int coins;
    # Carry out
    int carryOut;
    # Rate used
    int blockPoints;
    # Rate used
    int blockCoins;
    # Rows taken
    types:LedgerReference[] references;
    # Wallet, `()` when none (the issue is SKIPPED_NO_WALLET)
    string? walletAddress;
|};

# A stored issue (`scoring_coin_issue`).
public type CoinIssue record {|
    # UUIDv7
    string id;
    # Its run
    string runId;
    # Employee
    types:EmployeeId employeeId;
    # Points taken
    int pointsIn;
    # Carry in
    int carryIn;
    # Coins
    int coins;
    # Carry out
    int carryOut;
    # Wallet, `()` when skipped
    string? walletAddress;
    # Our `CNV-` reference
    string reference;
    # The service's reference, once known
    string? transferReference;
    # State
    CoinIssueStatus status;
    # Transfer attempts
    int attempts;
    # Last failure code
    string? lastErrorCode;
    # FAILED: not retried in the same period before this time
    time:Utc? nextAttemptAt;
    # When the last transfer call started
    time:Utc? attemptedAt;
|};

# The run of one period (`scoring_coin_run`).
public type CoinRun record {|
    # UUIDv7
    string id;
    # `2026-12`, `2026-W49` or `2026-12-01`
    string period;
|};

# The period's totals after a run.
public type CoinRunTotals record {|
    # Issues SENT in the period
    int issuesSent = 0;
    # Coins sent in the period
    int coinsSent = 0;
    # Issues FAILED
    int issuesFailed = 0;
    # Issues UNKNOWN or still PENDING
    int issuesUnknown = 0;
    # Issues SKIPPED_NO_WALLET
    int issuesSkipped = 0;
|};

# A captured wallet (`scoring_coin_wallet`).
public type CoinWallet record {|
    # Employee
    types:EmployeeId employeeId;
    # Wallet address
    string walletAddress;
    # When this address was captured
    time:Utc capturedAt;
|};

# What a run did.
public type CoinRunReport record {|
    # `DONE`, `PARTIAL`, `STOPPED` or `WALLETS_OFF`
    string status;
    # Why it stopped (`STOPPED` only)
    string? stopReason = ();
    # The period
    string? period = ();
    # Open issues reconciled as sent
    int reconciledSent = 0;
    # Open issues reconciled as never sent (their points convert again)
    int reconciledNotSent = 0;
    # Open issues still undecided (too recent, ambiguous, or the search failed)
    int stillOpen = 0;
    # Transfers recorded in this run
    int sent = 0;
    # Coins in those transfers
    int coinsSent = 0;
    # Transfers the service refused in this run
    int failed = 0;
    # Transfers with no clear answer in this run
    int unknown = 0;
    # Employees with Coins due but no captured wallet
    int skippedNoWallet = 0;
    # Employees passed over: an open issue, already SENT this period, or a FAILED retry not due yet
    int passedOver = 0;
    # The period's totals
    CoinRunTotals? totals = ();
|};

# Run limits.
public type ConvertOptions record {|
    # Stop sending after this many seconds (`PARTIAL`); a re-run of the period carries on
    decimal maxSeconds = 540;
    # Reconcile an open issue only once its attempt is this old, seconds (a late commit at the service is settled)
    decimal reconcileAfterSeconds = 600;
    # Sent to the Coins service with every call
    string? correlationId = ();
|};

# Persistence port of the conversion (`scoring_coin_*`, the ledger's settlement columns).
public type CoinRepository isolated object {
    # Opens (or reopens) the period's run as RUNNING.
    #
    # + period - Period
    # + now - Start
    # + return - The run, or an error
    public isolated function openRun(string period, time:Utc now) returns CoinRun|error;

    # PENDING and UNKNOWN issues of every period.
    #
    # + return - Issues, or an error
    public isolated function openIssues() returns CoinIssue[]|error;

    # The run's issues by employee.
    #
    # + runId - Run
    # + return - Employee -> issue, or an error
    public isolated function issuesOf(string runId) returns map<CoinIssue>|error;

    # Employees with convertible rows (`isConvertible`) or a carry, oldest waiting first.
    #
    # + verifiedSince - An engagement row counts only when verified at or after this (or cleared by a PO)
    # + return - Candidates, or an error
    public isolated function candidates(time:Utc verifiedSince) returns CoinCandidate[]|error;

    # Coins already committed in the run (SENT, PENDING, UNKNOWN).
    #
    # + runId - Run
    # + return - Coins, or an error
    public isolated function committedCoins(string runId) returns int|error;

    # Whether another issue already holds a transfer reference.
    #
    # + transferReference - The service's reference
    # + return - True when taken, or an error
    public isolated function transferTaken(string transferReference) returns boolean|error;

    # Step 1, one transaction: writes the issue PENDING (a new row, or the employee's FAILED / SKIPPED_NO_WALLET row
    # of this run again, attempts + 1) and sets its reference on exactly the planned rows, which must still be HELD
    # and untaken.
    #
    # + plan - Plan with a wallet
    # + runId - Run
    # + now - Attempt time
    # + return - The issue, or an error (nothing written)
    public isolated function begin(CoinPlan plan, string runId, time:Utc now) returns CoinIssue|error;

    # Records an employee with Coins due but no wallet (SKIPPED_NO_WALLET); the rows stay untouched.
    #
    # + plan - Plan without a wallet
    # + runId - Run
    # + now - Time
    # + return - An error on failure
    public isolated function skipNoWallet(CoinPlan plan, string runId, time:Utc now) returns error?;

    # Step 3, one transaction: the issue's rows PAID, the issue SENT, an audit row.
    #
    # + issue - PENDING or UNKNOWN issue
    # + transferReference - The service's reference
    # + now - Time
    # + return - An error on failure
    public isolated function markSent(CoinIssue issue, string transferReference, time:Utc now) returns error?;

    # One transaction: the issue FAILED and its rows untagged (HELD for the next run), an audit row.
    #
    # + issue - PENDING or UNKNOWN issue
    # + errorCode - Why
    # + nextAttemptAt - Not retried in the same period before this
    # + now - Time
    # + return - An error on failure
    public isolated function markFailed(CoinIssue issue, string errorCode, time:Utc nextAttemptAt, time:Utc now)
        returns error?;

    # The issue UNKNOWN (its rows stay tagged), an audit row.
    #
    # + issue - PENDING or UNKNOWN issue
    # + errorCode - Why
    # + now - Time
    # + return - An error on failure
    public isolated function markUnknown(CoinIssue issue, string errorCode, time:Utc now) returns error?;

    # Closes the run and refreshes the period's totals.
    #
    # + runId - Run
    # + status - `DONE`, `PARTIAL` or `STOPPED`
    # + stopReason - With `STOPPED`
    # + now - End
    # + return - The totals, or an error
    public isolated function finishRun(string runId, string status, string? stopReason, time:Utc now)
        returns CoinRunTotals|error;
};

# Persistence port of the captured wallets.
public type CoinWalletRepository isolated object {
    # The employee's captured wallet.
    #
    # + employeeId - Employee
    # + return - The wallet, `()` when none, or an error
    public isolated function walletOf(types:EmployeeId employeeId) returns CoinWallet|error?;

    # Saves the employee's wallet (a new address restarts `capturedAt`), with an audit row.
    #
    # + employeeId - Employee
    # + walletAddress - Address
    # + now - Time
    # + return - The stored wallet, or an error
    public isolated function saveWallet(types:EmployeeId employeeId, string walletAddress, time:Utc now)
        returns CoinWallet|error;
};

// ---- Pure rules --------------------------------------------------------------------------------------------

# Whether a ledger row may be converted: HELD (not action required, not PAID), not taken by another conversion, and
# for an engagement row, verified at or after `verifiedSince` or cleared by a PO (V027). The repository's candidate
# query adds what one row can't show: a reversed engagement row converts with its reversal (they net to zero), and a
# reversal converts only while the row it reverses is not action required.
#
# + entry - Ledger row
# + verifiedSince - Verification cutoff; `()` = verification not considered
# + return - True when convertible
public isolated function isConvertible(types:LedgerEntry entry, time:Utc? verifiedSince = ()) returns boolean {
    if entry.status != types:HELD || entry.coinReference !is () {
        return false;
    }
    if verifiedSince is () || entry.sourceType != types:ENGAGEMENT {
        return true;
    }
    return verificationCurrent(entry, verifiedSince);
}

# The period a run at `now` belongs to: `2026-12` (MONTHLY), the ISO week `2026-W49` (WEEKLY) or `2026-12-01`
# (DAILY), all UTC.
#
# + schedule - `coin.schedule`
# + now - Run time
# + return - Period key
public isolated function coinPeriod(string schedule, time:Utc now) returns string {
    time:Civil c = time:utcToCivil(now);
    if schedule == "DAILY" {
        return string `${c.year}-${pad2(c.month)}-${pad2(c.day)}`;
    }
    if schedule == "WEEKLY" {
        // ISO 8601: a week belongs to the year of its Thursday; 1970-01-01 was a Thursday.
        int days = now[0] / 86400;
        int weekday = (days + 3) % 7 + 1;
        int thursday = days - weekday + 4;
        time:Civil t = time:utcToCivil([thursday * 86400, 0]);
        time:Utc|time:Error jan1 = time:utcFromCivil({year: t.year, month: 1, day: 1, hour: 0, minute: 0, second: 0,
            utcOffset: {hours: 0, minutes: 0}});
        int jan1Days = jan1 is time:Utc ? jan1[0] / 86400 : thursday;
        int week = (thursday - jan1Days) / 7 + 1;
        return string `${t.year}-W${pad2(week)}`;
    }
    return string `${c.year}-${pad2(c.month)}`;
}

isolated function pad2(int n) returns string => n < 10 ? "0" + n.toString() : n.toString();

# Plans one employee's conversion: carry in plus the rows, in whole blocks, within the person cap and what is left
# of the run cap; the rest carries out.
#
# + candidate - What the employee brings
# + settings - Rate and caps
# + runRemaining - Coins left under the run cap; `()` = not counted (an employee without a wallet gets nothing now)
# + return - The plan, or `()` when no whole block is due
public isolated function planConversion(CoinCandidate candidate, CoinSettings settings, int? runRemaining)
        returns CoinPlan? {
    if settings.blockPoints <= 0 || settings.blockCoins <= 0 {
        return ();
    }
    int pointsIn = 0;
    foreach ConvertibleRow r in candidate.rows {
        pointsIn += r.points;
    }
    int eligible = candidate.carryIn + pointsIn;
    int blocks = eligible > 0 ? eligible / settings.blockPoints : 0;
    int personBlocks = settings.maxCoinsPerPerson / settings.blockCoins;
    if personBlocks < blocks {
        blocks = personBlocks;
    }
    if runRemaining is int {
        int runBlocks = runRemaining > 0 ? runRemaining / settings.blockCoins : 0;
        if runBlocks < blocks {
            blocks = runBlocks;
        }
    }
    if blocks <= 0 {
        return ();
    }
    return {
        employeeId: candidate.employeeId,
        pointsIn,
        carryIn: candidate.carryIn,
        coins: blocks * settings.blockCoins,
        carryOut: eligible - blocks * settings.blockPoints,
        blockPoints: settings.blockPoints,
        blockCoins: settings.blockCoins,
        references: from ConvertibleRow r in candidate.rows select r.reference,
        walletAddress: candidate.walletAddress
    };
}

# When a FAILED issue may be retried in the same period: 15 minutes, doubling per attempt, at most a day.
#
# + attempts - Attempts so far (1 after the first)
# + now - Failure time
# + return - Earliest retry
public isolated function retryAt(int attempts, time:Utc now) returns time:Utc {
    decimal delay = RETRY_BASE_SECONDS;
    int n = attempts;
    while n > 1 && delay < RETRY_MAX_SECONDS {
        delay *= 2d;
        n -= 1;
    }
    return time:utcAddSeconds(now, delay < RETRY_MAX_SECONDS ? delay : RETRY_MAX_SECONDS);
}

# A new `CNV-` reference.
#
# + return - Reference
public isolated function newCoinReference() returns string => COIN_REFERENCE_PREFIX + types:newUuidV7();

# Whether two decimal amounts are equal (`"10"` and `"10.000000000"` are).
#
# + amount - Amount as the service sent it
# + coins - Whole Coins
# + return - True when equal
public isolated function sameAmount(string amount, int coins) returns boolean {
    decimal|error d = decimal:fromString(amount.trim());
    return d is decimal && d == <decimal>coins;
}

# A wallet address as the screens show it: the first 6 and last 4 characters (`0x12ab…9f3c`).
#
# + address - Wallet address
# + return - Masked address
public isolated function maskWallet(string address) returns string {
    string a = address.trim();
    if a.length() <= 10 {
        return a.length() <= 4 ? "…" : a.substring(0, 2) + "…";
    }
    return a.substring(0, 6) + "…" + a.substring(a.length() - 4);
}

# Settlement change on one ledger row: only the settlement columns move, every fact stays. `PAID` comes only from a
# conversion (it names the `CNV-` reference) and only to a HELD row; a PAID row is final.
#
# + entry - Ledger row
# + status - `HELD`, `PAID`, or `()` for action required
# + now - Change time
# + coinReference - The conversion's `CNV-` reference (required for `PAID`)
# + return - The row with new settlement fields, `ALREADY_PAID`, or `PAID_NOT_ALLOWED`
public isolated function changeSettlement(types:LedgerEntry entry, types:LedgerStatus? status, time:Utc now,
        string? coinReference = ()) returns types:LedgerEntry|types:DomainError {
    if entry.status == types:PAID {
        return types:domainError(types:ERR_ALREADY_PAID, "These points became Coins and can't change");
    }
    types:LedgerEntry changed = entry.clone();
    if status == types:PAID {
        if entry.status != types:HELD {
            return types:domainError(types:ERR_PAID_NOT_ALLOWED, "Only HELD points convert to Coins");
        }
        if coinReference is () || !coinReference.startsWith(COIN_REFERENCE_PREFIX) {
            return types:domainError(types:ERR_PAID_NOT_ALLOWED, "A payout names the conversion that paid it");
        }
        changed.paidAt = now;
        changed.coinReference = coinReference;
    }
    changed.status = status;
    changed.statusChangedAt = now;
    return changed;
}

// ---- Use cases ---------------------------------------------------------------------------------------------

# One conversion run (`POST /coins/convert`). The caller holds the conversion lock; re-running a period sends nothing
# for its SENT issues.
#
# + repo - Conversion repository
# + port - Coins service
# + settings - Rate, caps, schedule, switch
# + options - Limits and correlation id
# + now - Run time (every row the run writes carries it)
# + return - What was done, or a repository error (the run row stays RUNNING; the next run reopens it)
public isolated function convertCoins(CoinRepository repo, coins:CoinsPort port, CoinSettings settings,
        ConvertOptions options, time:Utc now) returns CoinRunReport|error {
    if !settings.walletsEnabled {
        return {status: RUN_WALLETS_OFF};
    }
    string period = coinPeriod(settings.schedule, now);
    CoinRun run = check repo.openRun(period, now);
    CoinRunReport report = {status: RUN_DONE, period};
    string? cid = options.correlationId;

    coins:MasterBalance|coins:CoinsError master = port.masterBalance(cid);
    if master is coins:CoinsError {
        log:printWarn("Coins conversion: master balance unavailable", errorCode = master.detail().code);
        return stop(repo, run, report, STOP_COINS_UNAVAILABLE, now);
    }

    // 1. Settle what earlier runs left open, before anything new goes out.
    check reconcileOpen(repo, port, master.walletAddress, options, now, report);

    // 2. Plan. Employees with an issue still open are passed over: their rows are tagged and nothing is resent.
    map<boolean> open = {};
    foreach CoinIssue i in check repo.openIssues() {
        open[i.employeeId] = true;
    }
    map<CoinIssue> existing = check repo.issuesOf(run.id);
    int runRemaining = settings.maxCoinsPerRun - check repo.committedCoins(run.id);
    CoinPlan[] sends = [];
    CoinPlan[] noWallet = [];
    foreach CoinCandidate c in check repo.candidates(verifiedSince(settings, now)) {
        CoinIssue? ex = existing[c.employeeId];
        if open.hasKey(c.employeeId) || (ex is CoinIssue && !retryDue(ex, now)) {
            report.passedOver += 1;
            continue;
        }
        if c.walletAddress is () {
            CoinPlan? p = planConversion(c, settings, ());
            if p is CoinPlan {
                noWallet.push(p);
            }
            continue;
        }
        CoinPlan? p = planConversion(c, settings, runRemaining);
        if p is CoinPlan {
            runRemaining -= p.coins;
            sends.push(p);
        }
    }

    // 3. No partial sends: the master wallet must cover the whole run.
    int total = 0;
    foreach CoinPlan p in sends {
        total += p.coins;
    }
    decimal|error balance = decimal:fromString(master.balance.trim());
    if balance is error || balance < <decimal>total {
        log:printWarn("Coins conversion stopped: the master wallet can't cover the run", coinsDue = total,
                period = period);
        return stop(repo, run, report, STOP_INSUFFICIENT_BALANCE, now);
    }

    foreach CoinPlan p in noWallet {
        check repo.skipNoWallet(p, run.id, now);
        report.skippedNoWallet += 1;
    }

    // 4. Send, one employee at a time.
    decimal started = time:monotonicNow();
    string? stopReason = ();
    foreach CoinPlan p in sends {
        if time:monotonicNow() - started > options.maxSeconds {
            report.status = RUN_PARTIAL;
            break;
        }
        stopReason = check sendOne(repo, port, p, run.id, cid, now, report);
        if stopReason is string {
            break;
        }
    }
    if stopReason is string {
        return stop(repo, run, report, stopReason, now);
    }
    report.totals = check repo.finishRun(run.id, report.status, (), now);
    return report;
}

# Captures the signed-in employee's wallet from the Coins service: their default wallet, else the first.
#
# + repo - Wallet repository
# + port - Coins service
# + employeeId - The caller
# + userAssertion - The caller's token, forwarded to the service
# + correlationId - Correlation id
# + now - Time
# + return - The stored wallet, `()` when the service lists no wallet for the person, a `coins:CoinsError`, or a
# repository error
public isolated function captureWallet(CoinWalletRepository repo, coins:CoinsPort port, types:EmployeeId employeeId,
        string userAssertion, string? correlationId, time:Utc now) returns CoinWallet|coins:CoinsError|error? {
    coins:Wallet[] wallets = check port.walletsOf(userAssertion, correlationId);
    if wallets.length() == 0 {
        return ();
    }
    coins:Wallet chosen = wallets[0];
    foreach coins:Wallet w in wallets {
        if w.isDefault {
            chosen = w;
            break;
        }
    }
    return repo.saveWallet(employeeId, chosen.address, now);
}

# Whether an issue of this run may be planned again: skipped for a wallet, or FAILED and its retry is due.
#
# + issue - The employee's issue in this run
# + now - Run time
# + return - True when it may be planned again
isolated function retryDue(CoinIssue issue, time:Utc now) returns boolean {
    if issue.status == COIN_SKIPPED_NO_WALLET {
        return true;
    }
    if issue.status != COIN_FAILED {
        return false;
    }
    time:Utc? next = issue.nextAttemptAt;
    return next is () || !types:isBefore(now, next);
}

# Steps 1-3 for one employee.
#
# + repo - Conversion repository
# + port - Coins service
# + plan - Plan with a wallet
# + runId - Run
# + cid - Correlation id
# + now - Run time
# + report - Counts, updated here
# + return - A stop reason when the run must stop, else `()`; an error when an outcome could not be recorded
isolated function sendOne(CoinRepository repo, coins:CoinsPort port, CoinPlan plan, string runId, string? cid,
        time:Utc now, CoinRunReport report) returns string?|error {
    CoinIssue|error issue = repo.begin(plan, runId, now);
    if issue is error {
        // Rows changed under the plan (a reversal, a PO flag): nothing written, the next run plans again.
        log:printWarn("Coins conversion: issue not started", 'error = resilience:loggable(issue));
        report.passedOver += 1;
        return;
    }
    coins:Transfer|coins:CoinsError sent = port.transfer(<string>plan.walletAddress, plan.coins, cid);
    if sent is coins:Transfer {
        error? marked = repo.markSent(issue, sent.reference, now);
        if marked is error {
            // The Coins moved; the issue stays PENDING with its rows tagged and the next run reconciles it as SENT.
            log:printError("Coins sent but not recorded; the next run reconciles it", resilience:loggable(marked));
        }
        report.sent += 1;
        report.coinsSent += plan.coins;
        return;
    }
    coins:CoinsErrorDetail d = sent.detail();
    if d.delivered == "UNKNOWN" {
        check repo.markUnknown(issue, d.code, now);
        report.unknown += 1;
        log:printWarn("Coins transfer outcome unknown; reconciled on the next run", errorCode = d.code);
        return STOP_OUTCOME_UNKNOWN;
    }
    check repo.markFailed(issue, d.code, retryAt(issue.attempts, now), now);
    report.failed += 1;
    log:printWarn("Coins transfer refused", errorCode = d.code, httpStatus = d.httpStatus);
    if d.code == coins:INSUFFICIENT_FUNDS {
        return STOP_INSUFFICIENT_BALANCE;
    }
    if d.code == coins:UNAVAILABLE || d.code == coins:UNAUTHORIZED || d.code == coins:RATE_LIMITED {
        return STOP_COINS_UNAVAILABLE;
    }
    // RECIPIENT_NOT_FOUND, REJECTED: this employee only; the run goes on.
    return;
}

# Reconciles every open issue old enough: one matching transfer -> SENT; none -> FAILED (the rows convert again);
# more than one -> UNKNOWN with `RECONCILE_AMBIGUOUS` for an operator.
#
# + repo - Conversion repository
# + port - Coins service
# + master - Amplify's master wallet
# + options - `reconcileAfterSeconds`, correlation id
# + now - Run time
# + report - Counts, updated here
# + return - A repository error
isolated function reconcileOpen(CoinRepository repo, coins:CoinsPort port, string master, ConvertOptions options,
        time:Utc now, CoinRunReport report) returns error? {
    foreach CoinIssue issue in check repo.openIssues() {
        time:Utc? at = issue.attemptedAt;
        string? wallet = issue.walletAddress;
        if at is () || wallet is () || time:utcDiffSeconds(now, at) < options.reconcileAfterSeconds {
            report.stillOpen += 1;
            continue;
        }
        coins:TransactionPage|coins:CoinsError page = port.searchTransfers({
            fromAddresses: [master],
            toAddresses: [wallet],
            dateFrom: time:utcToString(time:utcAddSeconds(at, -RECONCILE_SKEW_SECONDS)),
            'limit: 100
        }, options.correlationId);
        if page is coins:CoinsError {
            log:printWarn("Coins reconcile: search failed", errorCode = page.detail().code);
            report.stillOpen += 1;
            continue;
        }
        string[] matches = [];
        foreach coins:Transaction t in page.transactions {
            if sameAmount(t.amount, issue.coins) && !check repo.transferTaken(t.reference) {
                matches.push(t.reference);
            }
        }
        if matches.length() == 1 {
            check repo.markSent(issue, matches[0], now);
            report.reconciledSent += 1;
        } else if matches.length() == 0 && page.total <= page.transactions.length() {
            check repo.markFailed(issue, ERR_NOT_SENT, now, now);
            report.reconciledNotSent += 1;
        } else {
            // Two candidates, or more pages than one search reads: never guess with money.
            if issue.lastErrorCode != ERR_RECONCILE_AMBIGUOUS {
                check repo.markUnknown(issue, ERR_RECONCILE_AMBIGUOUS, now);
            }
            log:printWarn("Coins reconcile ambiguous; an operator decides", candidates = matches.length());
            report.stillOpen += 1;
        }
    }
}

# Closes the run as STOPPED.
#
# + repo - Conversion repository
# + run - Run
# + report - Report to complete
# + reason - Stop reason
# + now - Time
# + return - The report, or a repository error
isolated function stop(CoinRepository repo, CoinRun run, CoinRunReport report, string reason, time:Utc now)
        returns CoinRunReport|error {
    report.status = RUN_STOPPED;
    report.stopReason = reason;
    report.totals = check repo.finishRun(run.id, RUN_STOPPED, reason, now);
    return report;
}
