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

// DB breaker state machine (plan M11): closed -> open -> half-open trial -> closed or open again,
// transient-only counting, the read retry manager and the breaker-state gauge.

import ballerina/sql;
import ballerina/test;

isolated decimal fakeNow = 0;

isolated function fakeClock() returns decimal {
    lock {
        return fakeNow;
    }
}

isolated function advance(decimal seconds) {
    lock {
        fakeNow += seconds;
    }
}

final sql:DatabaseError connectionLost = error sql:DatabaseError("Connection refused", errorCode = 0,
    sqlState = "08001");
final sql:DatabaseError duplicateKey = error sql:DatabaseError("duplicate key", errorCode = 0, sqlState = "23505");

function openBreaker() returns DbBreaker {
    DbBreaker b = new ({failureThreshold: 3, windowSeconds: 10, resetTimeSeconds: 5}, fakeClock);
    foreach int i in 0 ..< 3 {
        test:assertEquals(b.admit(), "PASS");
        _ = b.onFailure(connectionLost);
    }
    return b;
}

@test:Config
function dbBreakerOpensAfterThresholdAndRejects() {
    DbBreaker b = openBreaker();
    test:assertEquals(b.state(), "OPEN");
    test:assertEquals(b.admit(), "REJECT");
    test:assertEquals(b.openCount(), 1);
}

@test:Config
function dbBreakerHalfOpenTrialSuccessCloses() {
    DbBreaker b = openBreaker();
    advance(5);
    test:assertEquals(b.state(), "HALF_OPEN");
    test:assertEquals(b.admit(), "TRIAL");
    test:assertEquals(b.admit(), "REJECT", "only one trial while half-open");
    b.onSuccess();
    test:assertEquals(b.state(), "CLOSED");
    test:assertEquals(b.admit(), "PASS");
}

@test:Config
function dbBreakerHalfOpenTrialFailureReopens() {
    DbBreaker b = openBreaker();
    advance(5);
    test:assertEquals(b.admit(), "TRIAL");
    b.onTrialFailure();
    test:assertEquals(b.state(), "OPEN");
    test:assertEquals(b.admit(), "REJECT");
    test:assertEquals(b.openCount(), 2);
    advance(5);
    test:assertEquals(b.admit(), "TRIAL", "a new reset period gives a new trial");
}

@test:Config
function dbBreakerIgnoresNonTransientAndOldFailures() {
    DbBreaker b = new ({failureThreshold: 2, windowSeconds: 10, resetTimeSeconds: 5}, fakeClock);
    test:assertFalse(b.onFailure(duplicateKey));
    test:assertFalse(b.onFailure(error sql:NoRowsError("none")));
    _ = b.onFailure(connectionLost);
    advance(11);
    _ = b.onFailure(connectionLost);
    test:assertEquals(b.state(), "CLOSED", "failures outside the window don't add up");
    _ = b.onFailure(connectionLost);
    test:assertEquals(b.state(), "OPEN");
}

@test:Config
function transientClassification() {
    test:assertTrue(isTransientDbError(connectionLost));
    test:assertTrue(isTransientDbError(error sql:DatabaseError("x", errorCode = 0, sqlState = "57P01")));
    test:assertTrue(isTransientDbError(error sql:DatabaseError("x", errorCode = 0, sqlState = "40P01")));
    test:assertFalse(isTransientDbError(duplicateKey));
    test:assertFalse(isTransientDbError(error sql:DatabaseError("x", errorCode = 0, sqlState = "23514")));
    test:assertTrue(isTransientDbError(error sql:ApplicationError("Connection is not available, request timed out")));
    test:assertTrue(isTransientDbError(error("Database is unreachable", connectionLost)), "judged by the cause");
    test:assertFalse(isTransientDbError(error("Database is not configured")));
}

isolated int readCalls = 0;

isolated function flakyRead(int failures, sql:Error err) returns int|error {
    lock {
        readCalls += 1;
        if readCalls <= failures {
            return err;
        }
        return readCalls;
    }
}

function resetReads() {
    lock {
        readCalls = 0;
    }
}

function retriedRead(int failures, sql:Error err) returns int|error {
    retry<TransientDbRetry> (2, 0.001) {
        return check flakyRead(failures, err);
    }
}

@test:Config
function retryOnlyOnTransient() {
    resetReads();
    test:assertEquals(retriedRead(2, connectionLost), 3, "two transient failures, then success");
    resetReads();
    test:assertTrue(retriedRead(1, duplicateKey) is error, "non-transient errors are not retried");
    lock {
        test:assertEquals(readCalls, 1);
    }
    resetReads();
    test:assertTrue(retriedRead(5, connectionLost) is error, "gives up after the retries");
    lock {
        test:assertEquals(readCalls, 3);
    }
}

@test:Config
function breakerStateGauge() {
    test:assertEquals(breakerStateValue("OPEN"), 2.0);
    test:assertEquals(breakerStateValue("NOT_CONFIGURED"), -1.0);
    exportBreakerStates("test-component", {database: "OPEN", chat: "CLOSED"});
    exportBreakerStates("test-component", {database: "HALF_OPEN"});
    float? db = exportedBreakerValue("test-component", "database");
    // Tests run without a metrics reporter, so the registry is a no-op (0.0); with a reporter (Choreo,
    // Prometheus) the gauge holds the latest value. Either way export never fails the caller.
    test:assertTrue(db is () || db == 1.0 || db == 0.0);
}

@test:Config
function dbBreakerLateFailureFromAnEarlierCallDoesNotSpoilTheTrial() {
    // A is admitted while closed, the breaker opens, B becomes the half-open trial, then A's slow failure
    // arrives before B reports. A must not re-open the breaker; B's success then closes it.
    DbBreaker b = new ({failureThreshold: 2, windowSeconds: 10, resetTimeSeconds: 5}, fakeClock);
    test:assertEquals(b.admit(), "PASS");
    test:assertEquals(b.admit(), "PASS");
    _ = b.onFailure(connectionLost);
    _ = b.onFailure(connectionLost);
    test:assertEquals(b.state(), "OPEN");
    advance(5);
    test:assertEquals(b.admit(), "TRIAL");
    test:assertTrue(b.onFailure(connectionLost), "the late failure is still a transient failure");
    test:assertEquals(b.state(), "HALF_OPEN", "a late failure does not settle the trial");
    test:assertEquals(b.openCount(), 1);
    b.onSuccess();
    test:assertEquals(b.state(), "CLOSED");
}

@test:Config
function dbBreakerTrialFailureOfAnyKindReopensAndLostTrialExpires() {
    DbBreaker b = openBreaker();
    advance(5);
    test:assertEquals(b.admit(), "TRIAL");
    b.onTrialFailure();
    test:assertEquals(b.state(), "OPEN");
    advance(5);
    test:assertEquals(b.admit(), "TRIAL");
    test:assertEquals(b.admit(), "REJECT");
    advance(5);
    test:assertEquals(b.admit(), "TRIAL", "an unreported trial expires after the reset time");
}

@test:Config
function loggableDropsRowValues() {
    sql:DatabaseError dup = error sql:DatabaseError(
        "ERROR: duplicate key value violates unique constraint \"employee_email_uk\"\n  Detail: Key (email)=(ada@wso2.com) already exists.",
        errorCode = 0, sqlState = "23505");
    error safe = loggable(dup);
    test:assertFalse(safe.message().includes("ada@wso2.com"));
    test:assertTrue(safe.message().includes("employee_email_uk"));
    error wrapped = loggable(error("Save failed", dup));
    error? cause = wrapped.cause();
    test:assertTrue(cause is error && !cause.message().includes("ada@wso2.com"));
    test:assertEquals(loggable(error("plain")).message(), "plain");
}

// Regression (deep review RC-08): a wrapper built as `"Save failed: " + err.message()` kept the row
// values in its own message, which `loggable` passed through untouched.
@test:Config
function loggableRedactsWrapperMessages() {
    sql:DatabaseError dup = error sql:DatabaseError("duplicate key\n  Detail: Key (email)=(ada@wso2.com) exists.",
        errorCode = 0, sqlState = "23505");
    error wrapped = loggable(error("Save failed: " + dup.message(), dup));
    test:assertFalse(wrapped.message().includes("ada@wso2.com"));
    test:assertTrue(wrapped.message().startsWith("Save failed: duplicate key"));
    error app = loggable(error sql:ApplicationError("Bad value. Hint: use (x)=(secret)"));
    test:assertFalse(app.message().includes("secret"));
}

@test:Config
function dbBreakerStateReadsHalfOpenAfterResetAndResetCloses() {
    DbBreaker b = openBreaker();
    test:assertEquals(b.openCount() >= 1, true);
    test:assertEquals(b.admit(), "REJECT");
    advance(5);
    test:assertEquals(b.state(), "HALF_OPEN", "an open breaker past its reset time reads half-open");
    test:assertEquals(b.admit(), "TRIAL");
    test:assertEquals(b.admit(), "REJECT", "only one trial at a time");
    b.onTrialFailure();
    test:assertEquals(b.state(), "OPEN", "a failed trial re-opens the breaker");
    test:assertTrue(b.onFailure(connectionLost), "a failure while open still counts");
    test:assertTrue(b.onFailure(connectionLost), "failures while open are counted but change nothing");
    b.reset();
    test:assertEquals(b.state(), "CLOSED");
    test:assertEquals(b.admit(), "PASS");
    b.onTrialFailure();
    test:assertEquals(b.state(), "CLOSED", "a stray trial report on a closed breaker changes nothing");
    b.onSuccess();
    test:assertEquals(b.state(), "CLOSED");
}

@test:Config
function transientClassificationEdges() {
    test:assertTrue(isTransientDbError(error sql:DatabaseError("x", errorCode = 0, sqlState = "40P01")), "deadlock");
    test:assertTrue(isTransientDbError(error sql:DatabaseError("x", errorCode = 0, sqlState = "57014")), "cancel");
    test:assertFalse(isTransientDbError(error sql:DatabaseError("x", errorCode = 0, sqlState = "23514")), "check");
    test:assertTrue(isTransientDbError(error sql:DatabaseError("Connection reset", errorCode = 0, sqlState = ())));
    test:assertFalse(isTransientDbError(error sql:DatabaseError("syntax", errorCode = 0, sqlState = ())));
    test:assertTrue(isTransientDbError(error sql:ApplicationError("pool timed out")));
    test:assertFalse(isTransientDbError(error sql:NoRowsError("no rows")));
    test:assertTrue(isTransientDbError(error("wrapper", connectionLost)), "judged by the cause");
    test:assertFalse(isTransientDbError(error("plain")));
}

@test:Config
function contentionDoesNotCountAgainstTheBreaker() {
    sql:DatabaseError deadlock = error sql:DatabaseError("x", errorCode = 0, sqlState = "40P01");
    sql:DatabaseError serialization = error sql:DatabaseError("x", errorCode = 0, sqlState = "40001");
    // Still worth a retry...
    test:assertTrue(isTransientDbError(deadlock));
    test:assertTrue(isTransientDbError(serialization));
    // ...but not evidence of an unhealthy database.
    DbBreaker b = new ({failureThreshold: 2}, fakeClock);
    test:assertFalse(b.onFailure(deadlock));
    test:assertFalse(b.onFailure(serialization));
    test:assertFalse(b.onFailure(error("wrapper", deadlock)), "judged by the cause");
    test:assertFalse(b.onFailure(deadlock));
    test:assertEquals(b.state(), "CLOSED");
    test:assertEquals(b.openCount(), 0);
    // A real connection failure still counts.
    test:assertTrue(b.onFailure(connectionLost));
}
