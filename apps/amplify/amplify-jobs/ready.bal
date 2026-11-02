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

// Readiness (`GET /ready`) and the start-up check of the run tuning.

import amplify_common.types;

# Body of `GET /ready`.
type ReadyReport record {|
    # `amplify-jobs`
    string component;
    # `UP` when the worker can do its work (the database), else `DOWN`
    types:HealthState status;
    # Database: breaker not open and a trivial query answers
    types:HealthState database;
    # True while a run holds this replica's in-process flag
    boolean runInProgress;
    # Breaker state per dependency (reported, not fatal: LinkedIn and Chat outages only defer rows)
    map<string> breakers;
    # What the outbox holds; absent when the database is down or the backlog could not be read. Reported, not
    # fatal: `alerting` is the signal to page on (a row waiting longer than `outboxAlertSeconds`, or one that failed)
    OutboxReport outbox?;
    # Days ahead with a token partition; `alerting` when fewer than `tokenPartitionAlertDays` (the daily maintenance run
    # is the only thing that creates them)
    TokenPartitionReport tokenPartitions?;
|};

# Readiness from its inputs. Only the database gates it: without LinkedIn, Chat or the token keys the run
# still works and defers those rows (ADR-025), so they are reported, not fatal (as amplify-api's `/ready`).
#
# + databaseUp - Database breaker not open and the probe answered
# + breakers - Breaker state per dependency
# + running - Whether a run is in progress on this replica
# + outbox - The outbox backlog, when it was read
# + tokenPartitions - The token partition runway, when it was read
# + return - The report
isolated function readiness(boolean databaseUp, map<string> breakers, boolean running, OutboxReport? outbox = (),
        TokenPartitionReport? tokenPartitions = ()) returns ReadyReport {
    ReadyReport report = {
        component: COMPONENT,
        status: databaseUp ? types:UP : types:DOWN,
        database: databaseUp ? types:UP : types:DOWN,
        runInProgress: running,
        breakers: breakers.clone()
    };
    if outbox is OutboxReport {
        report.outbox = outbox;
    }
    if tokenPartitions is TokenPartitionReport {
        report.tokenPartitions = tokenPartitions;
    }
    return report;
}

# Whether `/ready` answers 200. Choreo stops routing on any non-2xx readiness response, so a database blip
# that opens the breaker for a few seconds would turn every scheduler call into a network failure.
# `POST /runs` already answers a clean 503 while the database is unavailable, and the scheduler retries a
# 5xx, so only a missing database configuration (the worker can never do its work) keeps it unready.
#
# + databaseConfigured - `dbHost` is set
# + return - True when the process should stay in rotation
isolated function readyKeepsRouting(boolean databaseConfigured) returns boolean => databaseConfigured;

# Whether a run is in progress on this replica.
#
# + return - The in-process flag
isolated function isRunInProgress() returns boolean {
    lock {
        return runInProgress;
    }
}

# Checks the run tuning at start-up. A row stays locked for `leaseSeconds` from its claim, and the run
# starts a row only inside `maxSeconds`, so a run that starts its last row at the budget's end must finish
# that row (its longest external call) before the lease runs out. Otherwise the next run releases the row
# as stale while it is still being handled, and a LinkedIn post can go out twice.
#
# + cfg - Run tuning
# + longestCallSeconds - Longest external call of one row (timeout plus any throttle wait)
# + return - An error naming the bad setting
isolated function validateRunConfig(RunConfig cfg, decimal longestCallSeconds) returns error? {
    if cfg.batchSize < 1 || cfg.maxRows < 1 || cfg.maxSeconds < 1 || cfg.maxAttempts < 1 {
        return error("runBatchSize, runMaxRows, runMaxSeconds and maxAttempts must be at least 1");
    }
    if cfg.linkedinMaxPostsPerRun < 0 || cfg.linkedinMaxPostsPerDay < 0 {
        return error("linkedinMaxPostsPerRun and linkedinMaxPostsPerDay must not be negative");
    }
    if cfg.backoffBaseSeconds <= 0d || cfg.backoffMaxSeconds < cfg.backoffBaseSeconds || cfg.deferSeconds <= 0d {
        return error("backoffBaseSeconds and deferSeconds must be positive and backoffMaxSeconds >= backoffBaseSeconds");
    }
    decimal needed = <decimal>cfg.maxSeconds + longestCallSeconds;
    if needed >= <decimal>cfg.leaseSeconds {
        return error(string `runLockLeaseSeconds (${cfg.leaseSeconds}) must exceed runMaxSeconds (${cfg.maxSeconds}) `
                + string `plus the longest call (${longestCallSeconds} s)`);
    }
}

# Longest external call one row can make: the LinkedIn timeout, or what a `CampaignRegistered` row does: the
# Chat timeout plus its throttle wait and, with Novera on, the token fetch and the notify (each bounded by
# the Novera timeout) before the best-effort Chat card.
#
# + return - Seconds
isolated function longestCallSeconds() returns decimal {
    decimal chat = chatTimeoutSeconds + chatMinIntervalSeconds;
    decimal registered = amplifyOnNovera ? 2d * noveraTimeoutSeconds + chat : chat;
    return linkedinTimeoutSeconds > registered ? linkedinTimeoutSeconds : registered;
}
