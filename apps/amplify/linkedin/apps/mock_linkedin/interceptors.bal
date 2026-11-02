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
import mock_linkedin.store;

import ballerina/http;
import ballerina/log;
import ballerina/uuid;

# Assigns a correlation id to every request and logs it. Used on both hosts.
service class CorrelationInterceptor {
    *http:RequestInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|error? {
        string id = uuid:createType4AsString();
        ctx.set(CTX_CORRELATION_ID, id);
        log:printInfo("Request received", correlationId = id, method = req.method, path = req.rawPath);
        return ctx.next();
    }
}

# Validates the bearer token and Rest.li headers, and applies the daily rate limits.
# Runs before every Share API resource. Every authenticated call counts toward the limits,
# and the app counter goes up even when the member limit then rejects the call.
service class RequestInterceptor {
    *http:RequestInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|ErrorBadRequest|ErrorUnauthorized|ErrorTooManyRequests|error? {
        string id = correlationId(ctx);
        store:AccessToken|ErrorUnauthorized token = authenticate(req);
        if token is ErrorUnauthorized {
            log:printDebug("Request rejected: unauthenticated", correlationId = id);
            return token;
        }

        ErrorBadRequest? headerError = validateRestliHeaders(req, path);
        if headerError is ErrorBadRequest {
            return headerError;
        }

        string day = utcDay();
        if store:incrementRequestCount(string `app:${token.clientId}:${day}`) > appDailyLimit {
            return tooManyRequests(MSG_APP_THROTTLED);
        }
        if store:incrementRequestCount(string `member:${token.memberSub}:${day}`) > memberDailyLimit {
            return tooManyRequests(MSG_MEMBER_THROTTLED);
        }

        ctx.set(CTX_ACCESS_TOKEN, token);
        return ctx.next();
    }
}

# Adds the LinkedIn response headers and logs the outcome.
service class ResponseInterceptor {
    *http:ResponseInterceptor;

    isolated remote function interceptResponse(http:RequestContext ctx, http:Response res) returns http:NextService|error? {
        string id = correlationId(ctx);
        if id != "" {
            res.setHeader(HEADER_LI_UUID, id);
        }
        res.setHeader(HEADER_RESTLI_PROTOCOL_VERSION, RESTLI_PROTOCOL_VERSION);
        log:printInfo("Response sent", correlationId = id, status = res.statusCode);
        return ctx.next();
    }
}

# Maps request binding and dispatching errors to LinkedIn-shaped error bodies.
# Anything else becomes a generic 500 so internal details never reach the caller.
service class ErrorInterceptor {
    *http:ResponseErrorInterceptor;

    isolated remote function interceptResponseError(http:RequestContext ctx, error err)
            returns ErrorBadRequest|ErrorNotFound|ErrorMethodNotAllowed|ErrorInternalServerError {
        if err is http:PayloadBindingError|http:PayloadValidationError|http:HeaderBindingError
                |http:HeaderValidationError|http:QueryParameterBindingError|http:QueryParameterValidationError
                |http:PathParameterBindingError {
            log:printDebug("Request rejected: invalid input", correlationId = correlationId(ctx), reason = err.message());
            return badRequest(MSG_INVALID_REQUEST);
        }
        if err is http:ResourceNotFoundError {
            return notFound(MSG_RESOURCE_NOT_FOUND);
        }
        if err is http:ResourceMethodNotAllowedError {
            return <ErrorMethodNotAllowed>{body: {status: http:STATUS_METHOD_NOT_ALLOWED, message: MSG_METHOD_NOT_ALLOWED}};
        }
        log:printError("Unhandled error while serving request", err, correlationId = correlationId(ctx));
        return <ErrorInternalServerError>{body: {status: http:STATUS_INTERNAL_SERVER_ERROR, message: MSG_INTERNAL_ERROR}};
    }
}

# Checks `X-Restli-Protocol-Version` on Rest.li calls and `LinkedIn-Version` on versioned `/rest` calls.
# `/v2/userinfo` is the OpenID Connect endpoint and takes neither.
#
# + req - Inbound request
# + path - Request path segments
# + return - A 400 response if a header is missing or wrong
isolated function validateRestliHeaders(http:Request req, string[] path) returns ErrorBadRequest? {
    if path == USERINFO_PATH {
        return ();
    }
    string|http:HeaderNotFoundError protocolVersion = req.getHeader(HEADER_RESTLI_PROTOCOL_VERSION);
    if protocolVersion != RESTLI_PROTOCOL_VERSION {
        return badRequest(MSG_PROTOCOL_VERSION);
    }
    if path.length() == 0 || path[0] != VERSIONED_PATH_PREFIX {
        return ();
    }
    string|http:HeaderNotFoundError version = req.getHeader(HEADER_LINKEDIN_VERSION);
    if version is http:HeaderNotFoundError {
        return badRequest(MSG_VERSION_MISSING);
    }
    if !re `[0-9]{6}`.isFullMatch(version) {
        return badRequest(string `Requested version ${version} is not a valid YYYYMM version`);
    }
    return ();
}
