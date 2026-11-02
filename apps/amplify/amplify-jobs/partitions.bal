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

// Token partition runway (review of V009). A token insert into a day with no partition fails, and the daily maintenance
// run is the only thing that creates them, so a job that has quietly stopped means connects start failing a week or two
// later. Three guards: the runway is 14 days (V009), jobs creates the partitions at start-up as well as in the daily run,
// and the days left are exported as `amplify_token_partition_days_ahead` and reported on `/ready`.

import amplify_common.resilience;
import amplify_domain.store;

import ballerina/lang.runtime;
import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

# Days ahead of today that start-up creates partitions for (the same as V009's default).
const int TOKEN_PARTITION_DAYS_AHEAD = 14;

# Alert when fewer days than this have a partition. Default 3: the maintenance run has been down for most of the runway.
configurable int tokenPartitionAlertDays = 3;

# The runway as `GET /ready` reports it.
type TokenPartitionReport record {|
    # Days past today (UTC) that have a partition; absent when none exists or it could not be read
    int daysAhead?;
    # True when the runway is shorter than `tokenPartitionAlertDays`, or unknown
    boolean alerting;
|};

# Whether the runway needs attention.
#
# + daysAhead - Days ahead with a partition, `()` when there is none
# + thresholdDays - `tokenPartitionAlertDays`
# + return - True when there is no partition or fewer days than the threshold
isolated function isRunwayAlerting(int? daysAhead, int thresholdDays) returns boolean =>
    daysAhead is () || daysAhead < thresholdDays;

# The runway as a report.
#
# + daysAhead - Days ahead with a partition, `()` when there is none
# + thresholdDays - `tokenPartitionAlertDays`
# + return - The report
isolated function toTokenPartitionReport(int? daysAhead, int thresholdDays) returns TokenPartitionReport {
    TokenPartitionReport report = {alerting: isRunwayAlerting(daysAhead, thresholdDays)};
    if daysAhead is int {
        report.daysAhead = daysAhead;
    }
    return report;
}

type PartitionState record {|
    TokenPartitionReport? report;
    decimal readAt;
    decimal alertLoggedAt;
|};

isolated PartitionState partitionState = {report: (), readAt: -1000, alertLoggedAt: -1000};

# Reads the runway (reused for `outboxBacklogCacheSeconds`), exports the gauge and warns when it is short. Never fails
# the caller: an unreadable runway is logged and reported as absent.
#
# + pg - Database client
# + return - The report, or `()` when it can't be read
isolated function tokenPartitionReport(postgresql:Client pg) returns TokenPartitionReport? {
    decimal now = time:monotonicNow();
    lock {
        TokenPartitionReport? cached = partitionState.report;
        if cached is TokenPartitionReport && now - partitionState.readAt < outboxBacklogCacheSeconds {
            return cached.clone();
        }
    }
    int?|error ahead = store:tokenPartitionDaysAhead(pg);
    if ahead is error {
        log:printWarn("Token partition runway unreadable", resilience:loggable(ahead));
        return ();
    }
    TokenPartitionReport report = toTokenPartitionReport(ahead, tokenPartitionAlertDays);
    resilience:exportTokenPartitionDaysAhead(COMPONENT, ahead is int ? ahead : -1);
    boolean warn = false;
    lock {
        decimal loggedAt = partitionState.alertLoggedAt;
        if report.alerting && now - loggedAt >= outboxAlertLogIntervalSeconds {
            loggedAt = now;
            warn = true;
        }
        partitionState = {report: report.clone(), readAt: now, alertLoggedAt: loggedAt};
    }
    if warn {
        log:printWarn("Token partitions are running out: connects fail on a day with no partition",
                daysAhead = ahead, thresholdDays = tokenPartitionAlertDays);
    }
    return report;
}

# Creates the partitions for the next two weeks.
#
# `CAST(... AS int)` is load-bearing: a Ballerina `int` reaches PostgreSQL as `bigint`, and the function is
# declared `(p_days_ahead int, p_from date)`, so a bare `${...}` resolves to no function at all
# (`42883: function connection.create_token_partitions(bigint) does not exist`). The tests never caught it
# because they call the function with a literal.
#
# + pg - Jobs database client (`amplify_jobs` may execute the function)
# + return - An error when the database refused
isolated function ensureTokenPartitions(postgresql:Client pg) returns error? {
    int _ = check pg->queryRow(`SELECT connection.create_token_partitions(CAST(${TOKEN_PARTITION_DAYS_AHEAD} AS int))`);
}

# Creates the partitions once the database answers, so a worker that restarts after a long outage does not wait for the
# next daily run. Gives up after a few tries; the daily run and the `/ready` alert are still there.
isolated function ensurePartitionsAtStartup() {
    foreach int attempt in 1 ... 6 {
        postgresql:Client|error pg = db();
        if pg is postgresql:Client {
            error? created = ensureTokenPartitions(pg);
            if created is () {
                log:printInfo("Token partitions ensured at start-up", daysAhead = TOKEN_PARTITION_DAYS_AHEAD);
                return;
            }
            recordDbFailure(created);
            log:printWarn("Could not create token partitions at start-up", resilience:loggable(created),
                    attempt = attempt);
        }
        runtime:sleep(10);
    }
}
