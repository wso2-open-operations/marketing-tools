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

// `POST /engagement/sync` (phase 4): the Community Management engagement sync. Off unless `engagement.sync_enabled`
// is true. Loads the page connection, refreshes its token near expiry, then runs `sharing:syncEngagement` with the
// page token: reactions, comments and native reshares on the page's open campaign posts become engagements with
// their `EngagementRecorded` event, which the next `POST /runs` scores. The rules live in amplify_domain.sharing;
// this file only wires LinkedIn and the database to its ports. Never logs tokens or member URNs.

import amplify_common.crypto;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

# Advisory lock key for "one engagement sync at a time" across replicas ("engs").
const int ENGAGEMENT_SYNC_LOCK_KEY = 1701734259;

# Default `engagement.daily_call_budget` when the setting is missing.
const int DEFAULT_DAILY_CALL_BUDGET = 450;

# Elements per Community Management call.
configurable int engagementPageSize = 50;
# Most pages per post and finder in one sync run.
configurable int engagementMaxPagesPerFinder = 10;

# Returned when another sync holds the lock.
type EngagementSyncSkipped record {|
    # `SKIPPED`
    string status = "SKIPPED";
    # `SYNC_IN_PROGRESS`
    string reason = "SYNC_IN_PROGRESS";
|};

# What `POST /engagement/sync` did.
type EngagementSyncResult record {|
    # `OFF` (setting false), `NOT_CONFIGURED` (no Community Management client or token keys), `NOT_CONNECTED` (no
    # page connection), `NEEDS_RECONNECT` (token expired or refused), else the sync's own status: `DONE`,
    # `BUDGET_REACHED`, `RATE_LIMITED`, `UNAVAILABLE`, `UNAUTHORIZED`, `REJECTED`
    string status;
    # The access token was refreshed first
    boolean tokenRefreshed = false;
    # Counts, when the sync ran
    sharing:SyncReport? sync = ();
|};

# The sync settings (`config_app_setting`).
type EngagementSettings record {|
    # `engagement.sync_enabled`
    boolean enabled = false;
    # `engagement.daily_call_budget`
    int dailyBudget = DEFAULT_DAILY_CALL_BUDGET;
|};

# What the sync needs from the database (a port, so the tests run on fakes).
type EngagementStore isolated object {
    isolated function settings() returns EngagementSettings|error;
    isolated function orgConnection() returns connection:OrgConnection|error?;
    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error?;
    isolated function saveOrg(connection:OrgConnectionChange change, int expectedVersion) returns error?;
    isolated function syncStore(string orgUrn) returns sharing:SyncStore;
};

# One sync run.
#
# + st - Database side
# + community - Community Management client, `()` when not configured
# + cipher - Token key ring, `()` when not configured
# + now - Run time
# + return - What was done, or a database error
isolated function runEngagementSync(EngagementStore st, linkedin:CommunityPort? community, crypto:TokenCipher? cipher,
        time:Utc now) returns EngagementSyncResult|error {
    EngagementSettings settings = check st.settings();
    if !settings.enabled {
        return {status: "OFF"};
    }
    if community is () || cipher is () {
        return {status: "NOT_CONFIGURED"};
    }
    connection:OrgConnection? found = check st.orgConnection();
    if found is () {
        return {status: "NOT_CONNECTED"};
    }
    connection:OrgConnection org = found;
    if connection:orgStatus(org, now) != connection:PAGE_CONNECTED {
        return {status: "NEEDS_RECONNECT"};
    }
    boolean refreshed = false;
    if connection:needsRefresh(org, now) {
        [connection:OrgConnection, boolean]|string renewed = check refreshPageToken(st, community, cipher, org, now);
        if renewed is string {
            return {status: renewed};
        }
        [org, refreshed] = renewed;
    }
    connection:TokenRef? ref = org.accessToken;
    connection:StoredToken? stored = ref is () ? () : check st.token(ref);
    if stored is () {
        return {status: "NEEDS_RECONNECT"};
    }
    // Plaintext lives only in this frame and the source, only for the run. Never logged.
    string|error bearer = connection:openToken(cipher, stored);
    if bearer is error {
        log:printError("Page token could not be decrypted (key ring?)", bearer);
        return {status: "NEEDS_RECONNECT", tokenRefreshed: refreshed};
    }
    sharing:SyncReport report = check sharing:syncEngagement(new CommunitySource(community, bearer, org.orgUrn),
            st.syncStore(org.orgUrn), {
                pageUrn: org.orgUrn,
                dailyBudget: settings.dailyBudget,
                pageSize: engagementPageSize,
                maxPagesPerFinder: engagementMaxPagesPerFinder
            }, now);
    return {status: report.status, tokenRefreshed: refreshed, sync: report};
}

# Refreshes the page's access token with its refresh token and stores the new rows. A refresh LinkedIn refuses
# while the old access token still works is logged and the run goes on with the old token.
#
# + st - Database side
# + community - Community Management client
# + cipher - Token key ring
# + org - Page connection
# + now - Current time
# + return - The connection to use and whether it was refreshed (false: going on with the old token), a status to
# stop with, or a database error
isolated function refreshPageToken(EngagementStore st, linkedin:CommunityPort community, crypto:TokenCipher cipher,
        connection:OrgConnection org, time:Utc now) returns [connection:OrgConnection, boolean]|string|error {
    boolean accessValid = time:utcDiffSeconds(org.accessExpiresAt, now) > 60d;
    connection:TokenRef? ref = org.refreshToken;
    connection:StoredToken? stored = ref is () ? () : check st.token(ref);
    string|error refreshToken = stored is () ? error("no refresh token row") : connection:openToken(cipher, stored);
    if refreshToken is error {
        log:printWarn("Page refresh token unusable", reason = refreshToken.message());
        return accessValid ? [org, false] : "NEEDS_RECONNECT";
    }
    linkedin:TokenGrant|linkedin:ProviderError grant = community.refresh(refreshToken);
    if grant is linkedin:ProviderError {
        log:printWarn("Page token refresh failed", errorCode = grant.detail().code);
        if accessValid {
            return [org, false];
        }
        return grant.detail().code == linkedin:UNAVAILABLE || grant.detail().code == linkedin:RATE_LIMITED
            ? "UNAVAILABLE" : "NEEDS_RECONNECT";
    }
    connection:StoredToken access = check connection:sealOrgToken(cipher, grant.accessToken, org.orgUrn, "ACCESS",
            time:utcAddSeconds(now, <decimal>grant.expiresInSeconds), now);
    connection:StoredToken? newRefresh = ();
    string? rt = grant.refreshToken;
    int? rtSeconds = grant.refreshExpiresInSeconds;
    if rt is string {
        time:Utc? until = rtSeconds is int ? time:utcAddSeconds(now, <decimal>rtSeconds) : org.refreshExpiresAt;
        if until is time:Utc {
            newRefresh = check connection:sealOrgToken(cipher, rt, org.orgUrn, "REFRESH", until, now);
        }
    }
    connection:OrgConnectionChange change = check connection:refreshOrg(org, access, newRefresh);
    check st.saveOrg(change, org.version);
    log:printInfo("Page token refreshed", accessExpiresAt = time:utcToString(change.connection.accessExpiresAt));
    return [change.connection, true];
}

# `sharing:EngagementSource` over the Community Management adapter, with the page token.
isolated class CommunitySource {
    *sharing:EngagementSource;

    private final linkedin:CommunityPort community;
    private final string bearer;
    private final string orgUrn;

    isolated function init(linkedin:CommunityPort community, string bearer, string orgUrn) {
        self.community = community;
        self.bearer = bearer;
        self.orgUrn = orgUrn;
    }

    public isolated function reactions(string targetUrn, int 'start, int count)
            returns sharing:ObservedPage|sharing:SourceError {
        linkedin:ReactionPage|linkedin:ProviderError page = self.community.listReactions(self.bearer, targetUrn, 'start,
                count);
        if page is linkedin:ProviderError {
            return sourceError(page);
        }
        return {
            items: from linkedin:Reaction r in page.items
                select {kind: "REACTION", actorUrn: r.actorUrn, targetUrn: r.rootUrn,
                    occurredAt: sharing:fromEpochMillis(r.createdAtMs)},
            fetched: page.fetched
        };
    }

    public isolated function comments(string targetUrn, int 'start, int count)
            returns sharing:ObservedPage|sharing:SourceError {
        linkedin:CommentPage|linkedin:ProviderError page = self.community.listComments(self.bearer, targetUrn, 'start,
                count);
        if page is linkedin:ProviderError {
            return sourceError(page);
        }
        return {
            items: from linkedin:Comment c in page.items
                select {kind: "COMMENT", actorUrn: c.actorUrn, targetUrn: c.objectUrn, activityUrn: c.commentUrn,
                    occurredAt: sharing:fromEpochMillis(c.createdAtMs)},
            fetched: page.fetched
        };
    }

    public isolated function reshares(int startMs, int endMs, int 'start, int count)
            returns sharing:ObservedPage|sharing:SourceError {
        linkedin:NotificationPage|linkedin:ProviderError page = self.community.listShareNotifications(self.bearer,
                self.orgUrn, startMs, endMs, 'start, count);
        if page is linkedin:ProviderError {
            return sourceError(page);
        }
        return {
            // A mention of the page is not a reshare of a campaign post: only `SHARE` counts.
            items: from linkedin:ShareNotification n in page.items
                where n.action == "SHARE"
                select {kind: "RESHARE", actorUrn: n.actorUrn, targetUrn: n.sourcePostUrn, activityUrn: n.activityUrn,
                    hasCommentary: n.hasCommentary, occurredAt: sharing:fromEpochMillis(n.occurredAtMs)},
            fetched: page.fetched
        };
    }
}

# Why a provider failure stops the sync.
#
# + err - Provider error
# + return - The source error
isolated function sourceError(linkedin:ProviderError err) returns sharing:SourceError {
    linkedin:ProviderErrorCode code = err.detail().code;
    sharing:SourceStop reason = code == linkedin:RATE_LIMITED ? "RATE_LIMITED"
        : code == linkedin:UNAUTHORIZED || code == linkedin:FORBIDDEN ? "UNAUTHORIZED"
        : code == linkedin:UNAVAILABLE || code == linkedin:OUTCOME_UNKNOWN ? "UNAVAILABLE"
        : "REJECTED";
    log:printWarn("Engagement sync stopped by LinkedIn", errorCode = code, httpStatus = err.detail().httpStatus);
    return error sharing:SourceError("LinkedIn stopped the sync", reason = reason);
}

# The engagement settings from rows; missing or malformed values keep the defaults (off, 450).
#
# + rows - Setting rows
# + return - Settings
isolated function toEngagementSettings(store:Setting[] rows) returns EngagementSettings {
    EngagementSettings s = {};
    foreach store:Setting row in rows {
        json v = row.value;
        if row.key == "engagement.sync_enabled" {
            s.enabled = v == true;
        } else if row.key == "engagement.daily_call_budget" {
            s.dailyBudget = v is int && v >= 0 ? v : s.dailyBudget;
        }
    }
    return s;
}

// ---- PostgreSQL -----------------------------------------------------------------------------------

# `EngagementStore` over the sync's own single-connection client.
isolated class PgEngagementStore {
    *EngagementStore;

    private final postgresql:Client db;

    isolated function init(postgresql:Client db) {
        self.db = db;
    }

    isolated function settings() returns EngagementSettings|error => toEngagementSettings(check store:readSettings(self.db));

    isolated function orgConnection() returns connection:OrgConnection|error? =>
        (new connection:PgOrgConnectionRepository(self.db)).findActive(types:LINKEDIN);

    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error? =>
        (new connection:PgTokenRepository(self.db)).find(ref);

    isolated function saveOrg(connection:OrgConnectionChange change, int expectedVersion) returns error? =>
        (new connection:PgOrgConnectionRepository(self.db)).save(change, expectedVersion);

    isolated function syncStore(string orgUrn) returns sharing:SyncStore => new PgSyncStore(self.db, orgUrn);
}

# `sharing:SyncStore` composed from the contexts that own each table: campaign (open posts), connection (member
# matching), sharing (cursors, budget, engagements, native intents).
isolated class PgSyncStore {
    *sharing:SyncStore;

    private final postgresql:Client db;
    private final string orgUrn;
    private final sharing:PgEngagementSyncRepository repo;

    isolated function init(postgresql:Client db, string orgUrn) {
        self.db = db;
        self.orgUrn = orgUrn;
        self.repo = new (db);
    }

    public isolated function openCampaigns(time:Utc now) returns sharing:SyncCampaign[]|error {
        campaign:OpenCampaign[] open = check campaign:openCampaignsOf(self.db, self.orgUrn, now);
        return from campaign:OpenCampaign c in open
            select {id: c.id, resourceUrn: c.resourceUrn, opensAt: c.opensAt, closesAt: c.closesAt};
    }

    public isolated function employeesOf(string[] memberUrns) returns map<types:EmployeeId>|error =>
        connection:employeesOfMembers(self.db, memberUrns);

    public isolated function cursor(string resourceUrn, sharing:SyncEndpoint endpoint) returns string|error? =>
        self.repo.cursor(resourceUrn, endpoint);

    public isolated function saveCursor(string resourceUrn, sharing:SyncEndpoint endpoint, string cursor, time:Utc now)
            returns error? => self.repo.saveCursor(resourceUrn, endpoint, cursor, now);

    public isolated function takeCall(time:Utc now, int budget) returns boolean|error => self.repo.takeCall(now, budget);

    public isolated function recordSynced(sharing:Engagement engagement, time:Utc now) returns boolean|error =>
        self.repo.recordSynced(engagement, now);
}

# Logs a finished sync: counts only.
#
# + result - The result
# + correlationId - Trigger correlation id
isolated function logEngagementSync(EngagementSyncResult result, string? correlationId) {
    sharing:SyncReport? r = result.sync;
    if r is () {
        log:printInfo("Engagement sync", status = result.status, correlationId = correlationId);
        return;
    }
    log:printInfo("Engagement sync", status = result.status, tokenRefreshed = result.tokenRefreshed,
            campaigns = r.campaigns, calls = r.calls, reactions = r.reactions, comments = r.comments,
            reposts = r.reposts, alreadyRecorded = r.alreadyRecorded, dropped = r.dropped, correlationId = correlationId);
}

# Breaker state of the Community Management REST client, for `/ready` and the gauge.
#
# + return - The state, or `NOT_CONFIGURED`
isolated function communityBreaker() returns string {
    linkedin:CommunityAdapter? c = communityAdapter;
    return c is () ? "NOT_CONFIGURED" : c.breakers()["api"] ?: "CLOSED";
}
