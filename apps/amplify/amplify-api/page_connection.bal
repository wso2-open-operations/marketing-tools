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

// The company page connection (Amplify Admin, `CAN_ADMIN`) and the native repost intent (employees). The page flow
// reuses the member flow's OAuth state table: a state issued here carries `COMMUNITY_MANAGEMENT` and the member
// flow refuses it (and the other way round). Tokens are sealed as ORG and never logged or audited.

import amplify_api.auth;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.identity;
import amplify_domain.sharing;

import ballerina/http;
import ballerina/log;
import ballerina/time;

# `POST /admin/linkedin-page/connect/start`: issues a page state and the authorization URL (page scopes only).
#
# + p - Admin
# + correlationId - Correlation id
# + return - 200 `{authorizationUrl, state, expiresAt}`, or problem details
isolated function startPageConnect(auth:Principal p, string? correlationId) returns http:StatusCodeResponse {
    do {
        linkedin:CommunityPort? community = communityProvider();
        if community is () {
            log:printWarn("LinkedIn page connection is not configured", correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }
        connection:OAuthState state = check connection:newPageOAuthState(p.employeeId, time:utcNow());
        check (check oauthStateRepository()).issue(state);
        string url = check community.authorizationUrl(state.state);
        return <http:Ok>{body: {authorizationUrl: url, state: state.state, expiresAt: ts(state.expiresAt)}};
    } on fail error e {
        return failure(e, correlationId, "Start LinkedIn page connect");
    }
}

# `POST /admin/linkedin-page/connect/complete`: exchanges the code, checks the admin is an approved administrator of
# the configured page, seals the tokens as ORG and upserts the page connection (audited).
#
# + p - Admin
# + correlationId - Correlation id
# + body - Code, state and the callback page
# + return - 200 with the page status, 403 `NOT_PAGE_ADMIN`, or problem details
isolated function completePageConnect(auth:Principal p, string? correlationId, ConnectCompleteBody body)
        returns http:StatusCodeResponse {
    do {
        if body.code.length() == 0 || body.code.length() > 2048 || body.state.length() < 32 || body.state.length() > 128 {
            return badRequest("code and state are required", correlationId);
        }
        if body.redirectUri != pageRedirectUri() {
            log:printWarn("LinkedIn page callback on an unexpected redirect URI", correlationId = correlationId);
            return unprocessable(OAUTH_REDIRECT_MISMATCH, "This sign-in didn't come back to Amplify's page; start again",
                    correlationId);
        }
        linkedin:CommunityPort? community = communityProvider();
        var sealer = cipher();
        if community is () || sealer is () {
            log:printWarn("LinkedIn page connection is not configured", correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }
        time:Utc now = time:utcNow();
        connection:OAuthState? state = check (check oauthStateRepository()).consume(body.state, p.employeeId, now);
        if state is () || state.providerApi != types:COMMUNITY_MANAGEMENT {
            return conflicted(OAUTH_STATE_INVALID, "This sign-in link expired or was already used; start again",
                    correlationId);
        }
        linkedin:TokenGrant|linkedin:ProviderError grant = community.exchangeCode(body.code);
        if grant is linkedin:ProviderError {
            return providerFailure(grant, correlationId);
        }
        boolean|linkedin:ProviderError admin = community.isAdmin(grant.accessToken, wso2OrganizationUrn);
        if admin is linkedin:ProviderError {
            return providerFailure(admin, correlationId);
        }
        if !admin {
            // The token is of no use to Amplify: give it back.
            linkedin:ProviderError? revoked = community.revokeToken(grant.accessToken);
            if revoked is linkedin:ProviderError {
                log:printWarn("Could not revoke a non-admin page token", errorCode = revoked.detail().code,
                        correlationId = correlationId);
            }
            return forbidden(NOT_PAGE_ADMIN, correlationId,
                    "Your LinkedIn account isn't an administrator of the company page");
        }
        connection:StoredToken access = check connection:sealOrgToken(sealer, grant.accessToken, wso2OrganizationUrn,
                "ACCESS", time:utcAddSeconds(now, <decimal>grant.expiresInSeconds), now);
        connection:StoredToken? refresh = ();
        string? rt = grant.refreshToken;
        if rt is string {
            int seconds = grant.refreshExpiresInSeconds ?: 31536000;
            refresh = check connection:sealOrgToken(sealer, rt, wso2OrganizationUrn, "REFRESH",
                    time:utcAddSeconds(now, <decimal>seconds), now);
        }
        connection:OrgConnectionRepository repo = check orgConnectionRepository(actorOf(p, correlationId));
        connection:OrgConnection? existing = check repo.find(types:LINKEDIN, wso2OrganizationUrn);
        connection:OrgConnectionChange change = connection:connectOrg(existing, {
            orgUrn: wso2OrganizationUrn,
            connectedBy: p.employeeId,
            scopes: grant.scopes,
            access,
            refresh
        }, now);
        check repo.save(change, existing is connection:OrgConnection ? existing.version : ());
        return <http:Ok>{body: check pageStatusBody(change.connection, now)};
    } on fail error e {
        return failure(e, correlationId, "Complete LinkedIn page connect");
    }
}

# `DELETE /admin/linkedin-page`: revokes the page token at LinkedIn, deletes both token rows and marks the
# connection revoked (audited). Nothing to do when there is no connection.
#
# + p - Admin
# + correlationId - Correlation id
# + return - 204, 503 when LinkedIn couldn't confirm the revoke, or problem details
isolated function disconnectPage(auth:Principal p, string? correlationId) returns http:NoContent|ProblemResponse {
    do {
        time:Utc now = time:utcNow();
        connection:OrgConnectionRepository repo = check orgConnectionRepository(actorOf(p, correlationId));
        connection:OrgConnection? existing = check repo.find(types:LINKEDIN, wso2OrganizationUrn);
        if existing is () || existing.revokedAt !is () {
            return http:NO_CONTENT;
        }
        connection:TokenRef? ref = existing.accessToken;
        linkedin:CommunityPort? community = communityProvider();
        var sealer = cipher();
        if ref is connection:TokenRef && time:utcDiffSeconds(existing.accessExpiresAt, now) > 0d {
            if community is () || sealer is () {
                return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
            }
            connection:StoredToken? token = check (check tokenRepository()).find(ref);
            string|error bearer = token is () ? error("gone") : connection:openToken(sealer, token);
            if bearer is string {
                linkedin:ProviderError? revoked = community.revokeToken(bearer);
                if revoked is linkedin:ProviderError && revoked.detail().code != linkedin:UNAUTHORIZED
                        && revoked.detail().code != linkedin:REJECTED {
                    log:printWarn("LinkedIn page revoke failed; connection kept", errorCode = revoked.detail().code,
                            correlationId = correlationId);
                    return unavailable(DEPENDENCY_UNAVAILABLE, correlationId,
                            "LinkedIn couldn't be reached, so the page was not disconnected. Try again shortly.");
                }
            }
        }
        check repo.save(connection:revokeOrg(existing, now), existing.version);
        return http:NO_CONTENT;
    } on fail error e {
        return failure(e, correlationId, "Disconnect LinkedIn page");
    }
}

# `GET /admin/linkedin-page`.
#
# + correlationId - Correlation id
# + return - `{connected, connectedByName, connectedAt, accessExpiresAt, callsToday, dailyBudget, lastSyncAt}`, or
# problem details
isolated function pageStatus(string? correlationId) returns json|ProblemResponse {
    do {
        connection:OrgConnection? c = check (check orgConnectionRepository({actorId: "system", roles: []}))
            .find(types:LINKEDIN, wso2OrganizationUrn);
        return check pageStatusBody(c, time:utcNow());
    } on fail error e {
        return failure(e, correlationId, "LinkedIn page status");
    }
}

isolated function pageStatusBody(connection:OrgConnection? c, time:Utc now) returns json|error {
    Settings settings = check loadSettings();
    int calls = check apiCallsToday();
    time:Utc? lastSync = check engagementLastSyncAt();
    string? lastSyncAt = lastSync is () ? () : ts(lastSync);
    if c is () {
        return {connected: false, connectedByName: (), connectedAt: (), accessExpiresAt: (), callsToday: calls,
            dailyBudget: settings.engagementDailyBudget, lastSyncAt};
    }
    map<identity:EmployeeMatch> people = check employeesIn([c.connectedBy]);
    identity:EmployeeMatch? who = people[c.connectedBy];
    boolean connected = connection:orgStatus(c, now) == connection:PAGE_CONNECTED;
    return {
        connected,
        connectedByName: who is () ? () : who.displayName,
        connectedAt: connected ? ts(c.connectedAt) : (),
        accessExpiresAt: connected ? ts(c.accessExpiresAt) : (),
        callsToday: calls,
        dailyBudget: settings.engagementDailyBudget,
        lastSyncAt
    };
}

// ---- Native repost intent ---------------------------------------------------------------------------

# `POST /campaigns/{id}/native-intent`: the caller opened an open campaign post to reshare it on LinkedIn itself.
#
# + p - Employee
# + correlationId - Correlation id
# + id - Campaign id
# + return - 200 with the intent, or problem details (404 for a campaign that isn't open)
isolated function recordNativeIntent(auth:Principal p, string? correlationId, string id) returns http:StatusCodeResponse {
    do {
        string campaignId = check uuidOf(id, "id");
        time:Utc now = time:utcNow();
        campaign:Campaign? c = check (check campaignRepository(actorOf(p, correlationId))).findById(campaignId);
        if c is () || c.archivedAt !is () || !campaign:isOpen(c, now) {
            return notFound("Campaign not found", correlationId);
        }
        sharing:NativeIntent intent = check (check nativeIntentRepository()).open(p.employeeId, campaignId, now);
        map<int> points = intent.detectedAt is () ? {} : check resharePoints(p.employeeId, [campaignId]);
        return <http:Ok>{body: nativeIntentDto(intent, now, points)};
    } on fail error e {
        return failure(e, correlationId, "Record native repost intent");
    }
}

# `GET /me/native-intents`.
#
# + p - Employee
# + correlationId - Correlation id
# + return - `{items}`, or problem details
isolated function nativeIntentsOf(auth:Principal p, string? correlationId) returns json|ProblemResponse {
    do {
        time:Utc now = time:utcNow();
        sharing:NativeIntent[] intents = check (check nativeIntentRepository()).ofEmployee(p.employeeId);
        string[] detected = from sharing:NativeIntent i in intents where i.detectedAt !is () select i.campaignId;
        map<int> points = check resharePoints(p.employeeId, detected);
        return {items: from sharing:NativeIntent i in intents select nativeIntentDto(i, now, points)};
    } on fail error e {
        return failure(e, correlationId, "My native repost intents");
    }
}

# A native repost intent with the points its reshare earned: set once the sync found the reshare and it was scored
# (net of a reversal or removal), else null.
#
# + i - Intent
# + now - Current time
# + points - Campaign id -> net reshare points (`resharePoints`)
# + return - The intent as JSON
isolated function nativeIntentDto(sharing:NativeIntent i, time:Utc now, map<int> points) returns json {
    time:Utc? detected = i.detectedAt;
    return {
        campaignId: i.campaignId,
        openedAt: ts(i.openedAt),
        detectedAt: detected is () ? () : ts(detected),
        nativeStatus: sharing:nativeStatus(i, now),
        points: detected is () ? () : points[i.campaignId]
    };
}
