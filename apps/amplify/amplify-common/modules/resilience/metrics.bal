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

// Breaker state as a metric (plan M9): gauge `amplify_breaker_state{component, dependency}` = 0 closed,
// 1 half-open, 2 open, published through Ballerina observability (Prometheus when metrics are enabled;
// Choreo's observability picks it up). Alert on `amplify_breaker_state == 2`.

import ballerina/observe;

# Gauge name.
public const string BREAKER_METRIC = "amplify_breaker_state";

# Gauge value for a state name; anything that isn't a breaker state (`NOT_CONFIGURED`) is -1.
#
# + state - `CLOSED`, `HALF_OPEN`, `OPEN` or another label
# + return - 0, 1, 2 or -1
public isolated function breakerStateValue(string state) returns float =>
    state == "CLOSED" ? 0.0 : state == "HALF_OPEN" ? 1.0 : state == "OPEN" ? 2.0 : -1.0;

# Sets `amplify_breaker_state` for each dependency of a component (registers the gauge on first use).
# Never fails the caller: a metrics problem is not a reason to fail a request or a run.
#
# + component - `amplify-api` or `amplify-jobs`
# + states - State by dependency
public isolated function exportBreakerStates(string component, map<string> states) {
    foreach [string, string] [dependency, state] in states.entries() {
        map<string> tags = {component, dependency};
        observe:Gauge gauge;
        observe:Counter|observe:Gauge? existing = observe:lookupMetric(BREAKER_METRIC, tags);
        if existing is observe:Gauge {
            gauge = existing;
        } else {
            gauge = new (BREAKER_METRIC, "Circuit breaker state: 0 closed, 1 half-open, 2 open, -1 not configured",
                tags);
            error? registered = gauge.register();
            if registered is error {
                // Someone registered it between the lookup and here; use theirs.
                observe:Counter|observe:Gauge? again = observe:lookupMetric(BREAKER_METRIC, tags);
                if again is observe:Gauge {
                    gauge = again;
                }
            }
        }
        gauge.setValue(breakerStateValue(state));
    }
}

# Current gauge value, or `()` when not exported yet (tests, `/ready`).
#
# + component - Component
# + dependency - Dependency
# + return - The value or `()`
public isolated function exportedBreakerValue(string component, string dependency) returns float? {
    observe:Counter|observe:Gauge? g = observe:lookupMetric(BREAKER_METRIC, {component, dependency});
    return g is observe:Gauge ? g.getValue() : ();
}

# Outbox backlog gauges: `amplify_outbox_pending`, `amplify_outbox_failed` and `amplify_outbox_oldest_pending_seconds`
# (-1 when nothing is pending). Alert on the oldest age: a row that sits pending for an hour means Novera, Chat or
# LinkedIn is unconfigured or down, and nothing else says so.

# Gauge names.
public const string OUTBOX_PENDING_METRIC = "amplify_outbox_pending";
public const string OUTBOX_FAILED_METRIC = "amplify_outbox_failed";
public const string OUTBOX_OLDEST_METRIC = "amplify_outbox_oldest_pending_seconds";

# Sets the outbox backlog gauges (registers each on first use). Never fails the caller.
#
# + component - `amplify-jobs`
# + pending - Rows waiting (including deferred ones)
# + failed - Rows that used every attempt
# + oldestPendingSeconds - Age of the oldest pending row, `()` when none is pending
public isolated function exportOutboxBacklog(string component, int pending, int failed, int? oldestPendingSeconds) {
    setGauge(OUTBOX_PENDING_METRIC, "Outbox rows waiting to be delivered", component, <float>pending);
    setGauge(OUTBOX_FAILED_METRIC, "Outbox rows that failed every attempt", component, <float>failed);
    setGauge(OUTBOX_OLDEST_METRIC, "Age in seconds of the oldest pending outbox row, -1 when none",
            component, oldestPendingSeconds is int ? <float>oldestPendingSeconds : -1.0);
}

isolated function setGauge(string name, string description, string component, float value) {
    map<string> tags = {component};
    observe:Counter|observe:Gauge? existing = observe:lookupMetric(name, tags);
    observe:Gauge gauge;
    if existing is observe:Gauge {
        gauge = existing;
    } else {
        gauge = new (name, description, tags);
        error? registered = gauge.register();
        if registered is error {
            observe:Counter|observe:Gauge? again = observe:lookupMetric(name, tags);
            if again is observe:Gauge {
                gauge = again;
            }
        }
    }
    gauge.setValue(value);
}

# Current value of an outbox gauge, or `()` when not exported yet.
#
# + name - One of the `OUTBOX_*_METRIC` names
# + component - Component
# + return - The value or `()`
public isolated function exportedOutboxValue(string name, string component) returns float? {
    observe:Counter|observe:Gauge? g = observe:lookupMetric(name, {component});
    return g is observe:Gauge ? g.getValue() : ();
}

# Token partition runway: `amplify_token_partition_days_ahead` is how many days past today (UTC) have a
# `connection.provider_token` partition. A connect fails on a day with none, and the daily maintenance run is the only
# thing that creates them, so alert when this falls below 3 (the run has been down for most of the runway).
public const string TOKEN_PARTITION_METRIC = "amplify_token_partition_days_ahead";

# Sets the runway gauge (registers it on first use). Never fails the caller.
#
# + component - `amplify-jobs`
# + daysAhead - Days ahead with a partition; -1 when it could not be read or there is no partition
public isolated function exportTokenPartitionDaysAhead(string component, int daysAhead) {
    setGauge(TOKEN_PARTITION_METRIC, "Days ahead of today that have a token partition, -1 unknown", component,
            <float>daysAhead);
}
