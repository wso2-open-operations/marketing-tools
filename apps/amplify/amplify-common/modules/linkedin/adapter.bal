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

import amplify_common.resilience;
import amplify_common.types;

import ballerina/http;
import ballerina/lang.regexp;
import ballerina/log;
import ballerina/mime;
import ballerina/url;

// LinkedIn wire shapes. Kept private to this module.

type AccessTokenResponse record {
    string access_token;
    int expires_in;
    string scope?;
    string id_token?;
};

type UserInfoResponse record {
    string sub;
    string name?;
    string email?;
};

// LinkedIn's error body. Only the numeric code is read: the text can echo request values, so it is never logged.
type ErrorBody record {
    int serviceErrorCode?;
    string message?;
};

# LinkedIn implementation of `ProviderAdapter`: OAuth 2.0 code exchange, OIDC userinfo and
# `POST /rest/posts` (Share on LinkedIn).
public isolated class LinkedInAdapter {
    *ProviderAdapter;

    private final http:Client api;
    private final http:Client auth;
    private final string authBaseUrl;
    private final string clientId;
    private final string clientSecret;
    private final string redirectUri;
    private final string apiVersion;

    # Creates the adapter.
    #
    # + config - Endpoints and client credentials
    # + return - An error if a client can't be created
    public isolated function init(LinkedInConfig config) returns error? {
        // Two clients, two pools and two breakers: an OAuth outage never blocks posting, and back.
        self.api = check new (config.apiBaseUrl, resilience:clientConfig(config.apiResilience, config.timeoutSeconds));
        self.auth = check new (config.authBaseUrl, resilience:clientConfig(config.authResilience, config.timeoutSeconds));
        self.authBaseUrl = config.authorizeBaseUrl.trim() == "" ? config.authBaseUrl : config.authorizeBaseUrl;
        self.clientId = config.clientId;
        self.clientSecret = config.clientSecret;
        self.redirectUri = config.redirectUri;
        self.apiVersion = config.apiVersion;
    }

    public isolated function authorizationUrl(string state) returns string|ProviderError =>
        self.authorizationUrlWithNonce(state, ());

    # Builds the authorization URL with an OIDC `nonce` (OpenID Connect Core 3.1.2.1). LinkedIn's docs
    # don't list `nonce` on `/oauth/v2/authorization`; send it, then pass the same value to
    # `IdTokenValidator.validate`, only once a real LinkedIn app is seen to echo it in the ID token.
    #
    # + state - Single-use `oauth_state.state`
    # + nonce - `oauth_state.nonce`, or `()` to send none
    # + return - Authorization URL
    public isolated function authorizationUrlWithNonce(string state, string? nonce) returns string|ProviderError {
        map<string> params = {
            "response_type": "code",
            "client_id": self.clientId,
            "redirect_uri": self.redirectUri,
            "state": state,
            "scope": string:'join(" ", ...REQUIRED_SCOPES)
        };
        if nonce is string && nonce.length() > 0 {
            params["nonce"] = nonce;
        }
        string|url:Error query = buildQuery(params);
        if query is url:Error {
            return providerError(BAD_RESPONSE, "Could not encode the authorization URL", (), (), false);
        }
        return string `${self.authBaseUrl}/oauth/v2/authorization?${query}`;
    }

    public isolated function exchangeCode(string code) returns TokenGrant|ProviderError {
        string|url:Error form = buildQuery({
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": self.redirectUri,
            "client_id": self.clientId,
            "client_secret": self.clientSecret
        });
        if form is url:Error {
            return providerError(BAD_RESPONSE, "Could not encode the token request", (), (), false);
        }
        http:Response|http:ClientError response = self.auth->post("/oauth/v2/accessToken", form,
                mediaType = mime:APPLICATION_FORM_URLENCODED);
        http:Response ok = check expectStatus(response, "token exchange");
        AccessTokenResponse body = check readTokenBody(ok);
        string[] scopes = [];
        foreach string scope in re `[,\s]+`.split(body.scope ?: "") {
            if scope.length() > 0 {
                scopes.push(scope);
            }
        }
        string? idToken = body.id_token;
        return {accessToken: body.access_token, expiresInSeconds: body.expires_in, scopes,
            idToken: idToken is string && idToken.trim().length() > 0 ? idToken : ()};
    }

    public isolated function userInfo(string accessToken) returns MemberProfile|ProviderError {
        http:Response|http:ClientError response = self.api->get("/v2/userinfo",
                {[HEADER_AUTHORIZATION]: bearer(accessToken)});
        http:Response ok = check expectStatus(response, "userinfo");
        UserInfoResponse body = check readUserInfoBody(ok);
        types:MemberUrn|types:DomainError memberUrn = types:memberUrnFromSub(body.sub);
        if memberUrn is types:DomainError {
            return providerError(BAD_RESPONSE, "LinkedIn userinfo returned an unusable sub", http:STATUS_OK, (), false);
        }
        return {sub: body.sub, memberUrn, name: body.name, email: body.email};
    }

    public isolated function revokeToken(string accessToken) returns ProviderError? {
        string|url:Error form = buildQuery({
            "client_id": self.clientId,
            "client_secret": self.clientSecret,
            "token": accessToken
        });
        if form is url:Error {
            return providerError(BAD_RESPONSE, "Could not encode the revoke request", (), (), false);
        }
        http:Response|http:ClientError response = self.auth->post("/oauth/v2/revoke", form,
                mediaType = mime:APPLICATION_FORM_URLENCODED);
        _ = check expectStatus(response, "token revoke");
    }

    # Breaker states of the REST API and OAuth clients.
    #
    # + return - `{api, auth}`
    public isolated function breakers() returns map<resilience:BreakerState> =>
        {api: resilience:breakerState(self.api), auth: resilience:breakerState(self.auth)};

    public isolated function publishShare(string accessToken, ShareCommand command) returns types:PostUrn|ProviderError {
        json payload = buildPostPayload(command);
        map<string> headers = {
            [HEADER_AUTHORIZATION]: bearer(accessToken),
            [HEADER_LINKEDIN_VERSION]: self.apiVersion,
            [HEADER_RESTLI_PROTOCOL]: RESTLI_PROTOCOL_VERSION
        };
        foreach [string, string] [name, value] in resilience:correlationHeaders(command.correlationId).entries() {
            headers[name] = value;
        }
        http:Response|http:ClientError response = self.api->post("/rest/posts", payload, headers);
        // Not `expectStatus`: after a timeout or 502/504 the post may be live, so a retry would post twice.
        http:Response created = check expectCreateStatus(response, command.correlationId);
        string|http:HeaderNotFoundError postId = created.getHeader(HEADER_RESTLI_ID);
        if postId is http:HeaderNotFoundError {
            return providerError(BAD_RESPONSE, "LinkedIn create post returned no x-restli-id", http:STATUS_CREATED, (), false);
        }
        types:PostUrn|types:DomainError urn = types:parsePostUrn(postId);
        if urn is types:DomainError {
            return providerError(BAD_RESPONSE, "LinkedIn create post returned an unexpected id", http:STATUS_CREATED, (), false);
        }
        return urn;
    }
}

# Builds the `POST /rest/posts` body for a share command (B4).
# `REPOST*` reshares the campaign post through `reshareContext.parent`. `SHARE*` creates a new post with
# an article link to the campaign post (D5 fallback). The Posts API doesn't scrape article links and
# requires `content.article.title`, so the article always carries one (`targetTitle`, else the default).
#
# + command - What to share
# + return - Request body
public isolated function buildPostPayload(ShareCommand command) returns json {
    map<json> body = {
        author: command.authorUrn,
        commentary: escapeLittleText(command.commentary ?: ""),
        visibility: "PUBLIC",
        distribution: {feedDistribution: "MAIN_FEED", targetEntities: [], thirdPartyDistributionChannels: []},
        lifecycleState: "PUBLISHED",
        isReshareDisabledByAuthor: false
    };
    if command.kind == types:REPOST || command.kind == types:REPOST_COMMENTARY {
        body["reshareContext"] = {parent: command.targetUrn};
    } else {
        string title = types:trimToNil(command.targetTitle) ?: DEFAULT_ARTICLE_TITLE;
        if title.length() > ARTICLE_TITLE_MAX_LENGTH {
            title = title.substring(0, ARTICLE_TITLE_MAX_LENGTH - 1).trim() + "…";
        }
        body["content"] = {article: {'source: command.targetUrl ?: postUrl(command.targetUrn), title}};
    }
    return body;
}

# Escapes text for LinkedIn's little text format, so an employee's `@`, `#` or brackets are shown as
# typed instead of being read as mentions, hashtags or templates.
#
# + text - Plain text
# + return - Escaped text
public isolated function escapeLittleText(string text) returns string =>
    re `[\\|{}@\[\]()<>#*_~]`.replaceAll(text, isolated function(regexp:Groups groups) returns string =>
        "\\" + groups[0].substring());

# Public feed URL of a post URN.
#
# + urn - Post URN
# + return - `https://www.linkedin.com/feed/update/{urn}/`
public isolated function postUrl(types:PostUrn urn) returns string => string `https://www.linkedin.com/feed/update/${urn}/`;

isolated function bearer(string token) returns string => "Bearer " + token;

isolated function buildQuery(map<string> params) returns string|url:Error {
    string[] pairs = [];
    foreach [string, string] [key, value] in params.entries() {
        pairs.push(key + "=" + check url:encode(value, "UTF-8"));
    }
    return string:'join("&", ...pairs);
}

# Passes any 2xx response through; maps anything else to a `ProviderError`.
#
# + response - Response, or the client error when there was none
# + operation - What was called, for the error text
# + correlationId - Id sent as `X-Correlation-ID`, so the warning can be joined to the share and the jobs run
# + return - The response, or the error
isolated function expectStatus(http:Response|http:ClientError response, string operation,
        string? correlationId = ()) returns http:Response|ProviderError {
    if response is http:ClientError {
        return providerError(UNAVAILABLE, string `LinkedIn ${operation} failed: no response`, (), (), true);
    }
    int status = response.statusCode;
    if status >= 200 && status < 300 {
        return response;
    }
    int? serviceErrorCode = ();
    json|http:ClientError body = response.getJsonPayload();
    if body is json {
        ErrorBody|error parsed = body.cloneWithType();
        if parsed is ErrorBody {
            serviceErrorCode = parsed.serviceErrorCode;
        }
    }
    [ProviderErrorCode, boolean] [code, retryable] = classify(status);
    log:printWarn(string `LinkedIn ${operation} refused`, httpStatus = status, serviceErrorCode = serviceErrorCode,
            retryable = retryable, correlationId = correlationId);
    return providerError(code, string `LinkedIn ${operation} failed with HTTP ${status}`, status, serviceErrorCode,
            retryable);
}

# Like `expectStatus` for `POST /rest/posts`, which isn't idempotent. A retry is only safe when nothing was
# sent (`UpstreamServiceUnavailableError` from an open breaker) or LinkedIn answered that it didn't take the
# request. A timeout, a dropped connection or a 502/504 from a gateway leaves the outcome unknown. A refused
# connection can't be told from a reset one by type, so it is also `OUTCOME_UNKNOWN`.
#
# + response - Result of the create call
# + correlationId - Correlation ID for the log line
# + return - The response when 2xx, else a provider error
isolated function expectCreateStatus(http:Response|http:ClientError response, string? correlationId = ())
        returns http:Response|ProviderError {
    if response is http:ClientError {
        if response is http:UpstreamServiceUnavailableError {
            return providerError(UNAVAILABLE, "LinkedIn create post failed: circuit open, nothing sent", (), (),
                    true);
        }
        return providerError(OUTCOME_UNKNOWN, "LinkedIn create post failed: no response, the post may be live",
                (), (), false);
    }
    if response.statusCode == http:STATUS_BAD_GATEWAY || response.statusCode == http:STATUS_GATEWAY_TIMEOUT {
        return providerError(OUTCOME_UNKNOWN, string `LinkedIn create post failed with HTTP ${response.statusCode}, the post may be live`,
                response.statusCode, (), false);
    }
    return expectStatus(response, "create post", correlationId);
}

isolated function classify(int status) returns [ProviderErrorCode, boolean] {
    if status == http:STATUS_UNAUTHORIZED {
        return [UNAUTHORIZED, false];
    }
    if status == http:STATUS_FORBIDDEN {
        return [FORBIDDEN, false];
    }
    if status == http:STATUS_TOO_MANY_REQUESTS {
        return [RATE_LIMITED, true];
    }
    if status >= 500 {
        return [UNAVAILABLE, true];
    }
    return [REJECTED, false];
}

isolated function readTokenBody(http:Response response) returns AccessTokenResponse|ProviderError {
    json|http:ClientError body = response.getJsonPayload();
    if body is json {
        AccessTokenResponse|error parsed = body.cloneWithType();
        if parsed is AccessTokenResponse && parsed.access_token.trim().length() > 0 && parsed.expires_in > 0 {
            return parsed;
        }
    }
    return providerError(BAD_RESPONSE, "LinkedIn token exchange returned an unexpected body", response.statusCode, (),
            false);
}

isolated function readUserInfoBody(http:Response response) returns UserInfoResponse|ProviderError {
    json|http:ClientError body = response.getJsonPayload();
    if body is json {
        UserInfoResponse|error parsed = body.cloneWithType();
        if parsed is UserInfoResponse {
            return parsed;
        }
    }
    return providerError(BAD_RESPONSE, "LinkedIn userinfo returned an unexpected body", response.statusCode, (), false);
}

isolated function providerError(ProviderErrorCode code, string message, int? httpStatus, int? serviceErrorCode,
        boolean retryable) returns ProviderError =>
    error ProviderError(message, code = code, httpStatus = httpStatus, serviceErrorCode = serviceErrorCode,
        retryable = retryable);
