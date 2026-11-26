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


// `POST /reach/refresh` (#1781): reads the impressions and members reached of the in-app shares of employees who
// connected Reach, with each employee's own Reach token (Community Management app, `r_member_postAnalytics`). Off
// unless `reach.enabled` is true. The rules live in amplify_domain.sharing (`refreshReach`); this file wires LinkedIn,
// the Reach tokens and the database to its ports. Calls count against `engagement.daily_call_budget`, shared with the
// engagement sync. Never logs tokens or post URNs.

import amplify_common.crypto;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

# Most posts one refresh reads.
configurable int reachMaxPostsPerRun = 500;

# Returned when another refresh holds the lock.
type ReachSkipped record {|
    # `SKIPPED`
    string status = "SKIPPED";
    # `REACH_IN_PROGRESS`
    string reason = "REACH_IN_PROGRESS";
|};

# What `POST /reach/refresh` did.
type ReachRefreshResult record {|
    # `OFF` (setting false), `NOT_CONFIGURED` (no Community Management client or token keys), `NO_CONSENT` (nobody
    # connected Reach), else the refresh's own status: `DONE`, `BUDGET_REACHED`, `POST_LIMIT`, `RATE_LIMITED`,
    # `UNAVAILABLE`
    string status;
    # Employees with a Reach connection
    int consenting = 0;
    # Reach tokens refreshed on the way
    int tokensRefreshed = 0;
    # Counts, when the refresh ran
    sharing:ReachReport? report = ();
|};

# The reach settings (`config_app_setting`).
type ReachSettings record {|
    # `reach.enabled`
    boolean enabled = false;
    # `reach.window_days`
    int windowDays = 30;
    # `engagement.daily_call_budget` (shared with the engagement sync)
    int dailyBudget = DEFAULT_DAILY_CALL_BUDGET;
|};

# What the refresh needs from the database (a port, so the tests run on fakes).
type ReachJobStore isolated object {
    isolated function settings() returns ReachSettings|error;
    isolated function connections() returns connection:ReachConnection[]|error;
    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error?;
    isolated function saveReach(connection:ReachChange change, int expectedVersion) returns error?;
    isolated function reachStore(types:EmployeeId[] employeeIds) returns sharing:ReachStore;
};

# One refresh.
#
# + st - Database side
# + analytics - The Community Management client, `()` when not configured
# + cipher - Token key ring, `()` when not configured
# + maxPosts - Most posts in the run
# + now - Run time
# + return - What was done, or a database error
isolated function runReachRefresh(ReachJobStore st, linkedin:MemberAnalyticsPort? analytics, crypto:TokenCipher? cipher,
        int maxPosts, time:Utc now) returns ReachRefreshResult|error {
    ReachSettings settings = check st.settings();
    if !settings.enabled {
        return {status: "OFF"};
    }
    if analytics is () || cipher is () {
        return {status: "NOT_CONFIGURED"};
    }
    connection:ReachConnection[] consenting = check st.connections();
    if consenting.length() == 0 {
        return {status: "NO_CONSENT"};
    }
    ReachTokenReader reader = new (st, analytics, cipher, consenting, now);
    types:EmployeeId[] ids = from connection:ReachConnection c in consenting
        select c.employeeId;
    sharing:ReachReport report = check sharing:refreshReach(st.reachStore(ids), reader,
            {windowDays: settings.windowDays, dailyBudget: settings.dailyBudget, maxPosts}, now);
    return {status: report.status, consenting: consenting.length(), tokensRefreshed: reader.refreshed(), report};
}

# `sharing:ReachReader` over the analytics port: opens each employee's Reach token once (refreshing it near expiry)
# and reads the two metrics. Plaintext tokens live only in this object, only for the run.
isolated class ReachTokenReader {
    *sharing:ReachReader;

    private final ReachJobStore st;
    private final linkedin:MemberAnalyticsPort analytics;
    private final crypto:TokenCipher cipher;
    private final map<connection:ReachConnection> & readonly byEmployee;
    private final time:Utc & readonly now;
    private final map<string|sharing:ReachSkip> bearers = {};
    private int refreshCount = 0;

    isolated function init(ReachJobStore st, linkedin:MemberAnalyticsPort analytics, crypto:TokenCipher cipher,
            connection:ReachConnection[] consenting, time:Utc now) {
        self.st = st;
        self.analytics = analytics;
        self.cipher = cipher;
        map<connection:ReachConnection> m = {};
        foreach connection:ReachConnection c in consenting {
            m[c.employeeId] = c;
        }
        self.byEmployee = m.cloneReadOnly();
        self.now = now.cloneReadOnly();
    }

    public isolated function read(sharing:ReachTarget target) returns sharing:ReachReading|sharing:ReachSkip|sharing:SourceError {
        string|sharing:ReachSkip|error bearer = self.bearerOf(target.employeeId);
        if bearer is error {
            log:printError("Reach token could not be opened", bearer);
            return "NO_TOKEN";
        }
        if bearer is sharing:ReachSkip {
            return bearer;
        }
        int|linkedin:ProviderError impressions = self.analytics.memberPostMetric(bearer, target.postUrn,
                linkedin:IMPRESSION);
        if impressions is linkedin:ProviderError {
            return reachSourceError(impressions);
        }
        int|linkedin:ProviderError reached = self.analytics.memberPostMetric(bearer, target.postUrn,
                linkedin:MEMBERS_REACHED);
        if reached is linkedin:ProviderError {
            return reachSourceError(reached);
        }
        return {impressions, membersReached: reached};
    }

    isolated function refreshed() returns int {
        lock {
            return self.refreshCount;
        }
    }

    private isolated function bearerOf(types:EmployeeId employeeId) returns string|sharing:ReachSkip|error {
        lock {
            string|sharing:ReachSkip? cached = self.bearers[employeeId];
            if cached !is () {
                return cached;
            }
        }
        string|sharing:ReachSkip opened = check self.open(employeeId);
        lock {
            self.bearers[employeeId] = opened;
        }
        return opened;
    }

    private isolated function open(types:EmployeeId employeeId) returns string|sharing:ReachSkip|error {
        connection:ReachConnection? found = self.byEmployee[employeeId];
        if found is () || connection:reachStatus(found, self.now) != connection:REACH_CONNECTED {
            return "NO_TOKEN";
        }
        connection:ReachConnection c = found;
        if connection:needsReachRefresh(c, self.now) {
            connection:ReachConnection|sharing:ReachSkip renewed = check self.renew(c);
            if renewed is connection:ReachConnection {
                c = renewed;
            } else if time:utcDiffSeconds(c.accessExpiresAt, self.now) <= 60d {
                return renewed;
            }
        }
        connection:StoredToken? stored = check self.st.token(c.accessToken);
        if stored is () {
            return "NO_TOKEN";
        }
        string|error bearer = connection:openToken(self.cipher, stored);
        if bearer is error {
            log:printError("Reach token could not be decrypted (key ring?)", bearer);
            return "NO_TOKEN";
        }
        return bearer;
    }

    private isolated function renew(connection:ReachConnection c) returns connection:ReachConnection|sharing:ReachSkip|error {
        connection:TokenRef? ref = c.refreshToken;
        connection:StoredToken? stored = ref is () ? () : check self.st.token(ref);
        string|error refreshToken = stored is () ? error("no refresh token row") : connection:openToken(self.cipher, stored);
        if refreshToken is error {
            log:printWarn("Reach refresh token unusable", reason = refreshToken.message());
            return "NO_TOKEN";
        }
        linkedin:TokenGrant|linkedin:ProviderError grant = self.analytics.refresh(refreshToken);
        if grant is linkedin:ProviderError {
            log:printWarn("Reach token refresh failed", errorCode = grant.detail().code);
            return "NO_TOKEN";
        }
        connection:StoredToken access = check connection:sealReachToken(self.cipher, grant.accessToken, c.employeeId,
                "ACCESS", time:utcAddSeconds(self.now, <decimal>grant.expiresInSeconds), self.now);
        connection:StoredToken? newRefresh = ();
        string? rt = grant.refreshToken;
        int? rtSeconds = grant.refreshExpiresInSeconds;
        if rt is string {
            time:Utc? until = rtSeconds is int ? time:utcAddSeconds(self.now, <decimal>rtSeconds) : c.refreshExpiresAt;
            if until is time:Utc {
                newRefresh = check connection:sealReachToken(self.cipher, rt, c.employeeId, "REFRESH", until, self.now);
            }
        }
        connection:ReachChange change = connection:refreshReach(c, access, newRefresh);
        check self.st.saveReach(change, c.version);
        lock {
            self.refreshCount += 1;
        }
        return change.connection;
    }
}

# How a provider failure maps onto the refresh: a rate limit or an outage stops it; a refused token skips the employee;
# anything else skips the post.
#
# + err - Provider error
# + return - The source error
isolated function reachSourceError(linkedin:ProviderError err) returns sharing:SourceError {
    linkedin:ProviderErrorCode code = err.detail().code;
    sharing:SourceStop reason = code == linkedin:RATE_LIMITED ? "RATE_LIMITED"
        : code == linkedin:UNAUTHORIZED ? "UNAUTHORIZED"
        : code == linkedin:UNAVAILABLE || code == linkedin:OUTCOME_UNKNOWN ? "UNAVAILABLE"
        : "REJECTED";
    log:printWarn("Reach read refused by LinkedIn", errorCode = code, httpStatus = err.detail().httpStatus);
    return error sharing:SourceError("LinkedIn refused the reach read", reason = reason);
}

# The reach settings from rows; missing or malformed values keep the defaults (off, 30 days, 450 calls).
#
# + rows - Setting rows
# + return - Settings
isolated function toReachSettings(store:Setting[] rows) returns ReachSettings {
    ReachSettings s = {};
    foreach store:Setting row in rows {
        json v = row.value;
        if row.key == "reach.enabled" {
            s.enabled = v == true;
        } else if row.key == "reach.window_days" {
            s.windowDays = v is int && v > 0 && v <= 90 ? v : s.windowDays;
        } else if row.key == "engagement.daily_call_budget" {
            s.dailyBudget = v is int && v >= 0 ? v : s.dailyBudget;
        }
    }
    return s;
}

// ---- PostgreSQL -----------------------------------------------------------------------------------

# `ReachJobStore` over the refresh's own single-connection client.
isolated class PgReachJobStore {
    *ReachJobStore;

    private final postgresql:Client db;

    isolated function init(postgresql:Client db) {
        self.db = db;
    }

    isolated function settings() returns ReachSettings|error => toReachSettings(check store:readSettings(self.db));

    isolated function connections() returns connection:ReachConnection[]|error {
        connection:PgReachConnectionRepository repo = new (self.db);
        return repo.allConnections();
    }

    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error? =>
        (new connection:PgTokenRepository(self.db)).find(ref);

    isolated function saveReach(connection:ReachChange change, int expectedVersion) returns error? =>
        (new connection:PgReachConnectionRepository(self.db)).save(change, expectedVersion);

    isolated function reachStore(types:EmployeeId[] employeeIds) returns sharing:ReachStore =>
        new PgReachStore(self.db, employeeIds);
}

# `sharing:ReachStore` composed from the sharing tables (shares, readings, the call counter).
isolated class PgReachStore {
    *sharing:ReachStore;

    private final sharing:PgReachRepository reach;
    private final sharing:PgEngagementSyncRepository usage;
    private final readonly & types:EmployeeId[] employeeIds;

    isolated function init(postgresql:Client db, types:EmployeeId[] employeeIds) {
        self.reach = new (db);
        self.usage = new (db);
        self.employeeIds = employeeIds.cloneReadOnly();
    }

    public isolated function targets(time:Utc since, string today) returns sharing:ReachTarget[]|error =>
        self.reach.sharesToMeasure(self.employeeIds, since, today);

    public isolated function takeCall(time:Utc now, int budget) returns boolean|error => self.usage.takeCall(now, budget);

    public isolated function saveReading(sharing:ReachTarget target, sharing:ReachReading reading, time:Utc now)
            returns error? => self.reach.saveReading(target, reading, now);
}

# Logs a finished refresh: counts only.
#
# + result - The result
# + correlationId - Trigger correlation id
isolated function logReachRefresh(ReachRefreshResult result, string? correlationId) {
    sharing:ReachReport? r = result.report;
    if r is () {
        log:printInfo("Reach refresh", status = result.status, correlationId = correlationId);
        return;
    }
    log:printInfo("Reach refresh", status = result.status, consenting = result.consenting,
            tokensRefreshed = result.tokensRefreshed, targets = r.targets, measured = r.measured,
            skippedNoToken = r.skippedNoToken, skippedNotReadable = r.skippedNotReadable, calls = r.calls,
            correlationId = correlationId);
}
