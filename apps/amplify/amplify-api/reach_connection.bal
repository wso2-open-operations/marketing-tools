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


// An employee's Reach connection (#1781): consent, through the Community Management app, to Amplify reading the
// analytics of their own posts (scope `r_member_postAnalytics` only). It comes back to the member callback page
// (`/amplify/connect/callback`) with a state that starts `reach-` (purpose REACH), so the page completes Reach; the
// member and page flows refuse a Reach state and the other way round. Tokens are sealed as MEMBER_ANALYTICS and never
// logged or audited. Disconnect revokes the token at LinkedIn and deletes the row and its tokens.

import amplify_api.auth;
import amplify_common.linkedin;
import amplify_domain.connection;

import ballerina/http;
import ballerina/log;
import ballerina/time;

# `POST /me/connections/reach/start`: issues a Reach state and the authorization URL.
#
# + p - Employee
# + correlationId - Correlation id
# + return - 200 `{authorizationUrl, state, expiresAt}`, or problem details
isolated function startReachConnect(auth:Principal p, string? correlationId) returns http:StatusCodeResponse {
    do {
        linkedin:MemberAnalyticsPort? analytics = reachProvider();
        if analytics is () {
            log:printWarn("LinkedIn Reach connection is not configured", correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }
        connection:OAuthState state = check connection:newReachOAuthState(p.employeeId, time:utcNow());
        check (check oauthStateRepository()).issue(state);
        string url = check analytics.memberAuthorizationUrl(state.state, redirectUri());
        return <http:Ok>{body: {authorizationUrl: url, state: state.state, expiresAt: ts(state.expiresAt)}};
    } on fail error e {
        return failure(e, correlationId, "Start LinkedIn Reach connect");
    }
}

# `POST /me/connections/reach/complete`: exchanges the code, seals the tokens as MEMBER_ANALYTICS and upserts the
# Reach connection (audited). The token must carry `r_member_postAnalytics`, or it goes back to LinkedIn.
#
# + p - Employee
# + correlationId - Correlation id
# + body - Code, state and the callback page
# + return - 200 with the Reach status, or problem details
isolated function completeReachConnect(auth:Principal p, string? correlationId, ConnectCompleteBody body)
        returns http:StatusCodeResponse {
    do {
        if body.code.length() == 0 || body.code.length() > 2048 || body.state.length() < 32 || body.state.length() > 128 {
            return badRequest("code and state are required", correlationId);
        }
        if body.redirectUri != redirectUri() {
            log:printWarn("LinkedIn Reach callback on an unexpected redirect URI", correlationId = correlationId);
            return unprocessable(OAUTH_REDIRECT_MISMATCH, "This sign-in didn't come back to Amplify's page; start again",
                    correlationId);
        }
        linkedin:MemberAnalyticsPort? analytics = reachProvider();
        var sealer = cipher();
        if analytics is () || sealer is () {
            log:printWarn("LinkedIn Reach connection is not configured", correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }
        time:Utc now = time:utcNow();
        connection:OAuthState? state = check (check oauthStateRepository()).consume(body.state, p.employeeId, now);
        if state is () || state.purpose != connection:REACH {
            return conflicted(OAUTH_STATE_INVALID, "This sign-in link expired or was already used; start again",
                    correlationId);
        }
        linkedin:TokenGrant|linkedin:ProviderError grant = analytics.exchangeMemberCode(body.code, redirectUri());
        if grant is linkedin:ProviderError {
            return providerFailure(grant, correlationId);
        }
        // LinkedIn lists the granted scopes; an empty list (some grants omit it) is taken as what was asked for.
        if grant.scopes.length() > 0 && grant.scopes.indexOf(linkedin:REACH_SCOPES[0]) is () {
            linkedin:ProviderError? revoked = analytics.revokeToken(grant.accessToken);
            if revoked is linkedin:ProviderError {
                log:printWarn("Could not revoke a Reach token without the analytics scope",
                        errorCode = revoked.detail().code, correlationId = correlationId);
            }
            return unprocessable(REACH_SCOPE_MISSING, "LinkedIn didn't grant access to your post analytics",
                    correlationId);
        }
        connection:StoredToken access = check connection:sealReachToken(sealer, grant.accessToken, p.employeeId,
                "ACCESS", time:utcAddSeconds(now, <decimal>grant.expiresInSeconds), now);
        connection:StoredToken? refresh = ();
        string? rt = grant.refreshToken;
        if rt is string {
            int seconds = grant.refreshExpiresInSeconds ?: 31536000;
            refresh = check connection:sealReachToken(sealer, rt, p.employeeId, "REFRESH",
                    time:utcAddSeconds(now, <decimal>seconds), now);
        }
        connection:ReachConnectionRepository repo = check reachConnectionRepository(actorOf(p, correlationId));
        connection:ReachConnection? existing = check repo.find(p.employeeId);
        string[] scopes = grant.scopes.length() > 0 ? grant.scopes : [...linkedin:REACH_SCOPES];
        connection:ReachChange change = connection:connectReach(existing, p.employeeId, scopes, access, refresh, now);
        check repo.save(change, existing is connection:ReachConnection ? existing.version : ());
        return <http:Ok>{body: reachStatusBody(change.connection, now)};
    } on fail error e {
        return failure(e, correlationId, "Complete LinkedIn Reach connect");
    }
}

# `GET /me/connections/reach`.
#
# + p - Employee
# + correlationId - Correlation id
# + return - `{connected, status, connectedAt, accessExpiresAt}`, or problem details
isolated function reachStatusOf(auth:Principal p, string? correlationId) returns json|ProblemResponse {
    do {
        connection:ReachConnection? c = check (check reachConnectionRepository(actorOf(p, correlationId)))
            .find(p.employeeId);
        return reachStatusBody(c, time:utcNow());
    } on fail error e {
        return failure(e, correlationId, "LinkedIn Reach status");
    }
}

# `DELETE /me/connections/reach`: revokes the token at LinkedIn (while it still works), then deletes the row and its
# tokens (audited). Nothing to do when there is no connection.
#
# + p - Employee
# + correlationId - Correlation id
# + return - 204, 503 when LinkedIn couldn't confirm the revoke, or problem details
isolated function disconnectReach(auth:Principal p, string? correlationId) returns http:NoContent|ProblemResponse {
    do {
        time:Utc now = time:utcNow();
        connection:ReachConnectionRepository repo = check reachConnectionRepository(actorOf(p, correlationId));
        connection:ReachConnection? existing = check repo.find(p.employeeId);
        if existing is () {
            return http:NO_CONTENT;
        }
        if time:utcDiffSeconds(existing.accessExpiresAt, now) > 0d {
            linkedin:MemberAnalyticsPort? analytics = reachProvider();
            var sealer = cipher();
            if analytics is () || sealer is () {
                return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
            }
            connection:StoredToken? token = check (check tokenRepository()).find(existing.accessToken);
            string|error bearer = token is () ? error("gone") : connection:openToken(sealer, token);
            if bearer is string {
                linkedin:ProviderError? revoked = analytics.revokeToken(bearer);
                if revoked is linkedin:ProviderError && revoked.detail().code != linkedin:UNAUTHORIZED
                        && revoked.detail().code != linkedin:REJECTED {
                    log:printWarn("LinkedIn Reach revoke failed; connection kept", errorCode = revoked.detail().code,
                            correlationId = correlationId);
                    return unavailable(DEPENDENCY_UNAVAILABLE, correlationId,
                            "LinkedIn couldn't be reached, so Reach was not disconnected. Try again shortly.");
                }
            }
        }
        _ = check repo.delete(existing);
        return http:NO_CONTENT;
    } on fail error e {
        return failure(e, correlationId, "Disconnect LinkedIn Reach");
    }
}

isolated function reachStatusBody(connection:ReachConnection? c, time:Utc now) returns json {
    if c is () {
        return {connected: false, status: "NOT_CONNECTED", connectedAt: (), accessExpiresAt: ()};
    }
    connection:ReachStatus status = connection:reachStatus(c, now);
    return {
        connected: status == connection:REACH_CONNECTED,
        status,
        connectedAt: ts(c.connectedAt),
        accessExpiresAt: ts(c.accessExpiresAt)
    };
}
