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
import amplify_api.auth;

import amplify_common.resilience;
import amplify_common.types;

import ballerina/http;
import ballerina/http.httpscerr;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;

# Runs before every resource: verifies the gateway's backend JWT (signature against the JWKS, then
# `iss`/`aud`/`exp`), then enforces the activity matrix (role × method × route). Probes skip it.
# Denials return problem details and are written to `audit.audit_log`; logs carry the code and route
# only, never the token or the caller's email.
isolated service class AuthInterceptor {
    *http:RequestInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|http:Unauthorized|http:Forbidden|http:ServiceUnavailable|http:Conflict|error? {
        string correlationId = assignCorrelationId(ctx, req);
        if req.method == http:GET && auth:isPublic(path) {
            return ctx.next();
        }
        string|http:HeaderNotFoundError header = req.getHeader(jwtHeader);
        auth:Principal|auth:AuthError principal = verifier.verify(header is string ? header.toString() : ());
        if principal is auth:AuthError {
            string code = principal.detail().code;
            if code == auth:KEYS_UNAVAILABLE {
                log:printError("Token keys unavailable", errorCode = code, correlationId = correlationId);
                return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
            }
            deny(ANONYMOUS, [], routeOf(req.method, path, ()), code, correlationId, routeMatched = false);
            return unauthorized(code, principal.message(), correlationId);
        }

        auth:Rule? rule = auth:findRule(req.method, path);
        if rule is () {
            deny(principal.employeeId, principal.roles, routeOf(req.method, path, ()), ROUTE_NOT_PERMITTED,
                    correlationId, routeMatched = false);
            return forbidden(ROUTE_NOT_PERMITTED, correlationId);
        }
        if !auth:isAllowed(rule, principal.grants) {
            deny(principal.employeeId, principal.roles, routeOf(req.method, path, rule), ROLE_NOT_PERMITTED,
                    correlationId);
            return forbidden(ROLE_NOT_PERMITTED, correlationId);
        }
        // A re-created Asgardeo account acts as the employee the person already is (V020), so history keeps one key.
        types:EmployeeId|types:DomainError|error employeeId = canonicalEmployeeId(principal);
        if employeeId is types:DomainError {
            deny(principal.employeeId, principal.roles, routeOf(req.method, path, rule), EMAIL_CONFLICT, correlationId);
            // Generic on purpose: which email belongs to which record is nothing a caller may probe for.
            return conflicted(EMAIL_CONFLICT, "This sign-in can't be matched to an Amplify profile, contact the Amplify admins",
                    correlationId);
        }
        if employeeId is error {
            log:printError("Could not resolve the employee", resilience:loggable(employeeId), correlationId = correlationId);
            recordDbFailure(employeeId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }
        auth:Principal acting = {employeeId, email: principal.email, displayName: principal.displayName,
            roles: principal.roles, grants: principal.grants, issuer: principal.issuer};
        ctx.set(PRINCIPAL_KEY, acting.cloneReadOnly());
        return ctx.next();
    }
}

# Seconds within which a repeat of the same denial is counted instead of written. A scanner on the
# project network otherwise turns every 401 into a synchronous audit INSERT; `0` disables the throttle.
configurable decimal denialAuditWindowSeconds = 60;

# A denial key's throttle state: when it was last written, and how many repeats were counted since.
type DenialBucket record {|
    # Monotonic seconds of the last write
    decimal writtenAt;
    # Repeats counted since that write
    int suppressed = 0;
|};

isolated map<DenialBucket> denialBuckets = {};

isolated function denialKey(string actorId, string[] roles, string route, string code) returns string =>
    actorId + "\t" + string:'join(",", ...roles) + "\t" + route + "\t" + code;

# Decides whether a denial is written now, and how many identical ones the row stands for. A repeat of
# the same denial inside the window is counted and reported on the next row, so the trail stays honest
# without a write per request.
#
# + actorId - Employee id, or `anonymous`
# + roles - Caller's roles
# + route - `METHOD /template`
# + code - Stable denial code
# + now - Monotonic seconds (injectable for tests)
# + windowSeconds - Throttle window
# + return - The suppressed count to record (`0` for the first), or `()` when this denial is only counted
isolated function shouldWriteDenialAt(string actorId, string[] roles, string route, string code, decimal now,
        decimal windowSeconds) returns int? {
    string key = denialKey(actorId, roles, route, code);
    lock {
        DenialBucket? bucket = denialBuckets[key];
        if bucket is DenialBucket && now - bucket.writtenAt < windowSeconds {
            bucket.suppressed += 1;
            return ();
        }
        if bucket is () && denialBuckets.length() >= DENIAL_THROTTLE_MAX {
            decimal horizon = now - windowSeconds;
            foreach [string, DenialBucket] [k, b] in denialBuckets.entries() {
                if b.writtenAt < horizon {
                    _ = denialBuckets.remove(k);
                }
            }
            if denialBuckets.length() >= DENIAL_THROTTLE_MAX {
                // Still full of live keys: the map never grows past the cap. This denial is written, just not tracked.
                return 0;
            }
        }
        int suppressed = bucket is DenialBucket ? bucket.suppressed : 0;
        denialBuckets[key] = {writtenAt: now};
        return suppressed;
    }
}

isolated function shouldWriteDenial(string actorId, string[] roles, string route, string code) returns int? =>
    shouldWriteDenialAt(actorId, roles, route, code, time:monotonicNow(), denialAuditWindowSeconds);

# The throttle key route for a path no rule matched: the method and a fixed marker.
isolated function unmatchedRoute(string route) returns string {
    int? space = route.indexOf(" ");
    return (space is int ? route.substring(0, space) : route) + " (unmatched)";
}

# Clears the throttle (tests).
isolated function resetDenialAudit() {
    lock {
        denialBuckets = {};
    }
}

# Logs a denial and writes its audit row. A failed audit write is logged; the call is still denied. When
# the same denial repeats inside the throttle window, the log still records it and the audit row carries
# the number of repeats it stands for on the next write.
#
# + actorId - Employee id, or `anonymous`
# + roles - Caller's roles
# + route - `METHOD /template`
# + code - Stable denial code
# + correlationId - Correlation id
# + routeMatched - False when no route rule matched the path. The throttle then keys on the method alone, so a
#                  scanner trying random paths shares one bucket instead of adding a key and a write per path
isolated function deny(string actorId, string[] roles, string route, string code, string? correlationId,
        boolean routeMatched = true) {
    log:printWarn("Access denied", errorCode = code, route = route, correlationId = correlationId);
    int? suppressed = shouldWriteDenial(actorId, roles, routeMatched ? route : unmatchedRoute(route), code);
    if suppressed is () {
        return;
    }
    json after = suppressed > 0 ? {"suppressed": suppressed} : ();
    error? written = recordDenial({
        actorId,
        actorRoles: roles,
        action: ACCESS_DENIED,
        entityType: ROUTE_ENTITY,
        entityId: route,
        outcome: "DENIED",
        reason: code,
        after,
        correlationId
    });
    if written is error {
        log:printError("Could not write the denial audit row", resilience:loggable(written), errorCode = code,
                route = route);
    }
}

# Route label for logs and audit: the matrix template when known, else the raw path (truncated).
#
# + method - HTTP method
# + path - Path segments
# + rule - Matched row, if any
# + return - For example `GET /po/dashboard`
isolated function routeOf(string method, string[] path, auth:Rule? rule) returns string {
    string raw = rule is auth:Rule ? rule.path : "/" + string:'join("/", ...path);
    string route = method.toUpperAscii() + " " + raw;
    return route.length() > 200 ? route.substring(0, 200) : route;
}

# The verified caller set by the interceptor.
#
# + ctx - Request context
# + return - The principal, or an error if the interceptor didn't run
isolated function principalOf(http:RequestContext ctx) returns auth:Principal|error =>
    ctx.getWithType(PRINCIPAL_KEY);

# Correlation id from the caller, if it's safe to echo and store.
#
# + req - Request
# + return - The id, or `()`
isolated function correlationIdOf(http:Request req) returns string? {
    string|http:HeaderNotFoundError id = req.getHeader(CORRELATION_HEADER);
    return id is string && re `[A-Za-z0-9._\-]{1,64}`.isFullMatch(id) ? id : ();
}

# Takes the caller's correlation id (or makes one) and keeps it on the request context, so logs, audit,
# outbox rows and the jobs trigger all carry it and the response echoes it.
#
# + ctx - Request context
# + req - Request
# + return - The id
isolated function assignCorrelationId(http:RequestContext ctx, http:Request req) returns string {
    string id = correlationIdOf(req) ?: uuid:createType4AsString();
    ctx.set(CORRELATION_KEY, id);
    return id;
}

# The request's correlation id (set by `AuthInterceptor`).
#
# + ctx - Request context
# + return - The id, or `()` outside a request
isolated function cid(http:RequestContext ctx) returns string? {
    string|error id = ctx.getWithType(CORRELATION_KEY);
    return id is string ? id : ();
}

# Adds the API security headers (plan M5) and echoes `X-Correlation-ID` on every response, errors and
# probes included.
isolated service class SecurityHeadersInterceptor {
    *http:ResponseInterceptor;

    isolated remote function interceptResponse(http:RequestContext ctx, http:Response res) returns http:NextService|error? {
        res.setHeader("X-Content-Type-Options", "nosniff");
        res.setHeader("Content-Security-Policy", "upgrade-insecure-requests");
        res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
        // Responses carry personal data (emails, points): nothing caches them unless the resource says so
        // (`/leaderboard` and `/po/dashboard` set `private, max-age`).
        if !res.hasHeader("Cache-Control") {
            res.setHeader("Cache-Control", "no-store");
        }
        string? id = cid(ctx);
        if id is string {
            res.setHeader(CORRELATION_HEADER, id);
        }
        return ctx.next();
    }
}

# Turns errors the resources didn't map (an `error` return, a failed payload or query binding, an
# unmatched route) into problem details. The error text goes to the log only.
isolated service class ResponseErrorMapper {
    *http:ResponseErrorInterceptor;

    isolated remote function interceptResponseError(http:RequestContext ctx, error err) returns http:Response {
        return errorResponse(ctx, err);
    }
}

# Same mapping for errors raised on the request path (data binding happens before the resource).
isolated service class RequestErrorMapper {
    *http:RequestErrorInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, error err) returns http:Response {
        return errorResponse(ctx, err);
    }
}

isolated function errorResponse(http:RequestContext ctx, error err) returns http:Response {
    string? id = cid(ctx);
    int status = 500;
    string code = INTERNAL_ERROR;
    string detail = "Something went wrong on our side";
    string title = "Internal Server Error";
    if err is httpscerr:PayloadTooLargeError {
        // Any 413 raised as an error (`httpscerr:PayloadTooLargeError`) is the same stable code, not a 500. The listener's
        // own over-limit refusal of a chunked body never reaches here (it answers before the interceptors run).
        return payloadTooLarge(id);
    }
    if err is http:PayloadBindingError || err is http:QueryParameterBindingError || err is http:HeaderBindingError
            || err is http:PathParameterBindingError || err is http:PayloadValidationError
            || err is http:QueryParameterValidationError || err is http:HeaderValidationError {
        status = 400;
        code = VALIDATION_FAILED;
        title = "Bad Request";
        detail = "The request is malformed or has invalid fields";
        log:printDebug("Request rejected by binding", 'error = err, correlationId = id);
    } else if err is http:ResourceDispatchingError {
        var sc = err.detail()["statusCode"];
        status = sc is int ? sc : 404;
        code = status == 404 ? NOT_FOUND : status == 405 ? METHOD_NOT_ALLOWED : VALIDATION_FAILED;
        title = status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : "Bad Request";
        detail = status == 404 ? "No such resource" : "The request can't be routed";
    } else {
        log:printError("Unhandled error", resilience:loggable(err), correlationId = id);
    }
    http:Response res = new;
    res.statusCode = status;
    res.setJsonPayload(problem(status, title, code, detail, id).toJson(), PROBLEM_JSON);
    return res;
}
