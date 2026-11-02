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


// Write use cases behind the resources (S1, S2, C1, S3, C2, S5): validate input, call the use case in
// amplify_domain with a repository built for the caller, map to a DTO. Each returns a typed response and
// never an error, so the idempotency wrapper can store it.

import amplify_api.auth;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.identity;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/http;
import ballerina/log;
import ballerina/time;

# The WSO2 company page; campaigns must point at its resources.
configurable string wso2OrganizationUrn = "urn:li:organization:1477";
# Origins a campaign's post link may use, comma separated (`scheme://host[:port]`). LinkedIn only in prod;
# dev and demo environments add the mock's www origin.
configurable string campaignLinkOrigins = "https://www.linkedin.com,https://linkedin.com";

final string[] & readonly postLinkOrigins = linkOrigins(campaignLinkOrigins);

# Parses `campaignLinkOrigins`. Empty (an unset descriptor value arrives as "") means LinkedIn only, never
# "nothing allowed".
#
# + raw - Comma-separated origins
# + return - Lowercase origins
isolated function linkOrigins(string raw) returns string[] & readonly {
    string[] parsed = from string o in re `,`.split(raw)
        let string t = o.trim().toLowerAscii()
        where t != ""
        select t;
    return parsed.length() > 0 ? parsed.cloneReadOnly() : campaign:DEFAULT_POST_LINK_ORIGINS;
}

isolated function actorOf(auth:Principal p, string? correlationId) returns store:Actor =>
    {actorId: p.employeeId, roles: p.roles, correlationId};

isolated function can(auth:Principal p, auth:Access grant) returns boolean => p.grants.indexOf(grant) !is ();

// ---- S1 Campaign ------------------------------------------------------------------------------------

isolated function registerCampaign(auth:Principal p, string? correlationId, CampaignDraftBody body, boolean shareNow)
        returns http:StatusCodeResponse {
    do {
        check maxLen(body.resourceUrl, 2048, "resourceUrl");
        check maxLen(body.summary, 2000, "summary");
        check maxLen(body.imageUrl, 2048, "imageUrl");
        if body.tags.length() > 20 {
            return badRequest("At most 20 tags", correlationId);
        }
        check ensureCategory(body.categoryCode);
        Settings settings = check loadSettings();
        time:Utc now = time:utcNow();
        campaign:Campaign c = check campaign:registerCampaign(check campaignRepository(actorOf(p, correlationId)), {
            resourceUrn: body.resourceUrn,
            ownerUrn: body.ownerUrn,
            resourceUrl: body.resourceUrl,
            title: body.title,
            summary: body.summary,
            imageUrl: body.imageUrl,
            categoryCode: body.categoryCode,
            isPriority: body.isPriority,
            tags: body.tags,
            opensAt: check parseTime(body.opensAt, "opensAt"),
            closesAt: check parseTime(body.closesAt, "closesAt")
        }, {wso2OrganizationUrn, defaultWindowDays: settings.defaultWindowDays, postLinkOrigins}, p.employeeId,
                shareNow, now);
        string run = shareNow ? triggerJobs("/runs", correlationId) : "NOT_REQUESTED";
        return <http:Created>{body: {campaign: campaignDto(c, now), run}};
    } on fail error e {
        return failure(e, correlationId, "Register campaign");
    }
}

isolated function ensureCategory(string code) returns error? {
    campaign:Category[] categories = check categoryList();
    foreach campaign:Category c in categories {
        if c.code == code.trim() {
            return;
        }
    }
    return types:domainError(types:ERR_INVALID_CAMPAIGN, "Unknown category");
}

isolated function editCampaign(auth:Principal p, string? correlationId, string id, CampaignPatchBody body)
        returns CampaignDto|ProblemResponse {
    do {
        string campaignId = check uuidOf(id, "id");
        check maxLen(body.resourceUrn, 255, "resourceUrn");
        check maxLen(body.resourceUrl, 2048, "resourceUrl");
        check maxLen(body.summary, 2000, "summary");
        check maxLen(body.imageUrl, 2048, "imageUrl");
        string[]? tags = body.tags;
        if tags is string[] && tags.length() > 20 {
            return badRequest("At most 20 tags", correlationId);
        }
        string? category = body.categoryCode;
        if category is string {
            check ensureCategory(category);
        }
        campaign:CampaignRepository repo = check campaignRepository(actorOf(p, correlationId));
        campaign:Campaign? current = check repo.findById(campaignId);
        if current is () {
            return notFound("Campaign not found", correlationId);
        }
        if current.version != body.version {
            return conflicted(types:ERR_VERSION_CONFLICT, "The campaign was changed by someone else; reload and retry",
                    correlationId);
        }
        time:Utc now = time:utcNow();
        // Apply to the row just checked and update only if it is still at the caller's version: the domain's
        // `updateCampaign` re-reads and would lock on whatever version it finds, so an edit committed between
        // this check and the update was silently overwritten.
        campaign:Campaign changed = check campaign:applyPatch(current, {
            resourceUrn: body.resourceUrn,
            resourceUrl: body.resourceUrl,
            title: body.title,
            summary: body.summary,
            imageUrl: body.imageUrl,
            categoryCode: body.categoryCode,
            isPriority: body.isPriority,
            tags: body.tags,
            opensAt: check parseTime(body.opensAt, "opensAt"),
            closesAt: check parseTime(body.closesAt, "closesAt")
        }, now, postLinkOrigins);
        check campaign:ensurePostChangeAllowed(repo, current, changed);
        check repo.update(changed, body.version);
        return campaignDto(changed, now);
    } on fail error e {
        return failure(e, correlationId, "Edit campaign");
    }
}

isolated function archiveCampaign(auth:Principal p, string? correlationId, string id) returns CampaignDto|ProblemResponse {
    do {
        time:Utc now = time:utcNow();
        campaign:Campaign archived = check campaign:archiveCampaign(check campaignRepository(actorOf(p, correlationId)),
                check uuidOf(id, "id"), now);
        return campaignDto(archived, now);
    } on fail error e {
        return failure(e, correlationId, "Archive campaign");
    }
}

// ---- S2 Connection ------------------------------------------------------------------------------------

isolated function startConnect(auth:Principal p, string? correlationId, ConnectStartBody body)
        returns http:StatusCodeResponse {
    do {
        string? returnTo = body.returnTo;
        if returnTo is string && !isRelativePath(returnTo) {
            return badRequest("returnTo must be a relative One WSO2 path", correlationId);
        }
        string? pending = body.pendingCampaignId;
        string? pendingId = pending is string ? check uuidOf(pending, "pendingCampaignId") : ();
        linkedin:ProviderAdapter? adapter = linkedInProvider();
        if adapter is () {
            log:printWarn("LinkedIn connect is not configured", correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }
        connection:OAuthState state = check connection:newOAuthState(p.employeeId, returnTo, pendingId, time:utcNow());
        check (check oauthStateRepository()).issue(state);
        // The nonce goes out only when ID-token validation can check it (`linkedinNonceMode`, `outbound.bal`).
        string url = nonceModeFor(idTokens()) == "OFF"
            ? check adapter.authorizationUrl(state.state)
            : check adapter.authorizationUrlWithNonce(state.state, state.nonce);
        return <http:Ok>{body: {authorizationUrl: url, state: state.state, expiresAt: ts(state.expiresAt)}};
    } on fail error e {
        return failure(e, correlationId, "Start LinkedIn connect");
    }
}

# Whether `path` is a same-origin path One WSO2 can navigate to after the OAuth round trip: it starts with
# one `/` and has no backslash (browsers read `/\host` as `//host`, an open redirect), whitespace or
# control characters.
#
# + path - `returnTo`
# + return - True when safe
isolated function isRelativePath(string path) returns boolean =>
    path.length() <= 512 && re `/([^/\\\s\p{Cc}][^\\\s\p{Cc}]*)?`.isFullMatch(path);

isolated function completeConnect(auth:Principal p, string? correlationId, ConnectCompleteBody body)
        returns http:StatusCodeResponse {
    do {
        if body.code.length() == 0 || body.code.length() > 2048 || body.state.length() < 32 || body.state.length() > 128 {
            return badRequest("code and state are required", correlationId);
        }
        // Server-side redirect URI check (token-and-oauth-notes §2): the page that received the code must be
        // the one the authorize request named, which is also what the token exchange sends.
        if body.redirectUri != redirectUri() {
            log:printWarn("LinkedIn callback on an unexpected redirect URI", correlationId = correlationId);
            return unprocessable(OAUTH_REDIRECT_MISMATCH, "This sign-in didn't come back to Amplify's page; start again",
                    correlationId);
        }
        linkedin:ProviderAdapter? adapter = linkedInProvider();
        var sealer = cipher();
        if adapter is () || sealer is () {
            log:printWarn("LinkedIn connect is not configured", correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }
        time:Utc now = time:utcNow();
        // Single use: consume deletes the state whether or not the rest succeeds.
        connection:OAuthState? state = check (check oauthStateRepository()).consume(body.state, p.employeeId, now);
        if state is () {
            return conflicted(OAUTH_STATE_INVALID, "This sign-in link expired or was already used; start again",
                    correlationId);
        }
        linkedin:TokenGrant|linkedin:ProviderError grant = adapter.exchangeCode(body.code);
        if grant is linkedin:ProviderError {
            return providerFailure(grant, correlationId);
        }
        linkedin:MemberProfile|linkedin:ProviderError profile = adapter.userInfo(grant.accessToken);
        if profile is linkedin:ProviderError {
            return providerFailure(profile, correlationId);
        }
        http:StatusCodeResponse? refused = checkIdToken(idTokens(), grant.idToken, profile.sub, correlationId, state);
        if refused is http:StatusCodeResponse {
            return refused;
        }
        time:Utc expiresAt = time:utcAddSeconds(now, <decimal>grant.expiresInSeconds);
        connection:StoredToken token = check connection:sealToken(sealer, grant.accessToken, p.employeeId, expiresAt, now);
        // The token row goes in with the connection change, in one transaction (api review H3).
        connection:LinkedInConnection linked = check connection:completeConnection(
                check connectionRepository(actorOf(p, correlationId)), {
            employeeId: p.employeeId,
            memberUrn: profile.memberUrn,
            scopes: grant.scopes,
            token: connection:tokenRef(token),
            expiresInSeconds: grant.expiresInSeconds
        }, now, token);
        // The consent record is best effort: the link itself is already stored, so a failure here must not
        // strand the person on an error page after LinkedIn.
        error? consentRecorded = recordConsent(p.employeeId, connection:CONSENTED, (), now);
        if consentRecorded is error {
            log:printWarn("Could not record LinkedIn consent", errorKind = errorKind(consentRecorded),
                    sqlState = sqlStateOf(consentRecorded), correlationId = correlationId);
        }
        return <http:Ok>{
            body: {
                status: connection:connectionStatus(linked, now),
                memberUrn: linked.memberUrn,
                connectedAt: ts(linked.connectedAt),
                expiresAt: ts(linked.accessExpiresAt),
                returnTo: state.returnTo,
                pendingCampaignId: state.pendingCampaignId
            }
        };
    } on fail error e {
        return failure(e, correlationId, "Complete LinkedIn connect");
    }
}

isolated function recordConsent(string employeeId, connection:ConsentDecision decision, string? profileUrl,
        time:Utc now) returns error? => (check consentRepository()).save(employeeId, decision, profileUrl, now);

isolated function declineConnect(auth:Principal p, string? correlationId, ConnectDeclineBody body)
        returns http:StatusCodeResponse {
    do {
        // Optional: blank means they chose not to give it. A value must be a LinkedIn profile URL.
        string? given = body.profileUrl;
        string? url = given is string && given.trim().length() > 0 ? given.trim() : ();
        if url is string && !connection:isProfileUrl(url) {
            return badRequest("profileUrl must be a LinkedIn profile URL like https://www.linkedin.com/in/your-name",
                    correlationId);
        }
        check recordConsent(p.employeeId, connection:DECLINED, url, time:utcNow());
        return <http:NoContent>{};
    } on fail error e {
        return failure(e, correlationId, "Record LinkedIn consent decline");
    }
}

# ID-token check on connect (common H1 / api H1), when `linkedinIdTokenValidation` is on: the token must be
# present, validate (RS256, `iss`, `aud`, `exp`/`iat`, and the `nonce` per `linkedinNonceMode`) and name the
# same member as userinfo. The validator's reason goes only to the log, never to the caller or with the token.
#
# + validator - The validator, `()` when validation is off
# + idToken - `TokenGrant.idToken`
# + userInfoSub - `sub` from `/v2/userinfo`
# + correlationId - Correlation id
# + state - The consumed OAuth state, whose `nonce` was sent on the authorize request
# + return - The refusal, or `()` to carry on
isolated function checkIdToken(linkedin:IdTokenValidator? validator, string? idToken, string userInfoSub,
        string? correlationId, connection:OAuthState state) returns http:StatusCodeResponse? {
    if validator is () {
        return ();
    }
    if idToken is () {
        log:printWarn("LinkedIn returned no ID token while ID-token validation is on", correlationId = correlationId);
        return unprocessable(OAUTH_STATE_INVALID, "LinkedIn didn't confirm the sign-in; start again", correlationId);
    }
    NonceMode nonceMode = nonceModeFor(validator);
    // REQUIRE: the validator itself refuses a token with no nonce or another one. SEND: a nonce that is present
    // must match; one that is absent is logged, not refused (see `linkedinNonceMode`).
    linkedin:IdTokenClaims|linkedin:ProviderError claims = validator.validate(idToken,
            nonceMode == "REQUIRE" ? state.nonce : ());
    if claims is linkedin:ProviderError {
        if claims.detail().code == linkedin:UNAVAILABLE {
            log:printWarn("LinkedIn ID-token keys unavailable", correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId, "LinkedIn is unavailable, try again");
        }
        log:printWarn("LinkedIn ID token refused", reason = claims.message(), correlationId = correlationId);
        return unprocessable(OAUTH_STATE_INVALID, "LinkedIn didn't confirm the sign-in; start again", correlationId);
    }
    if nonceMode == "SEND" {
        string? echoed = claims.nonce;
        if echoed is () {
            log:printWarn("LinkedIn ID token carries no nonce (nonce not echoed)", correlationId = correlationId);
        } else if !connection:nonceMatches(state, echoed) {
            log:printWarn("LinkedIn ID token nonce does not match", correlationId = correlationId);
            return unprocessable(OAUTH_STATE_INVALID, "LinkedIn didn't confirm the sign-in; start again", correlationId);
        }
    }
    if claims.sub != userInfoSub {
        log:printWarn("LinkedIn ID token names another member than userinfo", correlationId = correlationId);
        return unprocessable(OAUTH_STATE_INVALID, "LinkedIn didn't confirm the sign-in; start again", correlationId);
    }
    return ();
}

isolated function providerFailure(linkedin:ProviderError err, string? correlationId) returns http:StatusCodeResponse {
    // The provider body never reaches the caller (it may echo the code or token).
    log:printWarn("LinkedIn call failed", errorCode = err.detail().code, correlationId = correlationId);
    if err.detail().code == linkedin:UNAUTHORIZED || err.detail().code == linkedin:REJECTED {
        return unprocessable(OAUTH_STATE_INVALID, "LinkedIn didn't accept the sign-in; start again", correlationId);
    }
    return unavailable(DEPENDENCY_UNAVAILABLE, correlationId, "LinkedIn is unavailable, try again");
}

isolated function removeConnection(auth:Principal p, string? correlationId) returns http:NoContent|ProblemResponse {
    do {
        time:Utc now = time:utcNow();
        connection:ConnectionRepository repo = check connectionRepository(actorOf(p, correlationId));
        connection:LinkedInConnection? existing = check repo.findByEmployee(p.employeeId, types:LINKEDIN);
        if existing is connection:LinkedInConnection {
            // Revoke at LinkedIn first; only a confirmed (or already dead) token lets the local delete go on.
            http:ServiceUnavailable? refused = check revokeAtLinkedIn(existing, correlationId, now);
            if refused is http:ServiceUnavailable {
                return refused;
            }
        }
        _ = check connection:removeConnection(repo, p.employeeId, now);
        return http:NO_CONTENT;
    } on fail error e {
        return failure(e, correlationId, "Remove LinkedIn connection");
    }
}

# Revokes the connection's access token at LinkedIn before Amplify deletes it. Nothing to revoke when the
# connection is already removed, has no token row, or the token expired on its own. LinkedIn saying the token
# is already invalid counts as done. Any other failure keeps the connection so the employee can try again.
#
# + c - The employee's connection
# + correlationId - Request correlation id
# + now - Current time
# + return - A 503 to return when LinkedIn couldn't confirm, `()` to go on with the delete, or an error
isolated function revokeAtLinkedIn(connection:LinkedInConnection c, string? correlationId, time:Utc now)
        returns http:ServiceUnavailable?|error {
    connection:TokenRef? ref = c.currentToken;
    if c.removedAt !is () || ref is () || time:utcDiffSeconds(c.accessExpiresAt, now) <= 0d {
        return ();
    }
    linkedin:ProviderAdapter? adapter = linkedInProvider();
    var sealer = cipher();
    if adapter is () || sealer is () {
        log:printWarn("LinkedIn revoke is not configured", correlationId = correlationId);
        return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
    }
    connection:StoredToken? token = check (check tokenRepository()).find(ref);
    if token is () {
        return ();
    }
    string|error bearer = connection:openToken(sealer, token);
    if bearer is error {
        // Can't open it, so can't revoke it; the local delete still removes our copy.
        log:printWarn("Stored LinkedIn token did not open; removing without revoking", correlationId = correlationId);
        return ();
    }
    linkedin:ProviderError? revoked = adapter.revokeToken(bearer);
    if revoked is linkedin:ProviderError {
        linkedin:ProviderErrorCode code = revoked.detail().code;
        if code == linkedin:UNAUTHORIZED || code == linkedin:REJECTED {
            log:printInfo("LinkedIn token was already invalid", correlationId = correlationId);
            return ();
        }
        log:printWarn("LinkedIn revoke failed; connection kept", errorCode = code, correlationId = correlationId);
        return unavailable(DEPENDENCY_UNAVAILABLE, correlationId,
                "LinkedIn couldn't be reached, so the connection was not removed. Try again shortly.");
    }
    return ();
}

// ---- C1 Sharing -----------------------------------------------------------------------------------

isolated function requestShare(auth:Principal p, string? correlationId, string id, ShareBody body)
        returns http:StatusCodeResponse {
    do {
        string campaignId = check uuidOf(id, "id");
        types:ShareKind|error kind = body.kind.ensureType();
        if kind is error {
            return badRequest("kind must be REPOST, REPOST_COMMENTARY, SHARE or SHARE_COMMENTARY", correlationId);
        }
        Settings settings = check loadSettings();
        if !settings.sharingEnabled {
            return conflicted(FEATURE_DISABLED, "Sharing is paused right now", correlationId);
        }
        time:Utc now = time:utcNow();
        store:Actor actor = actorOf(p, correlationId);
        campaign:Campaign? c = check (check campaignRepository(actor)).findById(campaignId);
        // Same answer as `GET /campaigns/{id}`: an employee gets 404 for a campaign that is archived, scheduled or
        // closed, so the share route does not confirm the id exists. Editors see every campaign and get the
        // specific code (CAMPAIGN_CLOSED, CAMPAIGN_ARCHIVED) from the domain.
        if c is () || (!can(p, auth:CAN_CAMPAIGN) && (c.archivedAt !is () || !campaign:isOpen(c, now))) {
            return notFound("Campaign not found", correlationId);
        }
        connection:LinkedInConnection? linked = check (check connectionRepository(actor)).findByEmployee(p.employeeId,
                types:LINKEDIN);
        if linked is () || linked.removedAt !is () {
            return conflicted(LINKEDIN_NOT_CONNECTED, "Connect your LinkedIn account first", correlationId);
        }
        sharing:ShareRequest request = check sharing:requestShare(check shareRepository(actor),
                {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn, open: campaign:isOpen(c, now)},
                {memberUrn: linked.memberUrn, usable: connection:canShare(linked, now, settings.reminderDays)},
                {employeeId: p.employeeId, kind, commentary: body.commentary}, now);
        return <http:Accepted>{body: shareDto(request)};
    } on fail error e {
        return failure(e, correlationId, "Request share");
    }
}

// ---- S3 External Sharing ------------------------------------------------------------------------------

# The evidence URL a claim body names: the URL as sent, or the canonical LinkedIn post URL built from a post
# number. Exactly one of the two.
#
# + body - Claim body
# + return - The URL to validate and store, or a domain error
isolated function evidenceUrlOf(ExternalShareBody body) returns string|types:DomainError {
    string? url = body.evidenceUrl;
    string? number = body.activityId;
    if url is string && number is string {
        return types:domainError(VALIDATION_FAILED, "Send evidenceUrl or activityId, not both");
    }
    if number is string {
        return types:linkedInPostEvidenceUrl(number);
    }
    if url is string {
        return url;
    }
    return types:domainError(VALIDATION_FAILED, "Send evidenceUrl or activityId");
}

isolated function claimExternalShare(auth:Principal p, string? correlationId, ExternalShareBody body)
        returns http:StatusCodeResponse {
    do {
        string? campaignId = body.campaignId;
        string evidenceUrl = check evidenceUrlOf(body);
        external_sharing:ExternalShare claim = check external_sharing:submitExternalShare(
                check externalShareRepository(actorOf(p, correlationId), 3), {
            employeeId: p.employeeId,
            evidenceUrl,
            certified: body.certified,
            campaignId: campaignId is string ? check uuidOf(campaignId, "campaignId") : ()
        }, time:utcNow());
        return <http:Created>{body: externalShareDto(claim)};
    } on fail error e {
        return failure(e, correlationId, "Claim external share");
    }
}

# PO decisions on a claim.
enum Decision {
    APPROVE,
    REJECT,
    AMPLIFY
}

isolated function decideExternalShare(auth:Principal p, string? correlationId, string id, Decision decision,
        string? reason) returns http:StatusCodeResponse {
    do {
        string claimId = check uuidOf(id, "id");
        check maxLen(reason, 1000, "reason");
        Settings settings = check loadSettings();
        external_sharing:ExternalShareRepository repo = check externalShareRepository(actorOf(p, correlationId),
                settings.topN);
        time:Utc now = time:utcNow();
        external_sharing:ExternalShare result;
        if decision == REJECT {
            result = check external_sharing:rejectExternalShare(repo, claimId, p.employeeId, reason ?: "", now);
        } else {
            scoring:PointRule[] rules = check (check pointRuleRepository(actorOf(p, correlationId))).all();
            result = decision == APPROVE
                ? check external_sharing:approveWithPoints(repo, rules, claimId, p.employeeId, correlationId, now)
                : check external_sharing:amplifyWithPoints(repo, rules, claimId, p.employeeId, correlationId, now,
                        check ledgerRepository(actorOf(p, correlationId), settings.topN));
        }
        return <http:Ok>{body: externalShareDto(result)};
    } on fail error e {
        return failure(e, correlationId, "Decide external share");
    }
}

// ---- C2 Scoring -------------------------------------------------------------------------------------

isolated function addPointRule(auth:Principal p, string? correlationId, PointRuleBody body) returns http:StatusCodeResponse {
    do {
        types:PointAction|error action = body.action.ensureType();
        if action is error {
            return badRequest("Unknown action", correlationId);
        }
        if body.points > 10000 {
            return badRequest("points must be at most 10000", correlationId);
        }
        scoring:PointRuleRepository repo = check pointRuleRepository(actorOf(p, correlationId));
        time:Utc now = time:utcNow();
        scoring:PointRule rule = check scoring:setPointRule(repo, action, body.points,
                check parseTime(body.effectiveFrom, "effectiveFrom"), p.employeeId, now);
        return <http:Created>{body: pointRuleDto(rule, check repo.all(), now)};
    } on fail error e {
        return failure(e, correlationId, "Add point rule");
    }
}

isolated function adjustPoints(auth:Principal p, string? correlationId, AdjustmentBody body) returns http:StatusCodeResponse {
    do {
        check maxLen(body.reason, 1000, "reason");
        if body.points < -10000 || body.points > 10000 {
            return badRequest("points must be between -10000 and 10000", correlationId);
        }
        types:EmployeeId employeeId = check types:parseEmployeeId(body.employeeId);
        identity:Employee? employee = check (check employeeRepository()).findById(employeeId);
        if employee is () {
            return notFound("Employee not found", correlationId);
        }
        string? campaignId = body.campaignId;
        Settings settings = check loadSettings();
        types:LedgerEntry entry = check scoring:adjustPoints(check ledgerRepository(actorOf(p, correlationId),
                settings.topN), employeeId, body.points, body.reason, p.employeeId,
                campaignId is string ? check uuidOf(campaignId, "campaignId") : (), correlationId, time:utcNow());
        return <http:Created>{body: ledgerDto(entry)};
    } on fail error e {
        return failure(e, correlationId, "Adjust points");
    }
}

isolated function reverseEntry(auth:Principal p, string? correlationId, string reference, string reason)
        returns http:StatusCodeResponse {
    do {
        check maxLen(reason, 1000, "reason");
        Settings settings = check loadSettings();
        types:LedgerEntry entry = check scoring:reverseEntry(check ledgerRepository(actorOf(p, correlationId),
                settings.topN), reference, reason, p.employeeId, correlationId, time:utcNow());
        return <http:Created>{body: ledgerDto(entry)};
    } on fail error e {
        return failure(e, correlationId, "Reverse ledger entry");
    }
}

// ---- S5 Admin ---------------------------------------------------------------------------------------

isolated function retryAnnouncement(auth:Principal p, string? correlationId, string id) returns http:StatusCodeResponse {
    do {
        string campaignId = check uuidOf(id, "id");
        Settings settings = check loadSettings();
        if !settings.announcementsEnabled {
            return conflicted(FEATURE_DISABLED, "Announcements are paused right now", correlationId);
        }
        announcements:AnnouncementRepository repo = check announcementRepository(actorOf(p, correlationId));
        announcements:Announcement? current = check repo.findByCampaign(campaignId);
        if current is () {
            return notFound("Announcement not found", correlationId);
        }
        announcements:Announcement queued = check announcements:retryAnnouncement(current);
        check repo.requeue(campaignId);
        _ = triggerJobs("/runs", correlationId);
        return <http:Accepted>{body: announcementDto(queued)};
    } on fail error e {
        return failure(e, correlationId, "Retry announcement");
    }
}
