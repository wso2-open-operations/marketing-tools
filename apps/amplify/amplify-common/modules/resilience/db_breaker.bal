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

// Database circuit breaker (plan M9, ADR-028). `ballerinax/postgresql` has no breaker, so this is a
// small state machine the components put in front of their pool: transient failures inside a time
// window open it, an open breaker refuses calls until the reset time passes, then one caller gets a
// trial (half-open) and its result closes or re-opens it. Only transient errors count; a unique
// violation or a missing row says nothing about the database's health.

import ballerina/lang.runtime;
import ballerina/sql;
import ballerina/time;

# Database breaker settings.
public type DbBreakerConfig record {|
    # Transient failures inside the window that open the breaker
    int failureThreshold = 5;
    # Window the failures are counted in, seconds
    decimal windowSeconds = 30;
    # Time an open breaker waits before the half-open trial, seconds
    decimal resetTimeSeconds = 15;
|};

# What the breaker says about one call: go ahead, go ahead as the half-open trial, or don't call.
public type DbAdmission "PASS"|"TRIAL"|"REJECT";

# Monotonic clock in seconds (a test seam).
public type Clock isolated function () returns decimal;

isolated function monotonic() returns decimal => time:monotonicNow();

# Circuit breaker for one database pool.
public isolated class DbBreaker {
    private final DbBreakerConfig & readonly config;
    private final Clock clock;
    private BreakerState current = "CLOSED";
    private decimal[] failures = [];
    private decimal openedAt = 0;
    private boolean trialOut = false;
    private decimal trialAt = 0;
    private int opens = 0;

    # Creates a closed breaker.
    #
    # + config - Thresholds
    # + clock - Monotonic clock, seconds (tests pass a fake)
    public isolated function init(DbBreakerConfig config = {}, Clock clock = monotonic) {
        self.config = config.cloneReadOnly();
        self.clock = clock;
    }

    # Asks to make a call. `TRIAL` means this caller is the one half-open trial and must report the result.
    #
    # + return - `PASS`, `TRIAL` or `REJECT`
    public isolated function admit() returns DbAdmission {
        decimal now = self.clock();
        lock {
            if self.current == "CLOSED" {
                return "PASS";
            }
            if self.current == "OPEN" && now - self.openedAt >= self.config.resetTimeSeconds {
                self.current = "HALF_OPEN";
                self.trialOut = false;
            }
            // A trial nobody reported back on (the caller died) expires after the reset time.
            if self.current == "HALF_OPEN" && (!self.trialOut || now - self.trialAt >= self.config.resetTimeSeconds) {
                self.trialOut = true;
                self.trialAt = now;
                return "TRIAL";
            }
            return "REJECT";
        }
    }

    # Records a successful call: a half-open breaker closes.
    public isolated function onSuccess() {
        lock {
            if self.current == "HALF_OPEN" {
                self.current = "CLOSED";
                self.failures = [];
                self.trialOut = false;
            }
        }
    }

    # Records a failed call. Only errors that say the database is unhealthy count; non-transient errors and lock
    # contention (deadlock 40P01, serialization failure 40001) are ignored. A failed half-open trial is reported with
    # `onTrialFailure`, not here: a failure arriving while half-open comes from a call admitted before the
    # breaker opened, says nothing about the trial, and must not re-open the breaker or discard a trial that
    # then succeeds.
    #
    # + err - The error
    # + return - True when the failure was counted
    public isolated function onFailure(error err) returns boolean {
        if !isBreakerFailure(err) {
            return false;
        }
        decimal now = self.clock();
        lock {
            if self.current == "HALF_OPEN" || self.current == "OPEN" {
                return true;
            }
            decimal[] recent = from decimal t in self.failures where now - t < self.config.windowSeconds select t;
            recent.push(now);
            self.failures = recent;
            if recent.length() >= self.config.failureThreshold {
                self.trip(now);
            }
            return true;
        }
    }

    # The half-open trial failed, whatever the error: the breaker opens again.
    public isolated function onTrialFailure() {
        decimal now = self.clock();
        lock {
            if self.current == "HALF_OPEN" {
                self.trip(now);
            }
        }
    }

    # Closes the breaker and forgets its failures (tests; an operator forcing it closed).
    public isolated function reset() {
        lock {
            self.current = "CLOSED";
            self.failures = [];
            self.trialOut = false;
        }
    }

    # Current state.
    #
    # + return - `CLOSED`, `HALF_OPEN` or `OPEN` (an open breaker past its reset time reads `HALF_OPEN`)
    public isolated function state() returns BreakerState {
        decimal now = self.clock();
        lock {
            if self.current == "OPEN" && now - self.openedAt >= self.config.resetTimeSeconds {
                return "HALF_OPEN";
            }
            return self.current;
        }
    }

    # How many times the breaker has opened since start.
    #
    # + return - Count
    public isolated function openCount() returns int {
        lock {
            return self.opens;
        }
    }

    private isolated function trip(decimal now) {
        lock {
            self.current = "OPEN";
            self.openedAt = now;
            self.failures = [];
            self.trialOut = false;
            self.opens += 1;
        }
    }
}

// SQLSTATE classes that mean "the database or the connection is in trouble", not "your data is wrong":
// 08 connection exception, 53 insufficient resources, 57 operator intervention (shutdown, cancel),
// 58 system error, 40001 serialization failure, 40P01 deadlock. All of these are worth a retry
// (`isTransientDbError`); the breaker skips the last two (`isBreakerFailure`), which are contention.
final readonly & string[] TRANSIENT_SQLSTATE_PREFIXES = ["08", "53", "57", "58", "40001", "40P01"];

# Whether an error is a transient database problem (connection, pool, shutdown, serialization failure,
# deadlock). Errors that wrap another error are judged by their cause. This is the retry predicate
# (`TransientDbRetry`); the breaker uses the narrower `isBreakerFailure`.
#
# + err - The error
# + return - True when worth retrying
public isolated function isTransientDbError(error err) returns boolean {
    if err is sql:NoRowsError || err is sql:DataError || err is sql:TypeMismatchError
            || err is sql:FieldMismatchError || err is sql:ConversionError {
        return false;
    }
    if err is sql:DatabaseError {
        string? state = err.detail().sqlState;
        if state is () {
            return mentionsConnection(err.message());
        }
        foreach string prefix in TRANSIENT_SQLSTATE_PREFIXES {
            if state.startsWith(prefix) {
                return true;
            }
        }
        return false;
    }
    if err is sql:Error {
        return mentionsConnection(err.message());
    }
    error? cause = err.cause();
    return cause is error && isTransientDbError(cause);
}

// Contention SQLSTATEs: transient, so worth retrying, but a busy table says nothing about database health.
final readonly & string[] CONTENTION_SQLSTATES = ["40001", "40P01"];

# Whether an error counts against the breaker: a transient database error that is not lock contention
# (a deadlock or serialization failure means the database is working and busy, not unhealthy).
#
# + err - The error
# + return - True when the failure should count toward opening the breaker
isolated function isBreakerFailure(error err) returns boolean {
    if !isTransientDbError(err) {
        return false;
    }
    if err is sql:DatabaseError {
        string? state = err.detail().sqlState;
        return state is () || CONTENTION_SQLSTATES.indexOf(state) is ();
    }
    error? cause = err.cause();
    return !(cause is error) || isBreakerFailure(cause);
}

isolated function mentionsConnection(string message) returns boolean {
    string m = message.toLowerAscii();
    return m.includes("connection") || m.includes("timed out") || m.includes("timeout")
        || m.includes("refused") || m.includes("terminating");
}

# Retry manager for `retry<resilience:TransientDbRetry> (n) { ... }`: retries only transient database
# errors, with a short growing pause. Use it for reads; writes retry through the outbox or the caller's
# `Idempotency-Key`, never blindly.
public class TransientDbRetry {
    private final int count;
    private int attempt = 0;
    private final decimal pauseSeconds;

    # Creates the manager.
    #
    # + count - Retries after the first try
    # + pauseSeconds - First pause; doubles each retry
    public isolated function init(int count = 1, decimal pauseSeconds = 0.1) {
        self.count = count;
        self.pauseSeconds = pauseSeconds;
    }

    # Whether to try again.
    #
    # + e - The error of the last try
    # + return - True for a transient error with retries left
    public function shouldRetry(error e) returns boolean {
        if self.attempt >= self.count || !isTransientDbError(e) {
            return false;
        }
        runtime:sleep(self.pauseSeconds * <decimal>(1 << self.attempt));
        self.attempt += 1;
        return true;
    }
}

# A database error made safe to log (plan M9 log hygiene): PostgreSQL appends `Detail: Key (email)=(...)`
# and `Where:` lines that can carry row values (PII), so the message is cut before them and the SQLSTATE
# kept. Any other error is returned as is (its cause chain is judged the same way).
#
# + err - The error
# + return - The error to pass to `log:printError`
public isolated function loggable(error err) returns error {
    if err is sql:DatabaseError {
        return error(redactDbMessage(err.message()), sqlState = err.detail().sqlState, errorCode = err.detail().errorCode);
    }
    if err is sql:Error {
        return error(redactDbMessage(err.message()));
    }
    error? cause = err.cause();
    if cause is error {
        // A wrapper message is often built from the cause's message, so it is cut the same way.
        return error(redactDbMessage(err.message()), loggable(cause));
    }
    return err;
}

isolated function redactDbMessage(string message) returns string {
    string cut = message;
    foreach string marker in ["Detail:", "DETAIL:", "Where:", "WHERE:", "Hint:"] {
        int? at = cut.indexOf(marker);
        if at is int {
            cut = cut.substring(0, at);
        }
    }
    return cut.trim();
}
