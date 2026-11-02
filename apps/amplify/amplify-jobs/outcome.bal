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

// Outcome of handling one outbox row, and the retry backoff.

import ballerina/random;

# What the run does with a handled row.
enum OutcomeKind {
    # Handled (including "nothing to do"): `DONE`
    DONE,
    # Transient failure: back off and try again; `FAILED` after `maxAttempts`
    RETRY,
    # Not now (kill switch, rate ceiling, not configured, not open yet): due again later, attempt not counted
    DEFER,
    # Permanent failure: `FAILED`
    FAIL
}

# Result of a handler.
type Outcome record {|
    OutcomeKind kind;
    # Safe text for `outbox.last_error` and the log (never tokens, URLs or commentary)
    string? note = ();
    # DEFER only: wait before the row is due again, seconds
    decimal? delaySeconds = ();
|};

isolated function done(string? note = ()) returns Outcome => {kind: DONE, note};

isolated function retryLater(string note) returns Outcome => {kind: RETRY, note};

isolated function deferFor(decimal delaySeconds, string note) returns Outcome => {kind: DEFER, note, delaySeconds};

isolated function failed(string note) returns Outcome => {kind: FAIL, note};

# Exponential backoff with equal jitter: half of `min(max, base * 2^(attempt-1))` fixed, the other half
# random, so retries after a shared outage (429 storm) spread out instead of arriving together.
#
# + attempt - Attempt that just failed, starting at 1
# + baseSeconds - Backoff for attempt 1
# + maxSeconds - Cap
# + jitter - Random fraction in [0, 1); tests pass a fixed value
# + return - Seconds until the next attempt
isolated function backoffSeconds(int attempt, decimal baseSeconds, decimal maxSeconds, float? jitter = ())
        returns decimal {
    int exponent = attempt < 1 ? 0 : attempt - 1;
    decimal ceiling = baseSeconds;
    foreach int _ in 0 ..< exponent {
        ceiling *= 2;
        if ceiling >= maxSeconds {
            break;
        }
    }
    if ceiling > maxSeconds {
        ceiling = maxSeconds;
    }
    float fraction = jitter ?: random:createDecimal();
    decimal half = ceiling / 2;
    return half + half * <decimal>fraction;
}
