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
// empty or the row/time budget is spent. Ends with one structured run log line.

import amplify_common.resilience;
import amplify_common.types;
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

    report.linkedinPosts = budget.used();
    isolated function () returns map<string> breakers = deps.breakers;
    report.breakers = breakers();
    resilience:exportBreakerStates(COMPONENT, report.breakers);
    report.durationMs = <int>((time:monotonicNow() - started) * 1000);
    log:printInfo("Run finished", runId = report.runId, correlationId = report.correlationId,
            claimed = report.claimed, succeeded = report.succeeded, retried = report.retried,
            deferred = report.deferred, failed = report.failed, staleReleased = report.staleReleased,
            linkedinPosts = report.linkedinPosts, expiringConnections = report.connections.expiring,
            needsReconnect = report.connections.needsReconnect, breakers = report.breakers.toString(),
            durationMs = report.durationMs);
    return report;
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
        chat: deps.chat,
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
