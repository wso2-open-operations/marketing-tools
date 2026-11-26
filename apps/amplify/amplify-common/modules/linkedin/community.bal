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

// Community Management API (phase 4): the company page connection (an administrator's token with the page
// scopes) and the engagement reads the sync makes with it. Same client, breaker and error mapping as
// `adapter.bal`. Shapes come from `linkedin/resources/openapi/openapi/community-management.openapi.yaml`
// (reactions, comments, organization ACLs) and from LinkedIn's documentation where the spec has none
// (organizational entity notifications, the refresh grant). Comment and post text is never kept or logged.

import amplify_common.resilience;
import amplify_common.types;

import ballerina/http;
import ballerina/mime;
import ballerina/url;

# Scopes the page connection asks for, and only these (the Community Management app).
public final string[] & readonly PAGE_SCOPES = ["r_organization_social_feed", "rw_organization_admin"];

# Largest page LinkedIn serves on these finders.
public const int MAX_PAGE_SIZE = 100;

# Endpoints and the Community Management app's credentials. A separate app from Share on LinkedIn at LinkedIn;
# locally the mock client stands in for both.
public type CommunityConfig record {|
    # REST API base, `https://api.linkedin.com` (mock: `http://mock-linkedin:9090`)
    string apiBaseUrl = "https://api.linkedin.com";
    # OAuth base, `https://www.linkedin.com` (mock: `http://mock-linkedin:9091`)
    string authBaseUrl = "https://www.linkedin.com";
    # Browser-facing base for the authorization URL. Empty = `authBaseUrl`
    string authorizeBaseUrl = "";
    # Community Management app client id
    string clientId;
    # Its client secret (Choreo secret; never logged)
    string clientSecret;
    # Redirect URI registered on that app (the admin page callback); empty when only the sync uses the adapter
    string redirectUri = "";
    # `LinkedIn-Version` header
    string apiVersion = LINKEDIN_VERSION;
    # Per-call timeout
    decimal timeoutSeconds = 10;
    # REST API breaker and pool. Retry stays 0: the sync stops on a failure and the next run carries on
    resilience:HttpResilience apiResilience = {};
    # OAuth breaker and pool. Retry stays 0: a code is single use
    resilience:HttpResilience authResilience = {};
|};

# A reaction on a post (`GET /rest/reactions/(entity:{urn})?q=entity`).
public type Reaction record {|
    # Who reacted: a person URN, or an organization when the page reacted
    string actorUrn;
    # Post reacted on (`root`)
    string rootUrn;
    # `LIKE`, `PRAISE`, ... (kept for the log only, never stored)
    string reactionType;
    # When, epoch milliseconds (`created.time`)
    int createdAtMs;
|};

# A comment on a post (`GET /rest/socialActions/{urn}/comments`). The text is never read.
public type Comment record {|
    # Who commented (`actor`): a person, or an organization
    string actorUrn;
    # Comment URN, `urn:li:comment:({object},{id})`
    string commentUrn;
    # Post commented on (`object`)
    string objectUrn;
    # When, epoch milliseconds (`created.time`)
    int createdAtMs;
|};

# A share of one of the page's posts, from the page's notifications
# (`GET /rest/organizationalEntityNotifications?q=criteria`).
public type ShareNotification record {|
    # `SHARE` (a reshare of a page post) or `SHARE_MENTION` (a post mentioning the page)
    string action;
    # URN of the reshare (`generatedActivity`)
    string activityUrn;
    # Who reshared (`decoratedGeneratedActivity.share.owner`)
    string actorUrn;
    # Whether the reshare carried the member's own words. Only this flag is kept, never the text
    boolean hasCommentary;
    # Page post that was reshared (`sourcePost`)
    string sourcePostUrn;
    # When, epoch milliseconds (`lastModifiedAt`)
    int occurredAtMs;
|};

# One page of a finder. `fetched` counts every element LinkedIn returned, the unusable ones too, so an
# offset cursor moves by it.
public type ReactionPage record {|
    # Usable elements
    Reaction[] items;
    # Elements returned
    int fetched;
|};

# One page of comments; see `ReactionPage`.
public type CommentPage record {|
    # Usable elements
    Comment[] items;
    # Elements returned
    int fetched;
|};

# One page of share notifications; see `ReactionPage`.
public type NotificationPage record {|
    # Usable elements
    ShareNotification[] items;
    # Elements returned
    int fetched;
|};

# Port to the Community Management API. `CommunityAdapter` is the LinkedIn implementation; tests plug in fakes.
public type CommunityPort isolated object {
    # Authorization URL for the page connection (scopes `PAGE_SCOPES` only).
    #
    # + state - Single-use `oauth_state.state`
    # + return - The URL
    public isolated function authorizationUrl(string state) returns string|ProviderError;

    # Exchanges the admin's authorization code.
    #
    # + code - Code from the redirect
    # + return - Access and refresh token, or a provider error
    public isolated function exchangeCode(string code) returns TokenGrant|ProviderError;

    # Gets a new access token with the refresh token (programmatic refresh).
    #
    # + refreshToken - Refresh token
    # + return - The new grant (LinkedIn may return the same refresh token), or a provider error
    public isolated function refresh(string refreshToken) returns TokenGrant|ProviderError;

    # Revokes a token (RFC 7009).
    #
    # + token - Token to revoke
    # + return - `()` once LinkedIn confirms, or a provider error
    public isolated function revokeToken(string token) returns ProviderError?;

    # Whether the token's member is an approved administrator of the page.
    #
    # + accessToken - Bearer token
    # + orgUrn - `urn:li:organization:{id}`
    # + return - True when an approved `ADMINISTRATOR` role names the page, or a provider error
    public isolated function isAdmin(string accessToken, string orgUrn) returns boolean|ProviderError;

    # Reactions on a post, oldest first.
    #
    # + accessToken - Bearer token
    # + entityUrn - Post URN
    # + 'start - Offset
    # + count - Page size, at most `MAX_PAGE_SIZE`
    # + return - The page, or a provider error
    public isolated function listReactions(string accessToken, string entityUrn, int 'start, int count)
        returns ReactionPage|ProviderError;

    # Top-level comments on a post, oldest first.
    #
    # + accessToken - Bearer token
    # + entityUrn - Post URN
    # + 'start - Offset
    # + count - Page size, at most `MAX_PAGE_SIZE`
    # + return - The page, or a provider error
    public isolated function listComments(string accessToken, string entityUrn, int 'start, int count)
        returns CommentPage|ProviderError;

    # Shares of the page's posts and mentions of the page in a time range.
    #
    # + accessToken - Bearer token
    # + orgUrn - Page
    # + startMs - Range start, epoch milliseconds
    # + endMs - Range end, epoch milliseconds
    # + 'start - Offset
    # + count - Page size, at most `MAX_PAGE_SIZE`
    # + return - The page, or a provider error
    public isolated function listShareNotifications(string accessToken, string orgUrn, int startMs, int endMs,
            int 'start = 0, int count = 50) returns NotificationPage|ProviderError;
};

# LinkedIn implementation of `CommunityPort`: one REST client and one OAuth client, each with its own pool and
# breaker, separate from the Share on LinkedIn adapter's.
public isolated class CommunityAdapter {
    *CommunityPort;

    private final http:Client api;
    private final http:Client auth;
    private final string authorizeBaseUrl;
    private final string clientId;
    private final string clientSecret;
    private final string redirectUri;
    private final string apiVersion;

    # Creates the adapter.
    #
    # + config - Endpoints and the app's credentials
    # + return - An error if a client can't be created
    public isolated function init(CommunityConfig config) returns error? {
        self.api = check new (config.apiBaseUrl, resilience:clientConfig(config.apiResilience, config.timeoutSeconds));
        self.auth = check new (config.authBaseUrl, resilience:clientConfig(config.authResilience, config.timeoutSeconds));
        self.authorizeBaseUrl = config.authorizeBaseUrl.trim() == "" ? config.authBaseUrl : config.authorizeBaseUrl;
        self.clientId = config.clientId;
        self.clientSecret = config.clientSecret;
        self.redirectUri = config.redirectUri;
        self.apiVersion = config.apiVersion;
    }

    public isolated function authorizationUrl(string state) returns string|ProviderError {
        string|url:Error query = buildQuery({
            "response_type": "code",
            "client_id": self.clientId,
            "redirect_uri": self.redirectUri,
            "state": state,
            "scope": string:'join(" ", ...PAGE_SCOPES)
        });
        if query is url:Error {
            return providerError(BAD_RESPONSE, "Could not encode the authorization URL", (), (), false);
        }
        return string `${self.authorizeBaseUrl}/oauth/v2/authorization?${query}`;
    }

    public isolated function exchangeCode(string code) returns TokenGrant|ProviderError =>
        self.tokenCall({
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": self.redirectUri,
            "client_id": self.clientId,
            "client_secret": self.clientSecret
        }, "page token exchange");

    public isolated function refresh(string refreshToken) returns TokenGrant|ProviderError =>
        self.tokenCall({
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": self.clientId,
            "client_secret": self.clientSecret
        }, "page token refresh");

    public isolated function revokeToken(string token) returns ProviderError? {
        string|url:Error form = buildQuery({"client_id": self.clientId, "client_secret": self.clientSecret, "token": token});
        if form is url:Error {
            return providerError(BAD_RESPONSE, "Could not encode the revoke request", (), (), false);
        }
        http:Response|http:ClientError response = self.auth->post("/oauth/v2/revoke", form,
                mediaType = mime:APPLICATION_FORM_URLENCODED);
        _ = check expectStatus(response, "page token revoke");
    }

    public isolated function isAdmin(string accessToken, string orgUrn) returns boolean|ProviderError {
        json body = check self.getJson(accessToken,
                "/rest/organizationAcls?q=roleAssignee&role=ADMINISTRATOR&state=APPROVED", "organization ACLs");
        return isApprovedAdmin(body, orgUrn);
    }

    public isolated function listReactions(string accessToken, string entityUrn, int 'start, int count)
            returns ReactionPage|ProviderError {
        string urn = check encodeUrn(entityUrn);
        json body = check self.getJson(accessToken, string `/rest/reactions/(entity:${urn})?q=entity&sort=(value:CHRONOLOGICAL)&start=${'start}&count=${pageSize(count)}`,
                "reactions");
        return parseReactions(body);
    }

    public isolated function listComments(string accessToken, string entityUrn, int 'start, int count)
            returns CommentPage|ProviderError {
        string urn = check encodeUrn(entityUrn);
        json body = check self.getJson(accessToken,
                string `/rest/socialActions/${urn}/comments?start=${'start}&count=${pageSize(count)}`, "comments");
        return parseComments(body);
    }

    public isolated function listShareNotifications(string accessToken, string orgUrn, int startMs, int endMs,
            int 'start = 0, int count = 50) returns NotificationPage|ProviderError {
        string org = check encodeUrn(orgUrn);
        json body = check self.getJson(accessToken, string `/rest/organizationalEntityNotifications?q=criteria&actions=List(SHARE,SHARE_MENTION)&organizationalEntity=${org}&timeRange=(start:${startMs},end:${endMs})&start=${'start}&count=${pageSize(count)}`,
                "share notifications");
        return parseShareNotifications(body);
    }

    # Breaker states of the REST API and OAuth clients.
    #
    # + return - `{api, auth}`
    public isolated function breakers() returns map<resilience:BreakerState> =>
        {api: resilience:breakerState(self.api), auth: resilience:breakerState(self.auth)};

    private isolated function tokenCall(map<string> params, string operation) returns TokenGrant|ProviderError {
        string|url:Error form = buildQuery(params);
        if form is url:Error {
            return providerError(BAD_RESPONSE, "Could not encode the token request", (), (), false);
        }
        http:Response|http:ClientError response = self.auth->post("/oauth/v2/accessToken", form,
                mediaType = mime:APPLICATION_FORM_URLENCODED);
        http:Response ok = check expectStatus(response, operation);
        return toTokenGrant(check readTokenBody(ok));
    }

    private isolated function getJson(string accessToken, string path, string operation) returns json|ProviderError {
        http:Response|http:ClientError response = self.api->get(path, {
            [HEADER_AUTHORIZATION]: bearer(accessToken),
            [HEADER_LINKEDIN_VERSION]: self.apiVersion,
            [HEADER_RESTLI_PROTOCOL]: RESTLI_PROTOCOL_VERSION
        });
        http:Response ok = check expectStatus(response, operation);
        json|http:ClientError body = ok.getJsonPayload();
        if body is http:ClientError {
            return providerError(BAD_RESPONSE, string `LinkedIn ${operation} returned no JSON`, ok.statusCode, (), false);
        }
        return body;
    }
}

// ---- Wire shapes and parsing (pure, unit-tested) ------------------------------------------------------

type AuditStamp record {
    string actor?;
    int time?;
};

type ReactionElement record {
    string id?;
    string reactionType?;
    string root?;
    AuditStamp created?;
};

type CommentElement record {
    string id?;
    string actor?;
    string commentUrn?;
    string 'object?;
    AuditStamp created?;
};

type SharedActivity record {
    string owner?;
    string entity?;
    string text?;
};

type DecoratedActivity record {
    SharedActivity share?;
};

type NotificationElement record {
    string action?;
    string generatedActivity?;
    string sourcePost?;
    int lastModifiedAt?;
    DecoratedActivity decoratedGeneratedActivity?;
};

type AclElement record {
    string role?;
    string state?;
    string organization?;
    string organizationTarget?;
    string organizationalTarget?;
};

# Elements of a Rest.li collection response.
#
# + body - Response body
# + operation - For the error text
# + return - The elements (absent = none), or `BAD_RESPONSE` when the body isn't a collection
isolated function elementsOf(json body, string operation) returns json[]|ProviderError {
    if body !is map<json> {
        return providerError(BAD_RESPONSE, string `LinkedIn ${operation} returned an unexpected body`, http:STATUS_OK,
                (), false);
    }
    json elements = body["elements"];
    if elements is () {
        return [];
    }
    if elements is json[] {
        return elements;
    }
    return providerError(BAD_RESPONSE, string `LinkedIn ${operation} returned an unexpected body`, http:STATUS_OK, (),
            false);
}

# Reactions from a `q=entity` response. Elements without an actor, root or time are counted but left out.
#
# + body - Response body
# + return - The page, or `BAD_RESPONSE`
isolated function parseReactions(json body) returns ReactionPage|ProviderError {
    json[] elements = check elementsOf(body, "reactions");
    Reaction[] items = [];
    foreach json element in elements {
        ReactionElement|error e = element.cloneWithType();
        if e is error {
            continue;
        }
        AuditStamp? created = e.created;
        string? actor = created is AuditStamp ? created.actor : ();
        int? time = created is AuditStamp ? created.time : ();
        string? root = e.root ?: rootOfReactionId(e.id);
        if actor is string && root is string && time is int {
            items.push({actorUrn: actor, rootUrn: root, reactionType: e.reactionType ?: "LIKE", createdAtMs: time});
        }
    }
    return {items, fetched: elements.length()};
}

# The entity of a reaction id `urn:li:reaction:({actor},{entity})`, for an element that has no `root`.
#
# + id - Reaction id
# + return - The entity URN, or `()`
isolated function rootOfReactionId(string? id) returns string? {
    if id is () || !id.startsWith("urn:li:reaction:(") || !id.endsWith(")") {
        return ();
    }
    string inner = id.substring(17, id.length() - 1);
    // The actor URN has no comma; the entity follows the first one.
    int? comma = inner.indexOf(",");
    return comma is int ? inner.substring(comma + 1) : ();
}

# Comments from a `socialActions/{urn}/comments` response. The message is never read.
#
# + body - Response body
# + return - The page, or `BAD_RESPONSE`
isolated function parseComments(json body) returns CommentPage|ProviderError {
    json[] elements = check elementsOf(body, "comments");
    Comment[] items = [];
    foreach json element in elements {
        CommentElement|error e = element.cloneWithType();
        if e is error {
            continue;
        }
        AuditStamp? created = e.created;
        string? actor = e.actor ?: (created is AuditStamp ? created.actor : ());
        int? time = created is AuditStamp ? created.time : ();
        string? obj = e.'object;
        string? id = e.id;
        string? commentUrn = e.commentUrn ?: (obj is string && id is string ? string `urn:li:comment:(${obj},${id})` : ());
        if actor is string && obj is string && commentUrn is string && time is int {
            items.push({actorUrn: actor, commentUrn, objectUrn: obj, createdAtMs: time});
        }
    }
    return {items, fetched: elements.length()};
}

# Share notifications from a `q=criteria` response. The reshare's text is reduced to a yes/no.
#
# + body - Response body
# + return - The page, or `BAD_RESPONSE`
isolated function parseShareNotifications(json body) returns NotificationPage|ProviderError {
    json[] elements = check elementsOf(body, "share notifications");
    ShareNotification[] items = [];
    foreach json element in elements {
        NotificationElement|error e = element.cloneWithType();
        if e is error {
            continue;
        }
        DecoratedActivity? decorated = e.decoratedGeneratedActivity;
        SharedActivity? share = decorated is DecoratedActivity ? decorated.share : ();
        string? owner = share is SharedActivity ? share.owner : ();
        string? activity = e.generatedActivity ?: (share is SharedActivity ? share.entity : ());
        string? text = share is SharedActivity ? share.text : ();
        string? action = e.action;
        string? sourcePost = e.sourcePost;
        int? time = e.lastModifiedAt;
        if action is string && owner is string && activity is string && sourcePost is string && time is int {
            items.push({
                action,
                activityUrn: activity,
                actorUrn: owner,
                hasCommentary: text is string && text.trim().length() > 0,
                sourcePostUrn: sourcePost,
                occurredAtMs: time
            });
        }
    }
    return {items, fetched: elements.length()};
}

# Whether an organization ACL response names the page with an approved administrator role.
#
# + body - Response body
# + orgUrn - Page
# + return - True when it does, or `BAD_RESPONSE`
isolated function isApprovedAdmin(json body, string orgUrn) returns boolean|ProviderError {
    foreach json element in check elementsOf(body, "organization ACLs") {
        AclElement|error e = element.cloneWithType();
        if e is error {
            continue;
        }
        string? org = e.organization ?: e.organizationTarget ?: e.organizationalTarget;
        if e.role == "ADMINISTRATOR" && e.state == "APPROVED" && org == orgUrn {
            return true;
        }
    }
    return false;
}

# Whether an actor URN is a person (`urn:li:person:{id}`), the only actors the sync can match to an employee.
#
# + actorUrn - Actor URN
# + return - True for a member URN
public isolated function isPersonUrn(string actorUrn) returns boolean => types:parseMemberUrn(actorUrn) is types:MemberUrn;

# Rest.li 2.0 encoding of a URN inside a path or a query value: `:` and the rest are percent-encoded.
#
# + urn - URN
# + return - Encoded URN, or `BAD_RESPONSE`
isolated function encodeUrn(string urn) returns string|ProviderError {
    string|url:Error encoded = url:encode(urn, "UTF-8");
    if encoded is url:Error {
        return providerError(BAD_RESPONSE, "Could not encode a URN", (), (), false);
    }
    // `url:encode` follows application/x-www-form-urlencoded; Rest.li wants `%20`, never `+`, and keeps `(),`
    // encoded inside a value.
    return re `\+`.replaceAll(encoded, "%20");
}

isolated function pageSize(int count) returns int => count < 1 ? 1 : count > MAX_PAGE_SIZE ? MAX_PAGE_SIZE : count;
