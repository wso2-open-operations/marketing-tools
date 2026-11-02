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


// `Idempotency-Key` on every POST (plan M5, integration-boundary item 3), stored in
// `messaging.idempotency_key` per caller for 24 hours. A replay with the same request returns the stored
// status and body; a different request under the same key is 422; a repeat while the first still runs
// is 409. 5xx outcomes aren't stored, so the caller can retry with the same key.

import amplify_api.auth;
import amplify_common.resilience;

import ballerina/crypto;
import ballerina/http;
import ballerina/log;

# The work behind an idempotent POST.
type Handler isolated function () returns http:StatusCodeResponse;

# Runs `handler` under the request's `Idempotency-Key`, if any.
#
# + ctx - Request context
# + req - Request
# + principal - Caller (keys are per caller)
# + route - Route template, part of the fingerprint
# + body - Request body (`()` when none), part of the fingerprint
# + handler - The work
# + return - The response (fresh or replayed)
isolated function idempotent(http:RequestContext ctx, http:Request req, auth:Principal principal, string route,
        json body, Handler handler) returns http:Response {
    string? correlationId = cid(ctx);
    string|http:HeaderNotFoundError header = req.getHeader(IDEMPOTENCY_HEADER);
    if header is http:HeaderNotFoundError {
        return toResponse(handler());
    }
    string key = header.trim();
    if key.length() == 0 || key.length() > 255 {
        return toResponse(badRequest("Idempotency-Key must be 1-255 characters", correlationId));
    }
    string hash = crypto:hashSha256((req.method + " " + route + " " + body.toJsonString()).toBytes()).toBase16();
    var seen = claimIdempotency(principal.employeeId, key, hash);
    if seen is error {
        log:printError("Could not claim the idempotency key", resilience:loggable(seen), correlationId = correlationId);
        // The key store is the database: a transient failure here counts against the DB breaker (ADR-028).
        recordDbFailure(seen);
        return toResponse(unavailable(DEPENDENCY_UNAVAILABLE, correlationId));
    }
    if seen !is () {
        if seen.requestHash != hash {
            return toResponse(unprocessable(IDEMPOTENCY_KEY_REUSED,
                    "This Idempotency-Key was used for a different request", correlationId));
        }
        int? status = seen.responseStatus;
        if status is () {
            return toResponse(conflicted(IDEMPOTENCY_IN_PROGRESS, "The first request with this key is still running",
                    correlationId));
        }
        http:Response replay = jsonResponse(status, seen.responseBody);
        replay.setHeader(REPLAYED_HEADER, "true");
        return replay;
    }
    http:StatusCodeResponse outcome = handler();
    int status = statusOf(outcome);
    error? stored = status >= 500 ? releaseIdempotency(principal.employeeId, key)
        : completeIdempotency(principal.employeeId, key, status, bodyOf(outcome));
    if stored is error {
        log:printError("Could not store the idempotent response", resilience:loggable(stored),
                correlationId = correlationId);
        recordDbFailure(stored);
        if status < 500 {
            // The response exists but could not be stored, so the claim would stay "in progress" until its
            // 24 h TTL and every retry would get 409. Free the key, best effort; the domain's own uniqueness
            // rules answer a retry that repeats a committed action.
            error? released = releaseIdempotency(principal.employeeId, key);
            if released is error {
                log:printWarn("Could not release the idempotency key", resilience:loggable(released),
                        correlationId = correlationId);
            }
        }
    }
    return toResponse(outcome);
}

# A typed response as an `http:Response`.
#
# + res - Typed response
# + return - The response
isolated function toResponse(http:StatusCodeResponse res) returns http:Response =>
    jsonResponse(statusOf(res), bodyOf(res));

# Responses this API builds with a body.
type BodyResponse http:Ok|http:Created|http:Accepted|http:BadRequest|http:Unauthorized|http:Forbidden|http:NotFound
    |http:Conflict|http:UnprocessableEntity|http:InternalServerError|http:ServiceUnavailable;

isolated function bodyOf(http:StatusCodeResponse res) returns json =>
    res is BodyResponse ? res?.body.toJson() : ();

# A response with `body` as JSON. The text goes through `jsonText` (json_body.bal), not the http module's
# serializer, so a large body (a campaign is ~700 bytes) doesn't hit the JDK 21 writer's 512-char growth
# (M11b); the bytes are the same.
#
# + status - HTTP status
# + body - Body, `()` for none
# + return - The response
isolated function jsonResponse(int status, json body) returns http:Response {
    http:Response res = new;
    res.statusCode = status;
    if body !is () {
        string mediaType = status >= 400 ? PROBLEM_JSON : "application/json";
        string|error text = jsonText(body);
        if text is string {
            res.setPayload(text, mediaType);
        } else {
            res.setJsonPayload(body, mediaType);
        }
    }
    return res;
}
