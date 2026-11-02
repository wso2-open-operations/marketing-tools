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

// Outbox backlog (security review, "operational resilience"). A deferred outbox row, for example a Chat card while
// the webhook is unconfigured or Novera is down, can wait for ever with nothing to say so. The backlog is read on
// every readiness probe (cached for a few seconds), exported as gauges, and logged as a warning when the oldest
// pending row is older than `outboxAlertSeconds` or any row has failed every attempt.

import amplify_common.resilience;
import amplify_domain.store;

import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

# Age of the oldest pending outbox row, in seconds, past which the backlog is alerting. Default 1 hour.
configurable int outboxAlertSeconds = 3600;
# How long a read of the backlog is reused, seconds, so a probe every few seconds does not query the table each time.
configurable decimal outboxBacklogCacheSeconds = 15;
# Minimum seconds between two warning log lines about the same backlog.
configurable decimal outboxAlertLogIntervalSeconds = 300;

# The backlog as `GET /ready` reports it.
type OutboxReport record {|
    # Rows waiting, including deferred ones
    int pending;
    # Rows a run is handling now
    int inProgress;
    # Rows that used every attempt
    int failed;
    # Age in seconds of the oldest pending row, absent when none is pending
    int oldestPendingSeconds?;
    # True when the oldest pending row is older than `outboxAlertSeconds`, or any row failed
    boolean alerting;
|};

# Whether a backlog needs someone's attention.
#
# + backlog - What the outbox holds
# + thresholdSeconds - `outboxAlertSeconds`
# + return - True when the oldest pending row is over the threshold, or any row failed every attempt
isolated function isBacklogAlerting(store:OutboxBacklog backlog, int thresholdSeconds) returns boolean {
    int? oldest = backlog.oldestPendingSeconds;
    return backlog.failed > 0 || (oldest is int && oldest > thresholdSeconds);
}

# The backlog as a report.
#
# + backlog - What the outbox holds
# + thresholdSeconds - `outboxAlertSeconds`
# + return - The report
isolated function toOutboxReport(store:OutboxBacklog backlog, int thresholdSeconds) returns OutboxReport {
    int? oldest = backlog.oldestPendingSeconds;
    OutboxReport report = {pending: backlog.pending, inProgress: backlog.inProgress, failed: backlog.failed,
        alerting: isBacklogAlerting(backlog, thresholdSeconds)};
    if oldest is int {
        report.oldestPendingSeconds = oldest;
    }
    return report;
}

// One variable, so a single lock covers the cache and the log throttle together.
type BacklogState record {|
    OutboxReport? report;
    decimal readAt;
    decimal alertLoggedAt;
|};

isolated BacklogState backlogState = {report: (), readAt: -1000, alertLoggedAt: -1000};

# Reads the backlog (reused for `outboxBacklogCacheSeconds`), exports the gauges and warns when it is alerting.
# Never fails the caller: an unreadable backlog is logged and reported as absent.
#
# + pg - Database client
# + return - The report, or `()` when it can't be read
isolated function outboxReport(postgresql:Client pg) returns OutboxReport? {
    decimal now = time:monotonicNow();
    lock {
        OutboxReport? cached = backlogState.report;
        if cached is OutboxReport && now - backlogState.readAt < outboxBacklogCacheSeconds {
            return cached.clone();
        }
    }
    store:OutboxBacklog|error backlog = store:outboxBacklog(pg);
    if backlog is error {
        log:printWarn("Outbox backlog unreadable", resilience:loggable(backlog));
        return ();
    }
    OutboxReport report = toOutboxReport(backlog, outboxAlertSeconds);
    resilience:exportOutboxBacklog(COMPONENT, backlog.pending, backlog.failed, backlog.oldestPendingSeconds);
    boolean warn = false;
    lock {
        decimal loggedAt = backlogState.alertLoggedAt;
        if report.alerting && now - loggedAt >= outboxAlertLogIntervalSeconds {
            loggedAt = now;
            warn = true;
        }
        backlogState = {report: report.clone(), readAt: now, alertLoggedAt: loggedAt};
    }
    if warn {
        log:printWarn("Outbox backlog needs attention", pending = report.pending, failed = report.failed,
                oldestPendingSeconds = report.oldestPendingSeconds, thresholdSeconds = outboxAlertSeconds);
    }
    return report;
}
