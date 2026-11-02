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
import ballerina/time;
import ballerina/url;
import ballerina/uuid;

# Returns the current time as epoch seconds.
#
# + return - Epoch seconds with fraction
isolated function nowSeconds() returns decimal {
    time:Utc now = time:utcNow();
    return <decimal>now[0] + now[1];
}

# Returns the current UTC day, used to key daily rate limits.
#
# + return - Day as `YYYY-MM-DD`
isolated function utcDay() returns string => time:utcToString(time:utcNow()).substring(0, 10);

# Builds a person URN from a member id.
#
# + sub - Member id
# + return - `urn:li:person:{sub}`
isolated function personUrn(string sub) returns string => PERSON_URN_PREFIX + sub;

# Returns a random token-like value, shaped like LinkedIn's `AQ...` strings.
#
# + return - Random value
isolated function randomOpaqueValue() returns string =>
    OPAQUE_VALUE_PREFIX + re `-`.replaceAll(uuid:createType4AsString() + uuid:createType4AsString(), "");

# Returns a random media id, shaped like LinkedIn's `C5610AQ...` ids.
#
# + return - Random media id
isolated function randomMediaId() returns string =>
    MEDIA_ID_PREFIX + re `-`.replaceAll(uuid:createType4AsString(), "").substring(0, 12).toUpperAscii();

# Creates a new share URN with a 19 digit id, like LinkedIn's.
#
# + return - `urn:li:share:{id}`
isolated function newShareUrn() returns string {
    int id = 7200000000000000000 + (time:utcNow()[0] * 1000) + (store:nextPostSequence() % 1000);
    return SHARE_URN_PREFIX + id.toString();
}

# Builds the upload URL handed out for a registered upload.
#
# + uploadId - Upload id
# + return - Upload URL on the `www` host
isolated function uploadUrl(string uploadId) returns string =>
    string `${wwwBaseUrl}/${UPLOAD_PATH}/${uploadId}/uploaded-image/0?ca=vector_ugc&cn=uploads&sync=0&v=beta`;

# Appends query parameters to a URL.
#
# + base - Base URL, which may already have a query string
# + params - Parameters to add
# + return - URL with the parameters, or an error if encoding fails
isolated function withQuery(string base, map<string> params) returns string|error {
    string[] pairs = [];
    foreach [string, string] [name, value] in params.entries() {
        pairs.push(string `${name}=${check url:encode(value, "UTF-8")}`);
    }
    string separator = base.includes("?") ? "&" : "?";
    return base + separator + string:'join("&", ...pairs);
}

# Reads the correlation id for the request.
#
# + ctx - Request context
# + return - Correlation id, or an empty string if the request has none
isolated function correlationId(http:RequestContext ctx) returns string {
    string|error id = ctx.getWithType(CTX_CORRELATION_ID);
    return id is string ? id : "";
}

# Validates the bearer token on a request.
#
# + req - Inbound request
# + return - The access token, or a 401 response
isolated function authenticate(http:Request req) returns store:AccessToken|ErrorUnauthorized {
    string|http:HeaderNotFoundError header = req.getHeader(HEADER_AUTHORIZATION);
    // The auth scheme is case-insensitive (RFC 6750).
    if header is http:HeaderNotFoundError || !header.toLowerAscii().startsWith(BEARER_PREFIX.toLowerAscii()) {
        return unauthorized(MSG_MISSING_TOKEN, SERVICE_ERROR_INVALID_TOKEN);
    }
    string value = header.substring(BEARER_PREFIX.length()).trim();
    if value == "" {
        return unauthorized(MSG_MISSING_TOKEN, SERVICE_ERROR_INVALID_TOKEN);
    }
    store:AccessToken? token = store:getAccessToken(value);
    if token is () {
        return unauthorized(MSG_INVALID_TOKEN, SERVICE_ERROR_INVALID_TOKEN);
    }
    if token.expiresAt <= nowSeconds() {
        return unauthorized(MSG_EXPIRED_TOKEN, SERVICE_ERROR_EXPIRED_TOKEN);
    }
    return token;
}

# Reads the token the request interceptor validated and checks it has the scopes.
#
# + ctx - Request context
# + scopes - Scopes the operation needs
# + operation - Operation name for the error message, for example `POST /rest/posts`
# + return - The access token, or a 401 or 403 response
isolated function authorize(http:RequestContext ctx, string[] scopes, string operation)
        returns store:AccessToken|ErrorUnauthorized|ErrorForbidden {
    store:AccessToken|error token = ctx.getWithType(CTX_ACCESS_TOKEN);
    if token is error {
        log:printError("Access token missing from request context", token, correlationId = correlationId(ctx));
        return unauthorized(MSG_INVALID_TOKEN, SERVICE_ERROR_INVALID_TOKEN);
    }
    foreach string scope in scopes {
        if token.scopes.indexOf(scope) is () {
            return forbidden(string `Not enough permissions to access: ${operation}`);
        }
    }
    return token;
}

# Checks the token is valid and has a scope. For services outside the Share API interceptor chain.
#
# + req - Inbound request
# + scope - Scope the operation needs
# + operation - Operation name for the error message
# + return - The access token, or a 401 or 403 response
isolated function authenticateWithScope(http:Request req, string scope, string operation)
        returns store:AccessToken|ErrorUnauthorized|ErrorForbidden {
    store:AccessToken|ErrorUnauthorized token = authenticate(req);
    if token is ErrorUnauthorized {
        return token;
    }
    if token.scopes.indexOf(scope) is () {
        return forbidden(string `Not enough permissions to access: ${operation}`);
    }
    return token;
}

# Checks that a URN in the request is the calling member.
#
# + urn - Author or owner URN from the request
# + token - Access token of the caller
# + return - A 403 response if the URN is someone else
isolated function checkIsMember(string urn, store:AccessToken token) returns ErrorForbidden? {
    if urn != personUrn(token.memberSub) {
        return forbidden(string `Member is not authorized to act as ${urn}`);
    }
    return ();
}

# Checks that a media URN was uploaded by the member.
#
# + mediaUrn - Image or asset URN
# + token - Access token of the caller
# + return - A 400 or 403 response if the media can't be used
isolated function checkMedia(string mediaUrn, store:AccessToken token) returns ErrorBadRequest|ErrorForbidden? {
    store:Upload? upload = store:getUploadByMediaUrn(mediaUrn);
    if upload is () || !upload.uploaded {
        return badRequest(string `Media ${mediaUrn} does not exist or is not AVAILABLE`);
    }
    if upload.ownerUrn != personUrn(token.memberSub) {
        return forbidden(string `Member does not own media ${mediaUrn}`);
    }
    return ();
}

# Checks that a URL is an absolute http(s) URL.
#
# + value - URL to check
# + return - True if valid
isolated function isHttpUrl(string value) returns boolean => re `https?://\S+`.isFullMatch(value);

# Checks that a URN identifies a post.
#
# + value - URN to check
# + return - True if it is `urn:li:share:{id}` or `urn:li:ugcPost:{id}`
isolated function isPostUrn(string value) returns boolean => re `urn:li:(share|ugcPost):[0-9]+`.isFullMatch(value);

isolated function badRequest(string message) returns ErrorBadRequest =>
    {body: {status: http:STATUS_BAD_REQUEST, message}};

isolated function unauthorized(string message, int serviceErrorCode) returns ErrorUnauthorized =>
    {body: {status: http:STATUS_UNAUTHORIZED, message, serviceErrorCode}};

isolated function forbidden(string message) returns ErrorForbidden =>
    {body: {status: http:STATUS_FORBIDDEN, message, serviceErrorCode: SERVICE_ERROR_ACCESS_DENIED}};

isolated function notFound(string message) returns ErrorNotFound =>
    {body: {status: http:STATUS_NOT_FOUND, message}};

isolated function payloadTooLarge() returns ErrorPayloadTooLarge {
    string message = string `Request body is larger than the ${maxUploadBytes} bytes this mock accepts`;
    return {body: {status: http:STATUS_PAYLOAD_TOO_LARGE, message}};
}

isolated function unprocessable(string message) returns ErrorUnprocessableEntity =>
    {body: {status: http:STATUS_UNPROCESSABLE_ENTITY, message}};

isolated function tooManyRequests(string message) returns ErrorTooManyRequests =>
    {body: {status: http:STATUS_TOO_MANY_REQUESTS, message, serviceErrorCode: SERVICE_ERROR_THROTTLED}};

isolated function oauthBadRequest(string 'error, string description) returns OAuthErrorBadRequest =>
    {body: {'error, error_description: description}};
