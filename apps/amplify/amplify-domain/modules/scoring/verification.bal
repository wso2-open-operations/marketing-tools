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

// Pre-coin verification (Task #1767, V027, ADR-048 amendment). Before any Coins are paid, the LinkedIn activity behind
// every HELD engagement row the conversion could take is checked again:
//   still there        -> VERIFIED at the run time; the conversion takes the row while that is within
//                         `coin.verify_max_age_hours` (`isConvertible`)
//   gone (404/410)     -> REMOVED, and the row is reversed by the system ("No longer on LinkedIn") in the same
//                         transaction; the pair nets to zero and converts together
//   can't be checked   -> UNVERIFIABLE with a reason code, and the row becomes action required (status NULL) for the
//                         PO team; a PO setting it HELD again clears it (PO_CLEARED) for good
// Own posts (EXTERNAL_SHARE) were approved by a PO, and adjustments and reversals are the PO's or the system's own
// rows: none of them is checked. The checks themselves (which token, which LinkedIn read, the call budgets) live
// behind `EngagementChecker`, which amplify-jobs builds from the sharing and connection contexts (ADR-005: scoring
// never reads their tables).

import amplify_common.types;

import ballerina/log;
import ballerina/time;

# Default `coin.verify_max_age_hours`.
public const int DEFAULT_VERIFY_MAX_AGE_HOURS = 48;

# The reason on a reversal the verification writes.
public const string REASON_NO_LONGER_ON_LINKEDIN = "No longer on LinkedIn";

# The activity is still on LinkedIn.
public const CHECK_PRESENT = "PRESENT";
# LinkedIn says it was deleted.
public const CHECK_GONE = "GONE";
# It could not be checked (`reason` says why).
public const CHECK_UNVERIFIABLE = "UNVERIFIABLE";

# What one check found.
public type CheckOutcome CHECK_PRESENT|CHECK_GONE|CHECK_UNVERIFIABLE;

# The employee has no connection or no token row the check needs.
public const VERIFY_NO_TOKEN = "NO_TOKEN";
# The token the check needs has expired, or LinkedIn refused it (401).
public const VERIFY_TOKEN_EXPIRED = "TOKEN_EXPIRED";
# LinkedIn answered 403: the token may not read this activity.
public const VERIFY_NOT_PERMITTED = "NOT_PERMITTED";
# The engagement holds no URN to read (an old row), or LinkedIn refused the request as malformed.
public const VERIFY_NO_ACTIVITY = "NO_ACTIVITY";
# The engagement row behind the ledger row is missing.
public const VERIFY_SOURCE_NOT_FOUND = "SOURCE_NOT_FOUND";
# The member was erased; there is no member URN to check a reaction with.
public const VERIFY_MEMBER_ERASED = "MEMBER_ERASED";

# One check's result.
public type CheckResult record {|
    # What was found
    CheckOutcome outcome;
    # Why it could not be checked (`UNVERIFIABLE` only)
    string? reason = ();
|};

# The day's call budget is spent; the next run carries on.
public const VERIFY_STOP_BUDGET = "BUDGET_REACHED";
# LinkedIn answered 429.
public const VERIFY_STOP_RATE_LIMITED = "RATE_LIMITED";
# LinkedIn could not be reached or answered 5xx.
public const VERIFY_STOP_UNAVAILABLE = "UNAVAILABLE";

# Detail of `VerifyStop`.
public type VerifyStopDetail record {|
    # `BUDGET_REACHED`, `RATE_LIMITED` or `UNAVAILABLE`
    string reason;
|};

# The run must stop: nothing is recorded for the row, and the next run checks it again.
public type VerifyStop distinct error<VerifyStopDetail>;

# A ledger row to check.
public type VerifyCandidate record {|
    # Ledger reference
    types:LedgerReference reference;
    # Employee
    types:EmployeeId employeeId;
    # `sharing_engagement.id` (the row's `source_id`)
    string engagementId;
    # Priced action
    types:PointAction? action;
|};

# Checks the LinkedIn activity behind one ledger row (amplify-jobs: sharing + connection + LinkedIn).
public type EngagementChecker isolated object {
    # Checks one row.
    #
    # + candidate - The row
    # + now - Run time
    # + return - What was found, `VerifyStop` to end the run, or an error (the run ends with it)
    public isolated function verify(VerifyCandidate candidate, time:Utc now) returns CheckResult|VerifyStop|error;
};

# Persistence port of the verification (the ledger's settlement and verification columns).
public type VerificationRepository isolated object {
    # Engagement rows the conversion could take that are due a check: never checked, or VERIFIED before
    # `staleBefore`; never a reversed row. Never checked first, then the oldest check, then the oldest row.
    #
    # + staleBefore - Re-check rows verified before this
    # + 'limit - Most rows
    # + return - Rows, or an error
    public isolated function dueForCheck(time:Utc staleBefore, int 'limit) returns VerifyCandidate[]|error;

    # Records VERIFIED at `now` on a row still HELD and untaken (an audit row too).
    #
    # + reference - Row
    # + now - Run time
    # + return - An error on failure
    public isolated function markVerified(types:LedgerReference reference, time:Utc now) returns error?;

    # Records UNVERIFIABLE with its reason and sets the row action required, if still HELD and untaken (an audit row
    # too).
    #
    # + reference - Row
    # + reason - Reason code
    # + now - Run time
    # + return - An error on failure
    public isolated function markUnverifiable(types:LedgerReference reference, string reason, time:Utc now)
        returns error?;

    # One transaction: records REMOVED and appends the system reversal ("No longer on LinkedIn"), if the row is still
    # HELD, untaken and not reversed.
    #
    # + reference - Row
    # + correlationId - Run correlation id
    # + now - Run time
    # + return - True when reversed, false when the row changed meanwhile, or an error
    public isolated function reverseRemoved(types:LedgerReference reference, string? correlationId, time:Utc now)
        returns boolean|error;
};

# Run finished every row due.
public const VERIFY_DONE = "DONE";
# Run stopped at the time limit; the next run carries on.
public const VERIFY_PARTIAL = "PARTIAL";
# Run stopped early (`stopReason`); the rows not reached are not converted until checked.
public const VERIFY_STOPPED = "STOPPED";

# Run limits.
public type VerifyOptions record {|
    # `coin.verify_max_age_hours`; a row verified more than half of it ago is checked again
    int maxAgeHours = DEFAULT_VERIFY_MAX_AGE_HOURS;
    # Stop after this many seconds (`PARTIAL`)
    decimal maxSeconds = 540;
    # Rows read per batch
    int batchSize = 200;
    # Written on the reversals
    string? correlationId = ();
|};

# What a run did.
public type VerifyReport record {|
    # `DONE`, `PARTIAL` or `STOPPED`
    string status;
    # Why it stopped (`STOPPED` only)
    string? stopReason = ();
    # Rows checked
    int checked = 0;
    # Still there
    int verified = 0;
    # Gone and reversed
    int removed = 0;
    # Could not be checked, now action required
    int actionRequired = 0;
    # Why rows could not be checked, by reason code
    map<int> unverifiableByReason = {};
|};

// ---- Pure rules --------------------------------------------------------------------------------------------

# Whether an engagement row's verification lets it convert: cleared by a PO, or VERIFIED at or after `since`.
#
# + entry - Ledger row
# + since - Cutoff
# + return - True when current
public isolated function verificationCurrent(types:LedgerEntry entry, time:Utc since) returns boolean {
    if entry.verification == types:PO_CLEARED {
        return true;
    }
    time:Utc? at = entry.verifiedAt;
    return entry.verification == types:VERIFIED && at is time:Utc && !types:isBefore(at, since);
}

# The oldest verification a conversion at `now` accepts: `now - coin.verify_max_age_hours`.
#
# + settings - Conversion settings
# + now - Run time
# + return - Cutoff
public isolated function verifiedSince(CoinSettings settings, time:Utc now) returns time:Utc =>
    time:utcAddSeconds(now, -<decimal>(maxAgeHours(settings.verifyMaxAgeHours) * 3600));

# Rows verified before this are checked again: half the max age, so a row verified by one run is still current an
# hour later when the conversion runs, without checking every row on every run.
#
# + maxAge - `coin.verify_max_age_hours`
# + now - Run time
# + return - Cutoff
public isolated function recheckBefore(int maxAge, time:Utc now) returns time:Utc =>
    time:utcAddSeconds(now, -<decimal>(maxAgeHours(maxAge) * 1800));

isolated function maxAgeHours(int hours) returns int => hours < 1 ? DEFAULT_VERIFY_MAX_AGE_HOURS : hours;

# The verification run's stop error.
#
# + reason - `BUDGET_REACHED`, `RATE_LIMITED` or `UNAVAILABLE`
# + return - The error
public isolated function verifyStop(string reason) returns VerifyStop => error VerifyStop("Verification stopped", reason = reason);

// ---- Use cases ---------------------------------------------------------------------------------------------

# One verification run (amplify-jobs `POST /coins/verify`). The caller holds the verification lock.
#
# + repo - Verification repository
# + checker - The LinkedIn checks
# + options - Limits
# + now - Run time (every row the run marks carries it)
# + return - What was done, or a repository error
public isolated function verifyForCoins(VerificationRepository repo, EngagementChecker checker, VerifyOptions options,
        time:Utc now) returns VerifyReport|error {
    VerifyReport report = {status: VERIFY_DONE};
    time:Utc staleBefore = recheckBefore(options.maxAgeHours, now);
    decimal started = time:monotonicNow();
    map<boolean> seen = {};
    int size = options.batchSize < 1 ? 1 : options.batchSize;
    while true {
        VerifyCandidate[] batch = check repo.dueForCheck(staleBefore, size);
        boolean progressed = false;
        foreach VerifyCandidate c in batch {
            if seen.hasKey(c.reference) {
                // Marked already in this run but still listed (it changed under us): never loop on it.
                continue;
            }
            if time:monotonicNow() - started > options.maxSeconds {
                report.status = VERIFY_PARTIAL;
                return report;
            }
            seen[c.reference] = true;
            progressed = true;
            CheckResult|VerifyStop|error result = checker.verify(c, now);
            if result is VerifyStop {
                report.status = VERIFY_STOPPED;
                report.stopReason = result.detail().reason;
                log:printWarn("Pre-coin verification stopped", stopReason = report.stopReason, checked = report.checked);
                return report;
            }
            if result is error {
                return result;
            }
            report.checked += 1;
            match result.outcome {
                CHECK_PRESENT => {
                    check repo.markVerified(c.reference, now);
                    report.verified += 1;
                }
                CHECK_GONE => {
                    if check repo.reverseRemoved(c.reference, options.correlationId, now) {
                        report.removed += 1;
                    }
                }
                _ => {
                    string reason = result.reason ?: VERIFY_NO_ACTIVITY;
                    check repo.markUnverifiable(c.reference, reason, now);
                    report.actionRequired += 1;
                    report.unverifiableByReason[reason] = (report.unverifiableByReason[reason] ?: 0) + 1;
                }
            }
        }
        if !progressed || batch.length() < size {
            return report;
        }
    }
}

# A PO changes a row's settlement (`POST /po/points/{reference}/settlement`): `HELD` clears an action-required row
# (it converts without another check), `()` sets a row action required. PAID only comes from a conversion.
#
# + repo - Ledger repository
# + reference - Row
# + status - `HELD` or `()`
# + actorId - The PO
# + now - Current time
# + return - The row after the change, a domain error (`NOT_FOUND`, `SELF_REVIEW`, `ALREADY_PAID`,
# `PAID_NOT_ALLOWED`), or a repository error
public isolated function settleEntry(LedgerRepository repo, string reference, types:LedgerStatus? status,
        types:EmployeeId actorId, time:Utc now) returns types:LedgerEntry|error {
    types:LedgerReference ref = check types:parseLedgerReference(reference);
    types:LedgerEntry? entry = check repo.findByReference(ref);
    if entry is () {
        return types:domainError(types:ERR_NOT_FOUND, "Ledger entry not found");
    }
    if entry.employeeId == actorId {
        return types:domainError(types:ERR_SELF_REVIEW, "You can't settle your own points");
    }
    if status == types:PAID {
        return types:domainError(types:ERR_PAID_NOT_ALLOWED, "Points become PAID only through the Coins conversion");
    }
    _ = check changeSettlement(entry, status, now);
    check repo.updateSettlement(ref, status, now);
    return (check repo.findByReference(ref)) ?: entry;
}
