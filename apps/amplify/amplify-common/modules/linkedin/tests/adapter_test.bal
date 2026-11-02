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

// A stub LinkedIn on a local port, shaped like apps/amplify/linkedin/apps/mock_linkedin, so the adapter's
// wire contract (paths, headers, form body, x-restli-id) is checked without a network.

import amplify_common.types;

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;

const int STUB_PORT = 18210;
const string GOOD_TOKEN = "stub-token";

isolated json lastPostBody = ();
isolated string lastRevokedToken = "";

listener http:Listener stubListener = new (STUB_PORT);

service / on stubListener {
    resource function post oauth/v2/accessToken(http:Request req) returns http:Ok|http:BadRequest|error {
        map<string> form = check req.getFormParams();
        string? code = form["code"];
        if code == "oidc-code" {
            return <http:Ok>{body: {access_token: GOOD_TOKEN, expires_in: 5184000, scope: "openid,profile",
                id_token: "h.p.s"}};
        }
        if code == "empty-token-code" {
            return <http:Ok>{body: {access_token: " ", expires_in: 5184000}};
        }
        if code == "zero-expiry-code" {
            return <http:Ok>{body: {access_token: GOOD_TOKEN, expires_in: 0}};
        }
        if code == "junk-code" {
            return <http:Ok>{body: {unexpected: true}};
        }
        if form["grant_type"] != "authorization_code" || form["client_id"] != "cid" || form["client_secret"] != "secret"
                || form["redirect_uri"] != "https://one.wso2.com/cb" || form["code"] != "good-code" {
            return <http:BadRequest>{body: {'error: "invalid_request"}};
        }
        return <http:Ok>{body: {access_token: GOOD_TOKEN, expires_in: 5184000, scope: "openid,profile,w_member_social", token_type: "Bearer"}};
    }

    resource function post oauth/v2/revoke(http:Request req) returns http:Ok|http:BadRequest|error {
        map<string> form = check req.getFormParams();
        if form["client_id"] != "cid" || form["client_secret"] != "secret" {
            return <http:BadRequest>{body: {'error: "invalid_client"}};
        }
        if form["token"] == "refuse-me" {
            return <http:BadRequest>{body: {'error: "invalid_request"}};
        }
        lock {
            lastRevokedToken = form["token"] ?: "";
        }
        return <http:Ok>{};
    }

    resource function get v2/userinfo(@http:Header string Authorization) returns json|http:Unauthorized {
        if Authorization == "Bearer badsub" {
            return {sub: "has space"};
        }
        if Authorization == "Bearer junk" {
            return {name: "no sub"};
        }
        if Authorization != "Bearer " + GOOD_TOKEN {
            return <http:Unauthorized>{body: {status: 401, serviceErrorCode: 65601, message: "Invalid token"}};
        }
        return {sub: "782bbtaQ", name: "Avery Mock", given_name: "Avery", email: "avery.mock@example.com"};
    }

    resource function post rest/posts(@http:Header string Authorization, @http:Header string LinkedIn\-Version,
            @http:Header string X\-Restli\-Protocol\-Version, @http:Payload json body)
            returns http:Created|http:Unauthorized|http:BadRequest|http:TooManyRequests|http:InternalServerError|http:BadGateway|http:GatewayTimeout {
        if Authorization == "Bearer expired" {
            return <http:Unauthorized>{body: {status: 401, serviceErrorCode: 65601, message: "Invalid token"}};
        }
        if Authorization == "Bearer busy" {
            return <http:TooManyRequests>{};
        }
        if Authorization == "Bearer down" {
            return <http:InternalServerError>{};
        }
        if Authorization == "Bearer badgateway" {
            return <http:BadGateway>{};
        }
        if Authorization == "Bearer gatewaytimeout" {
            return <http:GatewayTimeout>{};
        }
        if Authorization == "Bearer slow" {
            runtime:sleep(3);
            return <http:Created>{headers: {"x-restli-id": "urn:li:share:7000000000000000002"}};
        }
        if Authorization == "Bearer noid" {
            return <http:Created>{};
        }
        if Authorization == "Bearer badid" {
            return <http:Created>{headers: {"x-restli-id": "urn:li:comment:1"}};
        }
        if LinkedIn\-Version != "202610" || X\-Restli\-Protocol\-Version != "2.0.0" {
            return <http:BadRequest>{body: {status: 400, message: "bad headers"}};
        }
        lock {
            lastPostBody = body.cloneReadOnly();
        }
        return <http:Created>{headers: {"x-restli-id": "urn:li:share:7000000000000000001"}};
    }
}

function adapter() returns LinkedInAdapter|error => new ({
    apiBaseUrl: string `http://localhost:${STUB_PORT}`,
    authBaseUrl: string `http://localhost:${STUB_PORT}`,
    clientId: "cid",
    clientSecret: "secret",
    redirectUri: "https://one.wso2.com/cb"
});

isolated function providerCode(any|error result) returns string {
    if result is ProviderError {
        return result.detail().code;
    }
    return "OK";
}

@test:Config
function adapterSatisfiesThePort() returns error? {
    ProviderAdapter port = check adapter();
    test:assertTrue(port is LinkedInAdapter);
}

@test:Config
function authorizationUrlCarriesClientStateAndScopes() returns error? {
    string authUrl = check (check adapter()).authorizationUrl("st-1");
    test:assertTrue(authUrl.startsWith(string `http://localhost:${STUB_PORT}/oauth/v2/authorization?`));
    test:assertTrue(authUrl.includes("response_type=code"));
    test:assertTrue(authUrl.includes("client_id=cid"));
    test:assertTrue(authUrl.includes("state=st-1"));
    test:assertTrue(authUrl.includes("redirect_uri=https%3A%2F%2Fone.wso2.com%2Fcb"));
    test:assertTrue(authUrl.includes("scope=openid%20profile%20w_member_social"));
}

@test:Config
function exchangeCodeReturnsTokenAndScopes() returns error? {
    TokenGrant grant = check (check adapter()).exchangeCode("good-code");
    test:assertEquals(grant, {accessToken: GOOD_TOKEN, expiresInSeconds: 5184000,
        scopes: ["openid", "profile", "w_member_social"], idToken: ()});
}

@test:Config
function exchangeCodeBadCodeIsRejected() returns error? {
    TokenGrant|ProviderError result = (check adapter()).exchangeCode("bad-code");
    test:assertEquals(providerCode(result), REJECTED);
    if result is ProviderError {
        test:assertFalse(result.message().includes("secret"), "never echo credentials");
    }
}

@test:Config
function userInfoBuildsMemberUrn() returns error? {
    MemberProfile profile = check (check adapter()).userInfo(GOOD_TOKEN);
    test:assertEquals(profile, {sub: "782bbtaQ", memberUrn: "urn:li:person:782bbtaQ", name: "Avery Mock",
        email: "avery.mock@example.com"});
}

@test:Config
function userInfoUnauthorizedMapsToUnauthorized() returns error? {
    MemberProfile|ProviderError result = (check adapter()).userInfo("nope");
    test:assertEquals(providerCode(result), UNAUTHORIZED);
    if result is ProviderError {
        test:assertEquals(result.detail().serviceErrorCode, 65601);
        test:assertFalse(result.detail().retryable);
    }
}

@test:Config
function publishRepostSendsHeadersAndReadsRestliId() returns error? {
    types:PostUrn urn = check (check adapter()).publishShare(GOOD_TOKEN, {
        authorUrn: "urn:li:person:782bbtaQ",
        kind: types:REPOST_COMMENTARY,
        targetUrn: "urn:li:share:6999",
        commentary: "Proud of the #WSO2 team @ work"
    });
    test:assertEquals(urn, "urn:li:share:7000000000000000001");
    json sent;
    lock {
        sent = lastPostBody.clone();
    }
    test:assertEquals(sent, {
        author: "urn:li:person:782bbtaQ",
        commentary: "Proud of the \\#WSO2 team \\@ work",
        visibility: "PUBLIC",
        distribution: {feedDistribution: "MAIN_FEED", targetEntities: [], thirdPartyDistributionChannels: []},
        lifecycleState: "PUBLISHED",
        isReshareDisabledByAuthor: false,
        reshareContext: {parent: "urn:li:share:6999"}
    });
}

function publishFailures() returns map<[string, string, boolean]> => {
    "expired": ["expired", UNAUTHORIZED, false],
    "rateLimited": ["busy", RATE_LIMITED, true],
    "serverError": ["down", UNAVAILABLE, true],
    // The gateway may have forwarded the create, so the post may be live: never retry
    "badGateway": ["badgateway", OUTCOME_UNKNOWN, false],
    "gatewayTimeout": ["gatewaytimeout", OUTCOME_UNKNOWN, false]
};

@test:Config {dataProvider: publishFailures}
function publishFailuresAreClassified(string token, string code, boolean retryable) returns error? {
    types:PostUrn|ProviderError result = (check adapter()).publishShare(token, {
        authorUrn: "urn:li:person:782bbtaQ", kind: types:REPOST, targetUrn: "urn:li:share:6999"});
    test:assertEquals(providerCode(result), code);
    if result is ProviderError {
        test:assertEquals(result.detail().retryable, retryable);
        test:assertFalse(result.message().includes(token), "never echo the token");
    }
}

// The per-call timeout on `POST /rest/posts`: LinkedIn may have created the post, so a retry would post twice.
@test:Config
function publishTimeoutIsOutcomeUnknownAndNotRetryable() returns error? {
    LinkedInAdapter slowApi = check new ({apiBaseUrl: string `http://localhost:${STUB_PORT}`,
        authBaseUrl: string `http://localhost:${STUB_PORT}`, clientId: "cid", clientSecret: "secret",
        redirectUri: "https://one.wso2.com/cb", timeoutSeconds: 1});
    types:PostUrn|ProviderError result = slowApi.publishShare("slow", {
        authorUrn: "urn:li:person:782bbtaQ", kind: types:REPOST, targetUrn: "urn:li:share:6999"});
    test:assertEquals(providerCode(result), OUTCOME_UNKNOWN);
    if result is ProviderError {
        test:assertFalse(result.detail().retryable);
        test:assertEquals(result.detail().httpStatus, ());
    }
}

// Reads keep treating a timeout as retryable: repeating a GET is harmless.
@test:Config
function userInfoTimeoutStaysRetryable() returns error? {
    LinkedInAdapter slowAuth = check new ({apiBaseUrl: "http://10.255.255.1:9", authBaseUrl: "http://10.255.255.1:9",
        clientId: "c", clientSecret: "s", redirectUri: "https://x.com/cb", timeoutSeconds: 1});
    ProviderError|MemberProfile result = slowAuth.userInfo(GOOD_TOKEN);
    test:assertTrue(result is ProviderError && result.detail().retryable);
}

@test:Config
function unreachableProviderIsUnavailable() returns error? {
    LinkedInAdapter down = check new ({apiBaseUrl: "http://localhost:9", authBaseUrl: "http://localhost:9",
        clientId: "c", clientSecret: "s", redirectUri: "https://x.com/cb", timeoutSeconds: 2});
    test:assertEquals(providerCode(down.userInfo(GOOD_TOKEN)), UNAVAILABLE);
}

@test:Config
function sharePayloadLinksToCampaignPost() {
    json body = buildPostPayload({authorUrn: "urn:li:person:a", kind: types:SHARE, targetUrn: "urn:li:share:1"});
    test:assertEquals(body, {
        author: "urn:li:person:a",
        commentary: "",
        visibility: "PUBLIC",
        distribution: {feedDistribution: "MAIN_FEED", targetEntities: [], thirdPartyDistributionChannels: []},
        lifecycleState: "PUBLISHED",
        isReshareDisabledByAuthor: false,
        content: {article: {'source: "https://www.linkedin.com/feed/update/urn:li:share:1/", title: DEFAULT_ARTICLE_TITLE}}
    });
}

@test:Config
function littleTextEscaping() {
    test:assertEquals(escapeLittleText("a|b{c}@d[e](f)<g>#h*i_j~k\\l"),
            "a\\|b\\{c\\}\\@d\\[e\\]\\(f\\)\\<g\\>\\#h\\*i\\_j\\~k\\\\l");
    test:assertEquals(escapeLittleText("plain text"), "plain text");
}

@test:Config
function exchangeCodeKeepsTheIdToken() returns error? {
    TokenGrant grant = check (check adapter()).exchangeCode("oidc-code");
    test:assertEquals(grant.idToken, "h.p.s");
    test:assertEquals(grant.scopes, ["openid", "profile"]);
}

// Regression (deep review RC-06): a blank access token or a non-positive lifetime was accepted and
// would have been encrypted and stored as a working connection.
function unusableTokenBodies() returns string[][] => [["empty-token-code"], ["zero-expiry-code"], ["junk-code"]];

@test:Config {dataProvider: unusableTokenBodies}
function exchangeCodeRejectsUnusableTokenBodies(string code) returns error? {
    TokenGrant|ProviderError result = (check adapter()).exchangeCode(code);
    test:assertEquals(providerCode(result), BAD_RESPONSE);
    if result is ProviderError {
        test:assertFalse(result.detail().retryable);
    }
}

@test:Config
function userInfoUnusableSubOrBodyIsBadResponse() returns error? {
    LinkedInAdapter a = check adapter();
    test:assertEquals(providerCode(a.userInfo("badsub")), BAD_RESPONSE);
    test:assertEquals(providerCode(a.userInfo("junk")), BAD_RESPONSE);
}

@test:Config
function publishWithoutOrWithForeignRestliIdIsBadResponse() returns error? {
    LinkedInAdapter a = check adapter();
    ShareCommand command = {authorUrn: "urn:li:person:782bbtaQ", kind: types:REPOST, targetUrn: "urn:li:share:6999"};
    test:assertEquals(providerCode(a.publishShare("noid", command)), BAD_RESPONSE);
    test:assertEquals(providerCode(a.publishShare("badid", command)), BAD_RESPONSE);
}

@test:Config
function authorizationUrlUsesBrowserBaseAndOptionalNonce() returns error? {
    LinkedInAdapter a = check new ({apiBaseUrl: "http://localhost:1", authBaseUrl: "http://mock-linkedin:19091",
        authorizeBaseUrl: "http://localhost:19091", clientId: "cid", clientSecret: "s", redirectUri: "https://x.com/cb"});
    string plain = check a.authorizationUrl("st-1");
    test:assertTrue(plain.startsWith("http://localhost:19091/oauth/v2/authorization?"));
    test:assertFalse(plain.includes("nonce="));
    string withNonce = check a.authorizationUrlWithNonce("st-1", "n 1&x");
    test:assertTrue(withNonce.includes("nonce=n%201%26x"), "nonce is URL-encoded");
    test:assertFalse((check a.authorizationUrlWithNonce("st-1", "")).includes("nonce="));
    test:assertEquals(a.breakers(), {api: "CLOSED", auth: "CLOSED"});
}

// Regression (deep review RC-03): the Posts API requires `content.article.title` and doesn't scrape the
// link, so a SHARE without a title would be refused (422 -> PROVIDER_REJECTED).
@test:Config
function shareArticleAlwaysCarriesATitle() returns error? {
    json body = buildPostPayload({authorUrn: "urn:li:person:a", kind: types:SHARE_COMMENTARY,
        targetUrn: "urn:li:share:1", targetUrl: "https://wso2.com/blog/x", targetTitle: "  WSO2 is a Leader  ",
        commentary: "Nice"});
    test:assertEquals(check body.content, {article: {'source: "https://wso2.com/blog/x", title: "WSO2 is a Leader"}});
    string long = "";
    foreach int i in 0 ..< 450 {
        long += "t";
    }
    json longBody = buildPostPayload({authorUrn: "urn:li:person:a", kind: types:SHARE, targetUrn: "urn:li:share:1",
        targetTitle: long});
    string title = <string>check longBody.content.article.title;
    test:assertEquals(title.length(), ARTICLE_TITLE_MAX_LENGTH);
    json blank = buildPostPayload({authorUrn: "urn:li:person:a", kind: types:SHARE, targetUrn: "urn:li:share:1",
        targetTitle: " "});
    test:assertEquals(check blank.content.article.title, DEFAULT_ARTICLE_TITLE);
}

@test:Config
function repostCarriesNoArticle() {
    json body = buildPostPayload({authorUrn: "urn:li:person:a", kind: types:REPOST, targetUrn: "urn:li:ugcPost:1",
        targetTitle: "ignored"});
    test:assertTrue(body is map<json> && !body.hasKey("content"));
}

@test:Config
function revokeSendsTheClientCredentialsAndTheToken() returns error? {
    test:assertEquals((check adapter()).revokeToken("tok-to-revoke"), ());
    lock {
        test:assertEquals(lastRevokedToken, "tok-to-revoke");
    }
}

@test:Config
function revokeRefusedByLinkedInIsAProviderError() returns error? {
    test:assertEquals(providerCode((check adapter()).revokeToken("refuse-me")), REJECTED);
}
