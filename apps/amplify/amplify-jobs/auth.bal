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

// Authentication for the worker's own endpoints (security review, "back-office components").
//
// amplify-jobs is on Project visibility only, but anything else in the project (or a compromised pod) could
// reach it, and `POST /runs`, `/maintenance/partitions` and `/maintenance/rebuild-recognition` are the strongest
// operations Amplify has. Every call except the two probes must carry a key (ADR-039, amended 2026-11-01):
//
// - `internalApiKey` opens every route. amplify-api uses it for its own triggers ("Save & Share Now").
// - `schedulerApiKey` opens only `POST /runs` and `POST /maintenance/partitions`. It is the key the scheduler
//   holds (a static header on each registered job, and so also in the scheduler's own database), so a leak
//   of it cannot reach the rebuild or the leaver sweep.

import amplify_common.crypto;

import ballerina/http;
import ballerina/log;

# Header the scheduler and amplify-api send; the same name amplify-api puts on the jobs it registers.
const string INTERNAL_KEY_HEADER = "X-Amplify-Internal-Key";

# Secret for calls into amplify-jobs with full access (a Choreo secret; locally `AMPLIFY_INTERNAL_API_KEY`).
# Required: the worker does not start without it, so a missing secret can never leave the endpoints open.
configurable string internalApiKey = ?;

# Secret the scheduler's jobs carry (a Choreo secret; locally `AMPLIFY_SCHEDULER_API_KEY`). Opens only
# `POST /runs` and `POST /maintenance/partitions`. Required, and must differ from `internalApiKey`.
configurable string schedulerApiKey = ?;

# What a presented key is allowed to do.
public enum KeyDecision {
    # Internal key: everything.
    FULL,
    # Scheduler key on one of its two routes.
    SCHEDULER_ROUTE,
    # Scheduler key on any other route.
    FORBIDDEN,
    # No key, or a key that is neither.
    DENIED
}

# Refuses every request that does not carry an allowed key, except the liveness and readiness probes.
public isolated service class InternalKeyInterceptor {
    *http:RequestInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|http:Unauthorized|http:Forbidden|error? {
        if req.method == http:GET && path.length() == 1 && (path[0] == "health" || path[0] == "ready") {
            return ctx.next();
        }
        string|http:HeaderNotFoundError presented = req.getHeader(INTERNAL_KEY_HEADER);
        KeyDecision decision = presented is string
                ? decideAccess(presented, internalApiKey, schedulerApiKey, req.method, path) : DENIED;
        if decision == FULL || decision == SCHEDULER_ROUTE {
            return ctx.next();
        }
        // The route and whether a key was sent, never the key itself.
        string route = req.method + " /" + string:'join("/", ...path);
        log:printWarn("Internal call refused", route = route, keySent = presented is string,
                reason = decision == FORBIDDEN ? "scheduler key on a route it may not call" : "unauthorized");
        if decision == FORBIDDEN {
            return <http:Forbidden>{body: {message: "Forbidden"}};
        }
        return <http:Unauthorized>{body: {message: "Unauthorized"}};
    }
}

# Decides what a presented key may do. Both keys are always compared (no early exit), so the time taken does not
# say which key, if either, was close.
#
# + presented - Key from the request header
# + internal - `internalApiKey`
# + scheduler - `schedulerApiKey`
# + method - HTTP method
# + path - Request path segments
# + return - The decision
isolated function decideAccess(string presented, string internal, string scheduler, string method, string[] path)
        returns KeyDecision {
    boolean isInternal = keyMatches(presented, internal);
    boolean isScheduler = keyMatches(presented, scheduler);
    if isInternal {
        return FULL;
    }
    if isScheduler {
        return schedulerMayCall(method, path) ? SCHEDULER_ROUTE : FORBIDDEN;
    }
    return DENIED;
}

# The only two calls the scheduler key opens.
#
# + method - HTTP method
# + path - Request path segments
# + return - True for `POST /runs` and `POST /maintenance/partitions`
isolated function schedulerMayCall(string method, string[] path) returns boolean {
    if method != http:POST {
        return false;
    }
    return (path.length() == 1 && path[0] == "runs")
        || (path.length() == 2 && path[0] == "maintenance" && path[1] == "partitions");
}

# Whether a presented key is the configured one. Both sides are trimmed: amplify-api and the scheduler send the
# trimmed value, and a secret mounted from a file often ends in a newline, which would otherwise be accepted at
# start-up and then refuse every call.
#
# + presented - Key from the request header
# + configured - `internalApiKey` or `schedulerApiKey`
# + return - True when equal, compared in constant time
isolated function keyMatches(string presented, string configured) returns boolean =>
    crypto:constantTimeEquals(presented.trim(), configured.trim());

# Stops start-up when a key is blank or too short to be a secret, or when the two keys are the same value
# (a scheduler key equal to the internal key would give the scheduler full access).
#
# + internal - `internalApiKey`
# + scheduler - `schedulerApiKey`
# + return - An error naming the problem, or `()`
isolated function checkKeys(string internal, string scheduler) returns error? {
    if internal.trim().length() < MIN_INTERNAL_KEY_LENGTH {
        return error(string `internalApiKey must be set to a secret of at least ${MIN_INTERNAL_KEY_LENGTH} characters`);
    }
    if scheduler.trim().length() < MIN_INTERNAL_KEY_LENGTH {
        return error(string `schedulerApiKey must be set to a secret of at least ${MIN_INTERNAL_KEY_LENGTH} characters`);
    }
    if internal.trim() == scheduler.trim() {
        return error("schedulerApiKey must differ from internalApiKey");
    }
}

# Shortest secret accepted (a 24-byte random value as hex is 48).
const int MIN_INTERNAL_KEY_LENGTH = 32;
