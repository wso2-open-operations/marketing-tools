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


// RFC 9457 problem details, the one error shape of the API, and the mapping from domain errors to
// HTTP. Domain messages are safe to show (amplify_common.types:DomainError); anything else is logged and
// answered with a stable code only, never the error text, SQL or an upstream body.

import amplify_common.resilience;
import amplify_common.types;

import ballerina/http;
import ballerina/log;
import ballerina/sql;

# RFC 9457 problem details, the one error shape of the API.
public type Problem record {|
    # Problem type URI
    string 'type;
    # Short summary
    string title;
    # HTTP status
    int status;
    # Stable code, for example `ROLE_NOT_PERMITTED`
    string code;
    # Human-readable detail, never internals
    string? detail = ();
    # Correlation id
    string? correlationId = ();
|};

# Every error response a resource can return.
type ProblemResponse http:BadRequest|http:Unauthorized|http:Forbidden|http:NotFound|http:Conflict
    |http:UnprocessableEntity|http:InternalServerError|http:ServiceUnavailable;

isolated function problem(int status, string title, string code, string? detail, string? correlationId) returns Problem => {
    'type: PROBLEM_TYPE_PREFIX + code,
    title,
    status,
    code,
    detail,
    correlationId
};

isolated function unauthorized(string code, string? detail, string? correlationId) returns http:Unauthorized => {
    mediaType: PROBLEM_JSON,
    // RFC 9110 section 11.6.1: a 401 names the scheme it expects.
    headers: {"WWW-Authenticate": "Bearer realm=\"amplify\""},
    body: problem(401, "Unauthorized", code, detail, correlationId)
};

isolated function forbidden(string code, string? correlationId, string detail = "You don't have access to this action")
        returns http:Forbidden => {
    mediaType: PROBLEM_JSON,
    body: problem(403, "Forbidden", code, detail, correlationId)
};

isolated function unavailable(string code, string? correlationId,
        string detail = "A dependency is unavailable, try again shortly") returns http:ServiceUnavailable => {
    mediaType: PROBLEM_JSON,
    body: problem(503, "Service Unavailable", code, detail, correlationId)
};

isolated function conflicted(string code, string detail, string? correlationId) returns http:Conflict => {
    mediaType: PROBLEM_JSON,
    body: problem(409, "Conflict", code, detail, correlationId)
};

isolated function badRequest(string detail, string? correlationId, string code = VALIDATION_FAILED) returns http:BadRequest => {
    mediaType: PROBLEM_JSON,
    body: problem(400, "Bad Request", code, detail, correlationId)
};

isolated function notFound(string detail, string? correlationId) returns http:NotFound => {
    mediaType: PROBLEM_JSON,
    body: problem(404, "Not Found", NOT_FOUND, detail, correlationId)
};

isolated function unprocessable(string code, string detail, string? correlationId) returns http:UnprocessableEntity => {
    mediaType: PROBLEM_JSON,
    body: problem(422, "Unprocessable Content", code, detail, correlationId)
};

isolated function internalError(string? correlationId) returns http:InternalServerError => {
    mediaType: PROBLEM_JSON,
    body: problem(500, "Internal Server Error", INTERNAL_ERROR, "Something went wrong on our side", correlationId)
};

// Domain codes answered with 409 (state conflicts). The rest of the domain codes are 422 (invalid input).
final readonly & string[] CONFLICT_CODES = [types:ERR_VERSION_CONFLICT, types:ERR_CAMPAIGN_ALREADY_REGISTERED,
    types:ERR_CAMPAIGN_ARCHIVED, types:ERR_POST_HAS_ACTIVITY, types:ERR_CAMPAIGN_NOT_OPEN, types:ERR_MEMBER_ALREADY_LINKED,
    types:ERR_CONNECTION_REMOVED, types:ERR_CONNECTION_NEEDS_RECONNECT, types:ERR_SHARE_ALREADY_QUEUED,
    types:ERR_SHARE_ALREADY_PUBLISHED, types:ERR_SHARE_NOT_QUEUED, types:ERR_EVIDENCE_ALREADY_CLAIMED,
    types:ERR_NOT_PENDING, types:ERR_NOT_APPROVED, types:ERR_ALREADY_AMPLIFIED, types:ERR_ALREADY_REVERSED,
    types:ERR_CANNOT_REVERSE_REVERSAL, types:ERR_RULE_VERSION_EXISTS, types:ERR_RULE_NOT_FOUND,
    types:ERR_TOP_UP_NOT_POSITIVE, types:ERR_ALREADY_ANNOUNCED, types:ERR_ANNOUNCEMENT_NOT_FAILED,
    types:ERR_ANNOUNCEMENT_NOT_QUEUED, LINKEDIN_NOT_CONNECTED, NEEDS_RECONNECT, CAMPAIGN_CLOSED, DUPLICATE_ACTION,
    FEATURE_DISABLED, OAUTH_STATE_INVALID, EMAIL_CONFLICT];

# API code for a domain code: a few are renamed to the published names (plan M5).
#
# + code - Domain code
# + return - Published code
isolated function apiCode(string code) returns string {
    match code {
        types:ERR_CAMPAIGN_NOT_OPEN => {
            return CAMPAIGN_CLOSED;
        }
        types:ERR_CONNECTION_NEEDS_RECONNECT => {
            return NEEDS_RECONNECT;
        }
        types:ERR_SHARE_ALREADY_QUEUED|types:ERR_SHARE_ALREADY_PUBLISHED => {
            return DUPLICATE_ACTION;
        }
    }
    return code;
}

# Maps any error from a use case to problem details. Domain errors keep their (safe) message; anything
# else is logged with context and answered with a stable code only.
#
# + err - Error
# + correlationId - Correlation id
# + context - What was being done, for the log
# + return - The response
isolated function failure(error err, string? correlationId, string context) returns ProblemResponse {
    if err is types:DomainError {
        string code = apiCode(err.detail().code);
        string detail = err.message();
        if code == VALIDATION_FAILED {
            return badRequest(detail, correlationId);
        }
        if code == types:ERR_NOT_FOUND {
            return notFound(detail, correlationId);
        }
        if code == types:ERR_SELF_REVIEW {
            return forbidden(code, correlationId, detail);
        }
        if CONFLICT_CODES.indexOf(code) !is () {
            return conflicted(code, detail, correlationId);
        }
        return unprocessable(code, detail, correlationId);
    }
    if err is DependencyError {
        log:printWarn(string `${context}: ${err.message()}`, correlationId = correlationId);
        return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
    }
    log:printError(string `${context} failed`, resilience:loggable(err), correlationId = correlationId);
    // Transient database errors count against the DB breaker (M9); the breaker ignores the rest.
    recordDbFailure(err);
    if err is sql:Error || err is http:ClientError {
        return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
    }
    return internalError(correlationId);
}

# Status code of a typed response.
#
# + res - Response
# + return - HTTP status
isolated function statusOf(http:StatusCodeResponse res) returns int => res.status.code;

# What of a database error is safe to put in a log line: its kind and the SQLSTATE, never its message. PostgreSQL
# text can carry row values (`Detail: Key (email)=(...)`), so callers that log a failed write or read use these two
# fields instead of the error itself.
#
# + err - The error
# + return - `sql:DatabaseError`, `sql:Error` or `error`
isolated function errorKind(error err) returns string =>
    err is sql:DatabaseError ? "sql:DatabaseError" : err is sql:Error ? "sql:Error" : "error";

# The SQLSTATE of a database error, for the log.
#
# + err - The error
# + return - The five character SQLSTATE, or `()` when the error has none
isolated function sqlStateOf(error err) returns string? => err is sql:DatabaseError ? err.detail().sqlState : ();
