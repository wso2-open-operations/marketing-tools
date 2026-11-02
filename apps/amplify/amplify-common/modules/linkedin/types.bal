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

// Anti-corruption layer for LinkedIn (S2 Connection, C1 Sharing). Lives in amplify_common (ADR-020)
// because amplify-api does the OAuth exchange and userinfo, and amplify-jobs posts.
// Nothing outside this module sees LinkedIn's wire shapes.

import amplify_common.resilience;
import amplify_common.types;

# LinkedIn API version sent on every versioned `/rest` call.
public const string LINKEDIN_VERSION = "202610";
# Rest.li protocol version header value.
public const string RESTLI_PROTOCOL_VERSION = "2.0.0";
# Scopes Amplify asks for (Sign In with LinkedIn using OpenID Connect + Share on LinkedIn).
public final string[] & readonly REQUIRED_SCOPES = ["openid", "profile", "w_member_social"];
# Scope that lets Amplify post for the member.
public const string SCOPE_W_MEMBER_SOCIAL = "w_member_social";
# Article title used when a `SHARE` command has none (Posts API article `title` is required).
public const string DEFAULT_ARTICLE_TITLE = "WSO2 on LinkedIn";
# Longest article title sent; the Posts API wants fewer than 400 characters.
public const int ARTICLE_TITLE_MAX_LENGTH = 399;

const string HEADER_LINKEDIN_VERSION = "LinkedIn-Version";
const string HEADER_RESTLI_PROTOCOL = "X-Restli-Protocol-Version";
const string HEADER_RESTLI_ID = "x-restli-id";
const string HEADER_AUTHORIZATION = "Authorization";

# Endpoints and client credentials. Base URLs are configurable so the adapter runs against
# `apps/amplify/linkedin/apps/mock_linkedin` locally (API port 9090, www port 9091).
public type LinkedInConfig record {|
    # REST API base, `https://api.linkedin.com` (mock: `http://localhost:9090`)
    string apiBaseUrl = "https://api.linkedin.com";
    # OAuth base, `https://www.linkedin.com` (mock: `http://localhost:9091`)
    string authBaseUrl = "https://www.linkedin.com";
    # Browser-facing base for the authorization URL. Empty = `authBaseUrl`. Only differs locally, where the
    # server reaches the mock as `http://mock-linkedin:19091` and the browser as `http://localhost:19091`
    string authorizeBaseUrl = "";
    # OAuth client id
    string clientId;
    # OAuth client secret (Choreo secret; never logged)
    string clientSecret;
    # Redirect URI registered on the LinkedIn app
    string redirectUri;
    # `LinkedIn-Version` header
    string apiVersion = LINKEDIN_VERSION;
    # Per-call timeout
    decimal timeoutSeconds = 10;
    # REST API (`/rest/posts`, `/v2/userinfo`): breaker, retry and its own pool (M9). Retry stays 0: a
    # repeated `POST /rest/posts` would post twice (ADR-025)
    resilience:HttpResilience apiResilience = {};
    # OAuth (`/oauth/v2/accessToken`): breaker and its own pool. Retry stays 0: an auth code is single use
    resilience:HttpResilience authResilience = {};
|};

# Result of the OAuth code exchange. The access token is plaintext here only; amplify encrypts it before
# it touches the database and never logs it.
public type TokenGrant record {|
    # Opaque bearer token
    string accessToken;
    # Seconds until it expires (about 60 days)
    int expiresInSeconds;
    # Granted scopes
    string[] scopes;
    # OIDC ID token (compact JWT) when LinkedIn returns one (scope `openid`). Check it with
    # `IdTokenValidator.validate` before trusting any claim in it; never log it
    string? idToken = ();
|};

# The signed-in member, from OIDC userinfo.
public type MemberProfile record {|
    # OIDC `sub`
    string sub;
    # `urn:li:person:{sub}` (B13)
    types:MemberUrn memberUrn;
    # Display name, when LinkedIn returns one
    string? name;
    # Email, only with the `email` scope
    string? email;
|};

# A share to publish as the member.
public type ShareCommand record {|
    # Author, the member URN
    types:MemberUrn authorUrn;
    # Share kind (B4): reposts reshare `targetUrn`, shares link to `targetUrl`
    types:ShareKind kind;
    # Campaign post being shared
    types:PostUrn targetUrn;
    # Public URL of the campaign post (needed by `SHARE` / `SHARE_COMMENTARY`)
    string? targetUrl = ();
    # Article title for `SHARE` / `SHARE_COMMENTARY`, for example the campaign title. LinkedIn requires a
    # title on article content and doesn't scrape the link; `DEFAULT_ARTICLE_TITLE` when blank
    string? targetTitle = ();
    # Employee's own words, plain text. Escaped to LinkedIn little text format here.
    string? commentary = ();
    # Correlation id, sent as `X-Correlation-ID` (never part of the post)
    string? correlationId = ();
|};

# Unauthorized: token expired or revoked. Maps to `NEEDS_RECONNECT`.
public const UNAUTHORIZED = "UNAUTHORIZED";
# Forbidden: missing scope or not allowed.
public const FORBIDDEN = "FORBIDDEN";
# Rate limited (429).
public const RATE_LIMITED = "RATE_LIMITED";
# Request refused (400, 404, 409, 422).
public const REJECTED = "REJECTED";
# Nothing was sent, or LinkedIn refused to take it: connection refused, open breaker, 5xx other than 502/504.
# A later retry is safe.
public const UNAVAILABLE = "UNAVAILABLE";
# A create call was sent but its result is unknown: timeout, dropped connection, 502/504. The post may be
# live, so never `retryable`; the caller must not publish again without checking the member's posts.
public const OUTCOME_UNKNOWN = "OUTCOME_UNKNOWN";
# Response was not what the contract says.
public const BAD_RESPONSE = "BAD_RESPONSE";

# Category of a provider failure.
public type ProviderErrorCode UNAUTHORIZED|FORBIDDEN|RATE_LIMITED|REJECTED|UNAVAILABLE|OUTCOME_UNKNOWN|
        BAD_RESPONSE;

# Detail of a provider error. Never holds tokens or request bodies.
public type ProviderErrorDetail record {|
    # Category
    ProviderErrorCode code;
    # HTTP status, when there was a response
    int? httpStatus;
    # LinkedIn `serviceErrorCode`, when present
    int? serviceErrorCode;
    # Whether repeating the same call is safe and may succeed. Always `false` for `OUTCOME_UNKNOWN`
    boolean retryable;
|};

# A call to the provider failed.
public type ProviderError distinct error<ProviderErrorDetail>;

# Port to a social provider. `LinkedInAdapter` is the phase 1 implementation; tests and later
# providers plug in behind the same type.
public type ProviderAdapter isolated object {
    # Builds the authorization URL the browser is sent to.
    #
    # + state - Single-use `oauth_state.state`
    # + return - Authorization URL
    public isolated function authorizationUrl(string state) returns string|ProviderError;

    # Builds the authorization URL with an OIDC `nonce` (OpenID Connect Core 3.1.2.1) next to `state`.
    #
    # + state - Single-use `oauth_state.state`
    # + nonce - `oauth_state.nonce`, or `()` to send none
    # + return - Authorization URL
    public isolated function authorizationUrlWithNonce(string state, string? nonce) returns string|ProviderError;

    # Exchanges an authorization code for an access token.
    #
    # + code - Code from the redirect
    # + return - Token grant, or a provider error
    public isolated function exchangeCode(string code) returns TokenGrant|ProviderError;

    # Reads the member behind a token (OIDC userinfo).
    #
    # + accessToken - Bearer token
    # + return - Member profile, or a provider error
    public isolated function userInfo(string accessToken) returns MemberProfile|ProviderError;

    # Revokes an access token at LinkedIn (RFC 7009), so a removed connection can't be used any more.
    #
    # + accessToken - Token to revoke
    # + return - `()` once LinkedIn confirms, or a provider error
    public isolated function revokeToken(string accessToken) returns ProviderError?;

    # Publishes a share as the member.
    #
    # + accessToken - Bearer token
    # + command - What to share
    # + return - URN of the new post (`x-restli-id`), or a provider error. `OUTCOME_UNKNOWN` (not retryable)
    # means the post may be live
    public isolated function publishShare(string accessToken, ShareCommand command) returns types:PostUrn|ProviderError;
};
