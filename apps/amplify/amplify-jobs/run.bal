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

// The Run (plan M6): one at a time (in-process flag + PostgreSQL advisory lock), release stale locks,
// sweep, then claim outbox batches `FOR UPDATE SKIP LOCKED` and dispatch each row until the queue is
// empty or the row/time budget is spent, then copy Novera's seen counts for recent announcements (V023) with
// what is left of the time budget. Ends with one structured run log line.

import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.store;

import ballerina/log;
import ballerina/time;

# Structured run log, also the `POST /runs` response body.
type RunReport record {|
    # Run id (UUIDv7); `outbox.locked_by`
    string runId;
    # Correlation id of the trigger, when one was sent
    string? correlationId;
    # Start, RFC 3339 UTC
    string startedAt;
    # Rows claimed
    int claimed;
    # Rows `DONE`
    int succeeded;
    # Rows put back with backoff
    int retried;
    # Rows put back without counting an attempt (kill switch, ceiling, not configured, not open yet)
    int deferred;
    # Rows `FAILED`
    int failed;
    # Stale locks released at start
    int staleReleased;
    # LinkedIn posts made
    int linkedinPosts;
    # Announcements whose Novera seen count was refreshed
    int noveraStats = 0;
    # Connection sweep (derived status)
    ConnectionSweep connections;
    # Breaker state per dependency at the end of the run
    map<string> breakers;
    # Wall-clock duration, milliseconds
    int durationMs;
|};

# Returned when another run holds the lock.
type RunSkipped record {|
    # `SKIPPED`
    string status = "SKIPPED";
    # `RUN_IN_PROGRESS`
    string reason = "RUN_IN_PROGRESS";
|};

isolated boolean runInProgress = false;

# Runs once unless a run is already going (here or on another replica).
#
# + deps - Dependencies
# + correlationId - Trigger correlation id, if any
# + return - The run log, `RunSkipped`, or an error (database unreachable)
isolated function runOnce(Deps deps, string? correlationId = ()) returns RunReport|RunSkipped|error {
    lock {
        if runInProgress {
            return <RunSkipped>{};
        }
        runInProgress = true;
    }
    do {
        // `trap`: a panic anywhere in the run must still release the flag and the lock, or every later
        // call would answer SKIPPED until the process restarts.
        boolean acquired = check trap deps.runLock.tryAcquire();
        if !acquired {
            check releaseFlag();
            return <RunSkipped>{};
        }
        RunReport|error report = trap execute(deps, correlationId);
        error? released = deps.runLock.release();
        if released is error {
            log:printError("Run lock release failed (the session drop releases it)", released);
        }
        check releaseFlag();
        return report;
    } on fail error e {
        check releaseFlag();
        return e;
    }
}

isolated function releaseFlag() returns error? {
    lock {
        runInProgress = false;
    }
}

isolated function execute(Deps deps, string? correlationId) returns RunReport|error {
    RunConfig cfg = deps.config;
    string runId = types:newUuidV7();
    decimal started = time:monotonicNow();
    time:Utc startedAt = time:utcNow();
    RunReport report = {
        runId,
        correlationId,
        startedAt: time:utcToString(startedAt),
        claimed: 0,
        succeeded: 0,
        retried: 0,
        deferred: 0,
        failed: 0,
        staleReleased: 0,
        linkedinPosts: 0,
        connections: {expiring: 0, needsReconnect: 0},
        breakers: {},
        durationMs: 0
    };

    report.staleReleased = check deps.runStore.releaseStale();
    RunSettings settings = check deps.runStore.settings();
    report.connections = check deps.runStore.connectionSweep();
    int publishedToday = check deps.runStore.publishedToday(startedAt);
    int dailyLeft = cfg.linkedinMaxPostsPerDay - publishedToday;
    LinkedInBudget budget = new (dailyLeft < cfg.linkedinMaxPostsPerRun ? dailyLeft : cfg.linkedinMaxPostsPerRun);

    while report.claimed < cfg.maxRows && time:monotonicNow() - started < <decimal>cfg.maxSeconds {
        int room = cfg.maxRows - report.claimed;
        store:OutboxRow[] rows = check deps.runStore.claim(runId, room < cfg.batchSize ? room : cfg.batchSize,
                cfg.leaseSeconds);
        if rows.length() == 0 {
            break;
        }
        report.claimed += rows.length();
        foreach store:OutboxRow row in rows {
            if time:monotonicNow() - started >= <decimal>cfg.maxSeconds {
                // Out of time: hand the rest back untouched so the next run picks them up now.
                check deps.runStore.requeue(row.id, runId, 0, "run time budget spent", false);
                report.deferred += 1;
                continue;
            }
            check settle(deps, runId, row, processRow(deps, row, settings, budget, runId), report);
        }
    }

    report.noveraStats = refreshNoveraStats(deps, correlationId ?: runId, started);
    report.linkedinPosts = budget.used();
    isolated function () returns map<string> breakers = deps.breakers;
    report.breakers = breakers();
    resilience:exportBreakerStates(COMPONENT, report.breakers);
    report.durationMs = <int>((time:monotonicNow() - started) * 1000);
    log:printInfo("Run finished", runId = report.runId, correlationId = report.correlationId,
            claimed = report.claimed, succeeded = report.succeeded, retried = report.retried,
            deferred = report.deferred, failed = report.failed, staleReleased = report.staleReleased,
            linkedinPosts = report.linkedinPosts, noveraStats = report.noveraStats,
            expiringConnections = report.connections.expiring,
            needsReconnect = report.connections.needsReconnect, breakers = report.breakers.toString(),
            durationMs = report.durationMs);
    return report;
}

# Copies Novera's seen counts for recent broadcasts (V023), oldest count first, within what is left of the run's
# time budget. Never fails the run: a count that can't be read is tried again on a later run. A broadcast Novera
# doesn't know, or an answer that isn't a count, keeps only the time it was asked, so it waits a refresh interval.
# Novera unreachable, down (502, 503, 504), refusing the credentials or rate limiting stops the batch; a 500 skips
# only that broadcast.
#
# + deps - Dependencies
# + correlationId - Sent to Novera and logged
# + started - Run start (monotonic seconds)
# + return - Counts saved
isolated function refreshNoveraStats(Deps deps, string correlationId, decimal started) returns int {
    RunConfig cfg = deps.config;
    NoveraPort? novera = deps.novera;
    NoveraStatsStore? statsStore = deps.noveraStats;
    if !cfg.noveraSeenStatsEnabled || novera is () || statsStore is () || cfg.noveraStatsBatch < 1 {
        return 0;
    }
    announcements:NoveraStatsTarget[]|error due = statsStore.noveraStatsDue(cfg.noveraStatsWindowDays,
            cfg.noveraStatsRefreshSeconds, cfg.noveraStatsBatch);
    if due is error {
        log:printWarn("Novera seen counts not refreshed: due list unavailable", resilience:loggable(due),
                correlationId = correlationId);
        return 0;
    }
    int saved = 0;
    foreach announcements:NoveraStatsTarget target in due {
        if time:monotonicNow() - started >= <decimal>cfg.maxSeconds {
            break;
        }
        announcements:NoveraSeenStats|NoveraError stats = novera.stats(target.notificationId, correlationId);
        announcements:NoveraSeenStats? count = ();
        if stats is NoveraError {
            NoveraErrorDetail d = stats.detail();
            // NOT_COUNTED is routine (Novera's read-state check is off or hasn't reached the card yet): no warning.
            if d.code != "NOT_COUNTED" {
                log:printWarn("Novera seen count not read", campaignId = target.campaignId, errorCode = d.code,
                        httpStatus = d.httpStatus, correlationId = correlationId);
            }
            boolean answered = d.code == "NOT_FOUND" || d.code == "BAD_RESPONSE" || d.code == "REJECTED"
                    || d.code == "NOT_COUNTED";
            if !answered {
                int? status = d.httpStatus;
                // No answer, a refused credential, a limit, or the gateway or Novera saying it is down: the rest
                // would fail the same way. Another status (a 500) may be about this broadcast only.
                if status is () || d.code == "RATE_LIMITED" || status == 401 || status == 403 || status == 502
                        || status == 503 || status == 504 {
                    break;
                }
                continue;
            }
        } else {
            count = stats;
        }
        error? written = statsStore.saveNoveraStats(target.campaignId, count, time:utcNow());
        if written is error {
            log:printWarn("Novera seen count not saved", resilience:loggable(written), campaignId = target.campaignId,
                    correlationId = correlationId);
            continue;
        }
        if count !is () {
            saved += 1;
        }
    }
    return saved;
}

isolated function processRow(Deps deps, store:OutboxRow row, RunSettings settings, LinkedInBudget budget,
        string runId) returns Outcome {
    // Correlation id travels outbox row → handler → audit/outbox writes → external calls (M9).
    string correlationId = row.correlationId ?: runId;
    return dispatch({
        store: deps.runStore.forRow(correlationId, settings.topN),
        row,
        correlationId,
        settings,
        config: deps.config,
        novera: deps.novera,
        linkedIn: deps.linkedIn,
        cipher: deps.cipher,
        budget,
        finalAttempt: row.attempts >= deps.config.maxAttempts,
        now: time:utcNow()
    });
}

isolated function settle(Deps deps, string runId, store:OutboxRow row, Outcome outcome, RunReport report) returns error? {
    RunConfig cfg = deps.config;
    string note = outcome.note ?: "";
    match outcome.kind {
        DONE => {
            check deps.runStore.complete(row.id, runId);
            report.succeeded += 1;
        }
        DEFER => {
            check deps.runStore.requeue(row.id, runId, outcome.delaySeconds ?: cfg.deferSeconds, note, false);
            report.deferred += 1;
        }
        RETRY => {
            if row.attempts >= cfg.maxAttempts {
                check deps.runStore.failRow(row.id, runId, "retries exhausted: " + note);
                report.failed += 1;
            } else {
                check deps.runStore.requeue(row.id, runId,
                        backoffSeconds(row.attempts, cfg.backoffBaseSeconds, cfg.backoffMaxSeconds), note, true);
                report.retried += 1;
            }
        }
        FAIL => {
            check deps.runStore.failRow(row.id, runId, note);
            report.failed += 1;
        }
    }
    log:printDebug("Outbox row settled", outboxId = row.id, eventType = row.eventType, outcome = outcome.kind,
            attempts = row.attempts, note = note, correlationId = row.correlationId ?: runId);
}
