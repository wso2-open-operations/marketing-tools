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
import amplify_api.auth;
import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.scoring;
import amplify_domain.identity;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/http;
import ballerina/log;
import ballerina/time;

# Port the published API listens on (fronted by the API proxy at the cell edge).
configurable int port = 9090;

# Largest request body the API accepts from a request that declares its length, bytes (64 KiB). The biggest real
# payload is a campaign registration (title, summary, two URLs, up to 20 tags) or a share (commentary), both under
# 16 KiB, so the headroom is ample.
const int MAX_REQUEST_BODY_BYTES = 65536;

# What the transport accepts before it refuses a request unread, bytes: twice the API limit, so a request that
# declares its length reaches `BodyLimitInterceptor` and gets problem details, and an absurd one never gets read.
# A chunked body carries no length to check, so this bound is the one that stops it: the listener answers 413 itself,
# before any interceptor runs, so that answer has no problem details body.
const int MAX_ENTITY_BODY_BYTES = MAX_REQUEST_BODY_BYTES * 2;

// Request bodies here are small JSON documents; without a limit the listener buffers whatever it is sent, and the
// idempotency hash serialises it again, before validation can refuse it. `BodyLimitInterceptor` answers a request
// that declares a longer body with problem details before any of that; this transport limit bounds every request
// that reaches the resources.
listener http:Listener apiListener = new (port, requestLimits = {maxEntityBodySize: MAX_ENTITY_BODY_BYTES});

function init() returns error? {
    check checkApiKeys(jobsUrl, schedulerUrl, internalApiKey, schedulerApiKey);
    log:printInfo(string `${COMPONENT} starting on port ${port}`);
    string? tls = store:tlsWarning(dbConfig());
    if tls is string {
        log:printWarn(tls);
    }
    if !rosterConfigured() {
        log:printInfo("People directory not configured (peopleDirectoryUrl empty): My Team answers UNAVAILABLE");
    }
    // Converge the scheduler jobs to the settings in the background (ADR-026).
    _ = start reconcileAtStartup();
}

# `GET /me` employee block.
type MeEmployee record {|
    # Asgardeo `sub`
    string employeeId;
    # Lowercased email
    string email;
    # Display name
    string displayName;
|};

# `GET /me` LinkedIn block.
type MeLinkedIn record {|
    # `ACTIVE`, `EXPIRING`, `NEEDS_RECONNECT`, `REMOVED` or `NOT_CONNECTED`
    string status;
    # Access token expiry, RFC 3339; `()` when not connected or removed
    string? expiresAt;
|};

# `GET /me` response.
type MeResponse record {|
    # Stored employee row
    MeEmployee employee;
    # Configured groups from the token
    string[] roles;
    # Grants those groups give (`EMPLOYEE` always)
    auth:Access[] grants;
    # Capabilities derived from the activity matrix
    string[] capabilities;
    # LinkedIn connection
    MeLinkedIn linkedin;
|};

# Refuses a request that declares a body past `MAX_REQUEST_BODY_BYTES` with problem details, before the payload is
# read and hashed for idempotency. A request that declares no `Content-Length` can't be measured here: the transport
# limit refuses it instead.
isolated service class BodyLimitInterceptor {
    *http:RequestInterceptor;

    isolated resource function 'default [string... path](http:RequestContext ctx, http:Request req)
            returns http:NextService|http:Response|error? {
        string|http:HeaderNotFoundError length = req.getHeader("content-length");
        if length is string {
            int|error declared = int:fromString(length.trim());
            if declared is int && declared > MAX_REQUEST_BODY_BYTES {
                return payloadTooLarge(cid(ctx));
            }
        }
        return ctx.next();
    }
}

# 413 problem details for a request body past the limit.
#
# + correlationId - Correlation id
# + return - The response
isolated function payloadTooLarge(string? correlationId) returns http:Response {
    http:Response res = new;
    res.statusCode = 413;
    res.setJsonPayload(problem(413, "Payload Too Large", PAYLOAD_TOO_LARGE,
            string `The request body is larger than ${MAX_REQUEST_BODY_BYTES} bytes`, correlationId).toJson(),
            PROBLEM_JSON);
    return res;
}

# Amplify published API. Every resource except the probes runs behind `AuthInterceptor`.
@display {
    label: "Amplify API",
    id: "amplify/amplify-api"
}
service http:InterceptableService / on apiListener {

    // Order matters: responses run back through the list, so the security headers (first) are added to
    // every response, including errors mapped by the two error interceptors, and the caller is authenticated
    // before the body limit answers.
    public function createInterceptors() returns [SecurityHeadersInterceptor, ResponseErrorMapper, AuthInterceptor,
            BodyLimitInterceptor, RequestErrorMapper] => [new, new, new, new, new];

    # Liveness probe.
    #
    # + return - Component health
    resource function get health() returns types:HealthStatus => {component: COMPONENT, status: types:UP};

    # Readiness probe: the database breaker isn't open, the database answers and the token-key breaker
    # isn't open. The jobs, roster and LinkedIn breakers are reported but don't fail readiness (non-fatal
    # degradations, ADR-024). Each probe also refreshes the `amplify_breaker_state` gauges (ADR-028).
    #
    # + return - Readiness with the checks
    resource function get ready() returns http:Ok|http:ServiceUnavailable {
        boolean database = dbBreakerState() != "OPEN" && dbReachable();
        BreakerReport jwks = jwksBreaker();
        map<string> breakers = breakerStates(jwks);
        resilience:exportBreakerStates(COMPONENT, breakers);
        boolean up = database && jwks != "OPEN";
        json body = {
            component: COMPONENT,
            status: up ? types:UP : types:DOWN,
            database: database ? types:UP : types:DOWN,
            breakers
        };
        return up ? <http:Ok>{body} : <http:ServiceUnavailable>{body};
    }

    # The caller: employee row (upserted from the token claims), capabilities from the activity matrix,
    # and LinkedIn connection status.
    #
    # + ctx - Request context (principal from the interceptor)
    # + req - Request
    # + return - The caller, or problem details
    resource function get me(http:RequestContext ctx, http:Request req)
            returns http:Response|http:Conflict|http:ServiceUnavailable|error {
        auth:Principal principal = check principalOf(ctx);
        string? correlationId = cid(ctx);
        time:Utc now = time:utcNow();

        identity:Employee|error employee = upsertEmployee(principal, now);
        if employee is error {
            if store:isUniqueViolation(employee) {
                // Generic on purpose: the sign-in resolver already merged a re-created account, so this is a
                // real clash, and which email belongs to whom is nothing a caller may probe for.
                return conflicted(EMAIL_CONFLICT, "This sign-in can't be matched to an Amplify profile, contact the Amplify admins",
                        correlationId);
            }
            log:printError("Could not record the employee", errorKind = errorKind(employee), sqlState = sqlStateOf(employee),
                    correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }

        store:Actor actor = {actorId: principal.employeeId, roles: principal.roles, correlationId};
        connection:LinkedInConnection|error? linked = findConnection(actor, principal.employeeId);
        if linked is error {
            log:printError("Could not read the LinkedIn connection", errorKind = errorKind(linked),
                    sqlState = sqlStateOf(linked), correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId);
        }
        MeResponse me = {
            employee: {
                employeeId: employee.employeeId,
                email: employee.email,
                displayName: employee.displayName
            },
            roles: principal.roles,
            grants: principal.grants,
            capabilities: auth:capabilities(principal.grants),
            linkedin: linkedInOf(linked, now)
        };
        // An admin's capability list alone runs past 512 chars (M11b).
        return jsonBody(me.toJson());
    }

    // ---- S1 Campaign -------------------------------------------------------------------------------

    # Campaign list (paged).
    #
    # + ctx - Request context
    # + status - `open` (default), `scheduled`, `closed`, `archived`, `all` (non-open: `CAN_CAMPAIGN` only)
    # + window - Opened in the last N days, `<N>d`
    # + tag - Tag filter
    # + page - Zero-based page
    # + size - Page size
    # + return - The page, or problem details
    resource function get campaigns(http:RequestContext ctx, string status = "open", string? window = (),
            string? tag = (), int page = 0, int size = 14) returns http:Response|ProblemResponse|error =>
        okJson(listCampaigns(check principalOf(ctx), cid(ctx), status, window, tag, page, size));

    # Registers a campaign; `shareNow=true` also triggers a Run.
    #
    # + ctx - Request context
    # + req - Request
    # + body - Campaign
    # + shareNow - Save & Share Now
    # + return - 201 with the campaign, or problem details
    resource function post campaigns(http:RequestContext ctx, http:Request req, @http:Payload CampaignDraftBody body,
            boolean shareNow = false) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? id = cid(ctx);
        final readonly & CampaignDraftBody b = body.cloneReadOnly();
        return idempotent(ctx, req, p, "/campaigns?shareNow=" + shareNow.toString(), b.toJson(),
                isolated function() returns http:StatusCodeResponse => registerCampaign(p, id, b, shareNow));
    }

    # One campaign.
    #
    # + ctx - Request context
    # + id - Campaign id
    # + return - The campaign, or problem details
    resource function get campaigns/[string id](http:RequestContext ctx) returns http:Response|ProblemResponse|error =>
        okJson(campaignJson(getCampaign(check principalOf(ctx), cid(ctx), id)));

    # Edits a campaign.
    #
    # + ctx - Request context
    # + id - Campaign id
    # + body - Changes with the version read
    # + return - The campaign, or problem details
    resource function patch campaigns/[string id](http:RequestContext ctx, @http:Payload CampaignPatchBody body)
            returns http:Response|ProblemResponse|error =>
        okJson(campaignJson(editCampaign(check principalOf(ctx), cid(ctx), id, body)));

    # Archives a campaign.
    #
    # + ctx - Request context
    # + id - Campaign id
    # + return - The campaign, or problem details
    resource function delete campaigns/[string id](http:RequestContext ctx) returns http:Response|ProblemResponse|error =>
        okJson(campaignJson(archiveCampaign(check principalOf(ctx), cid(ctx), id)));

    # Tags in use.
    #
    # + ctx - Request context
    # + return - Tags, or problem details
    resource function get tags(http:RequestContext ctx) returns json|ProblemResponse {
        string[]|error tags = tagList();
        return tags is error ? failure(tags, cid(ctx), "List tags") : {tags};
    }

    # Active categories.
    #
    # + ctx - Request context
    # + return - Categories, or problem details
    resource function get categories(http:RequestContext ctx) returns json|ProblemResponse {
        campaign:Category[]|error categories = categoryList();
        return categories is error ? failure(categories, cid(ctx), "List categories") : {categories: categories.toJson()};
    }

    // ---- S2 Connection -----------------------------------------------------------------------------

    # Starts LinkedIn OAuth.
    #
    # + ctx - Request context
    # + req - Request
    # + return - Authorization URL and state, or problem details
    resource function post connections/linkedin/'start(http:RequestContext ctx, http:Request req)
            returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? id = cid(ctx);
        json|error raw = req.getJsonPayload();
        // No body is fine (`{}`); a body that is not valid JSON is a 400 like on every other route.
        ConnectStartBody|error body = raw is http:NoContentError ? {} : raw is error ? raw : raw.cloneWithType();
        if body is error {
            return toResponse(badRequest("The request has invalid fields", id));
        }
        final readonly & ConnectStartBody startBody = body.cloneReadOnly();
        return idempotent(ctx, req, p, "/connections/linkedin/start", startBody.toJson(),
                isolated function() returns http:StatusCodeResponse => startConnect(p, id, startBody));
    }

    # Completes LinkedIn OAuth.
    #
    # + ctx - Request context
    # + req - Request
    # + body - Code and state
    # + return - The connection, or problem details
    resource function post connections/linkedin/complete(http:RequestContext ctx, http:Request req,
            @http:Payload ConnectCompleteBody body) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? id = cid(ctx);
        final readonly & ConnectCompleteBody b = body.cloneReadOnly();
        // The code is a one-time secret: fingerprint the state only.
        return idempotent(ctx, req, p, "/connections/linkedin/complete", {state: b.state},
                isolated function() returns http:StatusCodeResponse => completeConnect(p, id, b));
    }

    # Records that the caller doesn't consent to link LinkedIn, with their LinkedIn profile URL.
    #
    # + ctx - Request context
    # + req - Request
    # + body - Profile URL
    # + return - 204, or problem details
    resource function post connections/linkedin/decline(http:RequestContext ctx, http:Request req,
            @http:Payload ConnectDeclineBody body) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? id = cid(ctx);
        final readonly & ConnectDeclineBody b = body.cloneReadOnly();
        return idempotent(ctx, req, p, "/connections/linkedin/decline", b.toJson(),
                isolated function() returns http:StatusCodeResponse => declineConnect(p, id, b));
    }

    # Removes the caller's LinkedIn connection.
    #
    # + ctx - Request context
    # + return - 204, or problem details
    resource function delete connections/linkedin(http:RequestContext ctx) returns http:NoContent|ProblemResponse|error =>
        removeConnection(check principalOf(ctx), cid(ctx));

    // ---- C1 Sharing --------------------------------------------------------------------------------

    # Requests a share (202).
    #
    # + ctx - Request context
    # + req - Request
    # + id - Campaign id
    # + body - Kind and commentary
    # + return - The queued share, or problem details
    resource function post campaigns/[string id]/shares(http:RequestContext ctx, http:Request req,
            @http:Payload ShareBody body) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? cidValue = cid(ctx);
        final readonly & ShareBody b = body.cloneReadOnly();
        final string idFinal = id;
        return idempotent(ctx, req, p, "/campaigns/" + id + "/shares", b.toJson(),
                isolated function() returns http:StatusCodeResponse => requestShare(p, cidValue, idFinal, b));
    }

    # The caller's shares.
    #
    # + ctx - Request context
    # + return - Shares, or problem details
    resource function get me/shares(http:RequestContext ctx) returns http:Response|ProblemResponse|error {
        auth:Principal p = check principalOf(ctx);
        sharing:ShareView[]|error rows = sharesOf(p.employeeId);
        return okJson(rows is error ? failure(rows, cid(ctx), "My shares")
            : {items: from var r in rows select shareViewDto(r).toJson()});
    }

    // ---- S3 External Sharing -----------------------------------------------------------------------

    # Claims an external share.
    #
    # + ctx - Request context
    # + req - Request
    # + body - Evidence URL and certification
    # + return - 201 with the claim, or problem details
    resource function post external\-shares(http:RequestContext ctx, http:Request req,
            @http:Payload ExternalShareBody body) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? id = cid(ctx);
        final readonly & ExternalShareBody b = body.cloneReadOnly();
        return idempotent(ctx, req, p, "/external-shares", b.toJson(),
                isolated function() returns http:StatusCodeResponse => claimExternalShare(p, id, b));
    }

    # The caller's claims.
    #
    # + ctx - Request context
    # + return - Claims, or problem details
    resource function get me/external\-shares(http:RequestContext ctx) returns http:Response|ProblemResponse|error {
        auth:Principal p = check principalOf(ctx);
        external_sharing:ExternalShare[]|error rows = claimsOf(p.employeeId);
        return okJson(rows is error ? failure(rows, cid(ctx), "My external shares")
            : {items: from var r in rows select externalShareDto(r).toJson()});
    }

    # PO review list.
    #
    # + ctx - Request context
    # + status - Status filter (default `PENDING`)
    # + page - Zero-based page
    # + size - Page size
    # + return - The page, or problem details
    resource function get po/external\-shares(http:RequestContext ctx, string status = "PENDING", int page = 0,
            int size = 25) returns http:Response|ProblemResponse|error =>
        okJson(reviewList(cid(ctx), status, page, size));

    # Approves a claim (and awards `OWN_POST`).
    #
    # + ctx - Request context
    # + req - Request
    # + id - Claim id
    # + return - The claim, or problem details
    resource function post po/external\-shares/[string id]/approve(http:RequestContext ctx, http:Request req)
            returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? c = cid(ctx);
        final string idFinal = id;
        return idempotent(ctx, req, p, "/po/external-shares/" + id + "/approve", (),
                isolated function() returns http:StatusCodeResponse => decideExternalShare(p, c, idFinal, APPROVE, ()));
    }

    # Rejects a claim.
    #
    # + ctx - Request context
    # + req - Request
    # + id - Claim id
    # + body - Reason
    # + return - The claim, or problem details
    resource function post po/external\-shares/[string id]/reject(http:RequestContext ctx, http:Request req,
            @http:Payload ReasonBody body) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? c = cid(ctx);
        final readonly & ReasonBody b = body.cloneReadOnly();
        final string idFinal = id;
        return idempotent(ctx, req, p, "/po/external-shares/" + id + "/reject", b.toJson(),
                isolated function() returns http:StatusCodeResponse => decideExternalShare(p, c, idFinal, REJECT, b.reason));
    }

    # Marks a claim amplified (and appends the top-up).
    #
    # + ctx - Request context
    # + req - Request
    # + id - Claim id
    # + return - The claim, or problem details
    resource function post po/external\-shares/[string id]/amplified(http:RequestContext ctx, http:Request req)
            returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? c = cid(ctx);
        final string idFinal = id;
        return idempotent(ctx, req, p, "/po/external-shares/" + id + "/amplified", (),
                isolated function() returns http:StatusCodeResponse => decideExternalShare(p, c, idFinal, AMPLIFY, ()));
    }

    // ---- C2 Scoring --------------------------------------------------------------------------------

    # Every point rule version.
    #
    # + ctx - Request context
    # + return - Rules, or problem details
    resource function get po/point\-rules(http:RequestContext ctx) returns http:Response|ProblemResponse|error {
        auth:Principal p = check principalOf(ctx);
        scoring:PointRule[]|error rules = getRules(p, cid(ctx));
        if rules is error {
            return failure(rules, cid(ctx), "List point rules");
        }
        time:Utc now = time:utcNow();
        return jsonBody({rules: from var r in rules select pointRuleDto(r, rules, now).toJson()});
    }

    # Adds a point rule version.
    #
    # + ctx - Request context
    # + req - Request
    # + body - Action, points, start
    # + return - 201 with the rule, or problem details
    resource function post po/point\-rules(http:RequestContext ctx, http:Request req, @http:Payload PointRuleBody body)
            returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? c = cid(ctx);
        final readonly & PointRuleBody b = body.cloneReadOnly();
        return idempotent(ctx, req, p, "/po/point-rules", b.toJson(),
                isolated function() returns http:StatusCodeResponse => addPointRule(p, c, b));
    }

    # Adjusts an employee's points.
    #
    # + ctx - Request context
    # + req - Request
    # + body - Employee, points, reason
    # + return - 201 with the ledger row, or problem details
    resource function post po/points/adjustments(http:RequestContext ctx, http:Request req,
            @http:Payload AdjustmentBody body) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? c = cid(ctx);
        final readonly & AdjustmentBody b = body.cloneReadOnly();
        return idempotent(ctx, req, p, "/po/points/adjustments", b.toJson(),
                isolated function() returns http:StatusCodeResponse => adjustPoints(p, c, b));
    }

    # Reverses a ledger row.
    #
    # + ctx - Request context
    # + req - Request
    # + reference - Ledger reference
    # + body - Reason
    # + return - 201 with the reversal row, or problem details
    resource function post po/points/[string reference]/reverse(http:RequestContext ctx, http:Request req,
            @http:Payload ReasonBody body) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? c = cid(ctx);
        final readonly & ReasonBody b = body.cloneReadOnly();
        final string referenceFinal = reference;
        return idempotent(ctx, req, p, "/po/points/" + reference + "/reverse", b.toJson(),
                isolated function() returns http:StatusCodeResponse => reverseEntry(p, c, referenceFinal, b.reason));
    }

    // ---- S4 Recognition ----------------------------------------------------------------------------

    # Company top N, personal and My Team.
    #
    # + ctx - Request context
    # + period - `ALL` (default), `YYYY-MM`, `YYYY-Qn`
    # + ifNoneMatch - ETag from an earlier call
    # + return - The leaderboard, 304, or problem details
    resource function get leaderboard(http:RequestContext ctx, string period = "ALL",
            @http:Header {name: "If-None-Match"} string? ifNoneMatch = ())
            returns http:Response|ProblemResponse|error =>
        leaderboard(check principalOf(ctx), cid(ctx), period, ifNoneMatch);

    # People ranked within the company, a business unit or a team. Open to every employee (ADR-035).
    #
    # + ctx - Request context
    # + period - Period
    # + scope - `COMPANY` (default), `BU` or `TEAM`
    # + bu - BU name for `BU` (default the caller's own)
    # + team - Team key for `TEAM` (default the caller's own)
    # + q - Name search
    # + page - Zero-based page
    # + size - Page size
    # + return - The page, or problem details
    resource function get leaderboard/people(http:RequestContext ctx, string period = "ALL", string scope = "COMPANY",
            string? bu = (), string? team = (), string? q = (), int page = 0, int size = 25)
            returns http:Response|ProblemResponse|error =>
        okJson(peopleBoard(check principalOf(ctx), cid(ctx), period, scope, bu, team, q, page, size));

    # Teams or business units ranked against each other. Open to every employee (ADR-035).
    #
    # + ctx - Request context
    # + period - Period
    # + 'by - `TEAM` (default) or `BU`
    # + bu - Limit `TEAM` to one BU
    # + sort - `rank` (default), `name`, `points`, `participants`, `headcount`, `participation`
    # + dir - `asc` (default) or `desc`
    # + return - The board, or problem details
    resource function get leaderboard/groups(http:RequestContext ctx, string period = "ALL", string 'by = "TEAM",
            string? bu = (), string sort = "rank", string dir = "asc")
            returns http:Response|ProblemResponse|error =>
        okJson(groupBoard(cid(ctx), period, 'by, bu, sort, dir));

    # The Celebrate top three and the caller's own position. Company wide, for the scope in
    # `leaderboard.top_scope` (this calendar month by default). The monthly totals are shared by every caller
    # and kept for 2 hours.
    #
    # + ctx - Request context
    # + return - The board, or problem details
    resource function get leaderboard/top(http:RequestContext ctx) returns http:Response|ProblemResponse|error =>
        topBoard(check principalOf(ctx), cid(ctx));

    # Current employee count, overall and by business unit and team. Counted from the people directory and
    # kept for a week.
    #
    # + ctx - Request context
    # + return - The count, or problem details
    resource function get headcount(http:RequestContext ctx) returns http:Response|ProblemResponse|error =>
        okJson(headcountView(cid(ctx)));

    // ---- S6 Dashboards (PO, Marketing, SLT, Admin; ADR-036) ----------------------------------------

    # Operations board.
    #
    # + ctx - Request context
    # + return - The board, or problem details
    resource function get dashboards/operations(http:RequestContext ctx)
            returns http:Response|ProblemResponse|error => dashboardOperations(cid(ctx));

    # Campaign performance board.
    #
    # + ctx - Request context
    # + days - Look-back, 1-90 (default 30)
    # + campaignId - The campaign to detail (default: the one with the most reposts)
    # + return - The board, or problem details
    resource function get dashboards/campaigns(http:RequestContext ctx, int days = 30, string? campaignId = ())
            returns http:Response|ProblemResponse|error => dashboardCampaigns(cid(ctx), days, campaignId);

    # The raw rows behind every board for a date range, as a CSV download.
    #
    # + ctx - Request context
    # + from - First day, `YYYY-MM-DD` (UTC)
    # + to - Last day, `YYYY-MM-DD` (UTC), inclusive
    # + return - The CSV, or problem details
    resource function get dashboards/export(http:RequestContext ctx, string 'from, string to)
            returns http:Response|ProblemResponse|error => dashboardExport(cid(ctx), 'from, to);

    # One person's Post Performance: the posts they reposted, with and without their own comment.
    #
    # + ctx - Request context
    # + employeeId - Employee id
    # + return - The board, or problem details
    resource function get dashboards/people/[string employeeId](http:RequestContext ctx)
            returns http:Response|ProblemResponse|error => dashboardPerson(cid(ctx), employeeId);

    # Participation funnel numbers.
    #
    # + ctx - Request context
    # + return - The board, or problem details
    resource function get dashboards/participation(http:RequestContext ctx)
            returns http:Response|ProblemResponse|error => dashboardParticipation(cid(ctx));

    # At a glance.
    #
    # + ctx - Request context
    # + return - The board, or problem details
    resource function get dashboards/glance(http:RequestContext ctx)
            returns http:Response|ProblemResponse|error => dashboardGlance(cid(ctx));

    # Scorecard.
    #
    # + ctx - Request context
    # + return - The board, or problem details
    resource function get dashboards/scorecard(http:RequestContext ctx)
            returns http:Response|ProblemResponse|error => dashboardScorecard(cid(ctx));

    # Own points, rank and monthly history.
    #
    # + ctx - Request context
    # + period - Period
    # + return - Points, or problem details
    resource function get me/points(http:RequestContext ctx, string period = "ALL")
            returns http:Response|ProblemResponse|error =>
        okJson(myPoints(check principalOf(ctx), cid(ctx), period));

    # Team page.
    #
    # + ctx - Request context
    # + period - Period
    # + q - Name search
    # + sort - `rank`, `points`, `name`
    # + page - Zero-based page
    # + size - Page size
    # + return - The page, or problem details
    resource function get team(http:RequestContext ctx, string period = "ALL", string? q = (), string sort = "rank",
            int page = 0, int size = 25) returns http:Response|ProblemResponse|error =>
        // Like every read with a body past the JSON writer's 512-char window (M11b), through `jsonBody`:
        // same bytes as a plain `json` return, without the JDK 21 buffer growth.
        okJson(teamView(check principalOf(ctx), cid(ctx), period, q, sort, page, size));

    # One person's points history.
    #
    # + ctx - Request context
    # + employeeId - Employee
    # + page - Zero-based page
    # + size - Page size
    # + return - History, or problem details
    resource function get team/[string employeeId]/history(http:RequestContext ctx, int page = 0, int size = 25)
            returns http:Response|ProblemResponse|error =>
        okJson(history(check principalOf(ctx), cid(ctx), employeeId, page, size));

    # PO dashboard.
    #
    # + ctx - Request context
    # + month - `YYYY-MM` (default current month, UTC)
    # + return - The tiles, or problem details
    resource function get po/dashboard(http:RequestContext ctx, string? month = ()) returns http:Response|ProblemResponse =>
        poDashboard(cid(ctx), month);

    // ---- S5 Admin ----------------------------------------------------------------------------------

    # Club cards.
    #
    # + ctx - Request context
    # + status - `FAILED` (default), `QUEUED`, `SENT`, `ALL`
    # + return - Announcements, or problem details
    resource function get admin/announcements(http:RequestContext ctx, string status = "FAILED")
            returns http:Response|ProblemResponse|error =>
        okJson(listAnnouncements(check principalOf(ctx), cid(ctx), status));

    # Re-queues a failed Club card.
    #
    # + ctx - Request context
    # + req - Request
    # + id - Campaign id
    # + return - 202, or problem details
    resource function post admin/announcements/[string id]/'retry(http:RequestContext ctx, http:Request req)
            returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? c = cid(ctx);
        final string idFinal = id;
        return idempotent(ctx, req, p, "/admin/announcements/" + id + "/retry", (),
                isolated function() returns http:StatusCodeResponse => retryAnnouncement(p, c, idFinal));
    }

    # Settings.
    #
    # + ctx - Request context
    # + return - Settings, or problem details
    resource function get admin/settings(http:RequestContext ctx) returns http:Response|ProblemResponse|error {
        json|error body = settingsBody();
        return okJson(body is error ? failure(body, cid(ctx), "List settings") : body);
    }

    # Changes settings.
    #
    # + ctx - Request context
    # + body - Changes
    # + return - Settings after the change, or problem details
    resource function put admin/settings(http:RequestContext ctx, @http:Payload SettingChangesBody body)
            returns http:Response|ProblemResponse|error =>
        okJson(changeSettings(check principalOf(ctx), cid(ctx), body));

    # Converges the scheduler jobs to the schedule settings (ADR-026).
    #
    # + ctx - Request context
    # + req - Request
    # + return - 200 with the jobs, or problem details (503 when the scheduler can't be reached)
    resource function post admin/scheduler/sync(http:RequestContext ctx, http:Request req) returns http:Response|error {
        final auth:Principal & readonly p = (check principalOf(ctx)).cloneReadOnly();
        final string? c = cid(ctx);
        return idempotent(ctx, req, p, "/admin/scheduler/sync", (),
                isolated function() returns http:StatusCodeResponse => syncSchedulerNow(p, c));
    }
}

# Creates or refreshes the caller's `identity.employee` row from the token claims (claims, not
# userinfo: ADR-022).
#
# + principal - Verified caller
# + now - Current time
# + return - The stored employee, or an error
isolated function upsertEmployee(auth:Principal principal, time:Utc now) returns identity:Employee|error {
    identity:EmployeeRepository repo = check employeeRepository();
    identity:Employee? existing = check repo.findById(principal.employeeId);
    identity:Employee employee = check identity:recordSeen(existing,
            {sub: principal.employeeId, email: principal.email, name: principal.displayName}, now);
    check repo.upsert(employee);
    return employee;
}

isolated function findConnection(store:Actor actor, types:EmployeeId employeeId) returns connection:LinkedInConnection|error? {
    connection:ConnectionRepository repo = check connectionRepository(actor);
    return repo.findByEmployee(employeeId, types:LINKEDIN);
}

# LinkedIn block for `GET /me`.
#
# + linked - Connection, if any
# + now - Current time
# + return - Status and expiry
isolated function linkedInOf(connection:LinkedInConnection? linked, time:Utc now) returns MeLinkedIn {
    if linked is () {
        return {status: NOT_CONNECTED, expiresAt: ()};
    }
    connection:ConnectionStatus status = connection:connectionStatus(linked, now);
    return {
        status,
        expiresAt: status == connection:REMOVED ? () : time:utcToString(linked.accessExpiresAt)
    };
}

# A campaign read or write as JSON for `okJson`.
#
# + result - Campaign or problem details
# + return - JSON or the problem details
isolated function campaignJson(CampaignDto|ProblemResponse result) returns json|ProblemResponse =>
    result is ProblemResponse ? result : result.toJson();

isolated function getRules(auth:Principal p, string? correlationId) returns scoring:PointRule[]|error =>
    (check pointRuleRepository(actorOf(p, correlationId))).all();

isolated function jwksBreaker() returns BreakerReport {
    http:CircuitState state = verifier.keysBreakerState();
    return state == http:CB_OPEN_STATE ? "OPEN" : state == http:CB_HALF_OPEN_STATE ? "HALF_OPEN" : "CLOSED";
}
