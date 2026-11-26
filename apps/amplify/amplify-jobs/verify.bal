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

// `POST /coins/verify` (Task #1767, V027, ADR-048 amendment): the pre-coin verification. Before the conversion, every
// HELD engagement row it could take is checked on LinkedIn again: still there -> VERIFIED (the conversion takes a row
// only while that is within `coin.verify_max_age_hours`), gone -> reversed "No longer on LinkedIn", can't be checked
// -> action required for the PO team. The rules live in amplify_domain.scoring (`verifyForCoins`); this file is the
// `EngagementChecker` behind it, built from the contexts that own each table (ADR-005): sharing (the engagement, the
// record of each check, the call budgets), connection (the employee's and the page's tokens), and LinkedIn.
//
// Which read per row:
//   in-app share or native reshare  GET /rest/posts/{urn} with the employee's own token (Share on LinkedIn); when the
//                                   employee has none, or it may not read the post, with the page token
//   reaction                        GET /rest/reactions/(actor:…,entity:…) with the page token
//   comment                         GET /rest/socialActions/{post}/comments/{id} with the page token
// Budgets per UTC day (`sharing_api_usage`): page-token reads share `engagement.daily_call_budget` with the engagement
// sync; member-token reads have `coin.verify_member_daily_call_budget`. A spent budget, a 429 or LinkedIn being down
// stops the run; the rows not reached are not converted until a later run checks them. The page token is not
// refreshed here (the engagement sync does that). Never logs tokens or member URNs.

import amplify_common.crypto;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

# Stop checking after this many seconds (`PARTIAL`); the next run carries on. Below the scheduler's
# `coinsVerifyDeadlineSeconds` (amplify-api, 600).
configurable decimal coinsVerifyMaxSeconds = 540;
# Ledger rows read per batch.
configurable int coinsVerifyBatchSize = 200;

# Default `coin.verify_member_daily_call_budget` when the setting is missing.
const int DEFAULT_MEMBER_DAILY_CALL_BUDGET = 1000;

# The verification settings (`config_app_setting`).
type VerifySettings record {|
    # `coin.wallets_enabled`: no conversion, no verification
    boolean walletsEnabled = false;
    # `coin.verify_max_age_hours`
    int maxAgeHours = scoring:DEFAULT_VERIFY_MAX_AGE_HOURS;
    # `engagement.daily_call_budget`: page-token calls per UTC day, with the engagement sync
    int pageBudget = DEFAULT_DAILY_CALL_BUDGET;
    # `coin.verify_member_daily_call_budget`: member-token calls per UTC day
    int memberBudget = DEFAULT_MEMBER_DAILY_CALL_BUDGET;
|};

# Returned when the verification did not run: a Coins job holds the lock (`COINS_IN_PROGRESS`), wallets are off
# (`WALLETS_OFF`), or LinkedIn or the token keys are not configured (`NOT_CONFIGURED`).
type VerifySkipped record {|
    # `SKIPPED`
    string status = "SKIPPED";
    # Why
    string reason;
|};

# What the verification needs from the database (a port, so the tests run on fakes).
type VerifyStore isolated object {
    isolated function settings() returns VerifySettings|error;
    isolated function ledger() returns scoring:VerificationRepository;
    isolated function engagement(string id) returns sharing:Engagement|error?;
    isolated function recordCheck(string engagementId, types:ProviderApi providerApi, boolean stillExists, time:Utc now)
        returns error?;
    isolated function takeCall(types:ProviderApi providerApi, time:Utc now, int budget) returns boolean|error;
    isolated function memberConnection(types:EmployeeId employeeId) returns connection:LinkedInConnection|error?;
    isolated function orgConnection() returns connection:OrgConnection|error?;
    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error?;
};

# A bearer token, or why there is none (`NO_TOKEN`, `TOKEN_EXPIRED`).
type Bearer string|record {|string reason;|};

# One verification run.
#
# + st - Database side
# + member - Share on LinkedIn adapter (member-token reads), `()` when not configured
# + page - Community Management adapter (page-token reads), `()` when not configured
# + cipher - Token key ring, `()` when not configured
# + correlationId - Trigger correlation id, written on the reversals
# + now - Run time
# + return - What was done, a skip, or a database error
isolated function runCoinVerification(VerifyStore st, linkedin:PostPresencePort? member,
        linkedin:CommunityPresencePort? page, crypto:TokenCipher? cipher, string? correlationId, time:Utc now)
        returns scoring:VerifyReport|VerifySkipped|error {
    VerifySettings settings = check st.settings();
    if !settings.walletsEnabled {
        return <VerifySkipped>{reason: scoring:RUN_WALLETS_OFF};
    }
    if member is () || cipher is () {
        // A configuration gap is not the rows' fault: flagging them all for the PO would be wrong.
        return <VerifySkipped>{reason: "NOT_CONFIGURED"};
    }
    Bearer pageBearer = page is () ? {reason: scoring:VERIFY_NO_TOKEN} : check openPageBearer(st, cipher, now);
    LinkedInChecker checker = new (st, member, page, cipher, pageBearer, settings);
    return scoring:verifyForCoins(st.ledger(), checker, {
        maxAgeHours: settings.maxAgeHours,
        maxSeconds: coinsVerifyMaxSeconds,
        batchSize: coinsVerifyBatchSize,
        correlationId
    }, now);
}

# The page's access token for this run, or why there is none.
#
# + st - Database side
# + cipher - Token key ring
# + now - Run time
# + return - The bearer or a reason, or a database error
isolated function openPageBearer(VerifyStore st, crypto:TokenCipher cipher, time:Utc now) returns Bearer|error {
    connection:OrgConnection? org = check st.orgConnection();
    if org is () {
        return {reason: scoring:VERIFY_NO_TOKEN};
    }
    if connection:orgStatus(org, now) != connection:PAGE_CONNECTED {
        return {reason: scoring:VERIFY_TOKEN_EXPIRED};
    }
    connection:TokenRef? ref = org.accessToken;
    connection:StoredToken? stored = ref is () ? () : check st.token(ref);
    if stored is () {
        return {reason: scoring:VERIFY_NO_TOKEN};
    }
    string|error bearer = connection:openToken(cipher, stored);
    if bearer is error {
        log:printError("Verification: page token could not be decrypted (key ring?)", bearer);
        return {reason: scoring:VERIFY_NO_TOKEN};
    }
    return bearer;
}

# `scoring:EngagementChecker` over the sharing and connection stores and the two LinkedIn adapters.
isolated class LinkedInChecker {
    *scoring:EngagementChecker;

    private final VerifyStore st;
    private final linkedin:PostPresencePort member;
    private final linkedin:CommunityPresencePort? page;
    private final crypto:TokenCipher cipher;
    private final Bearer & readonly pageBearer;
    private final VerifySettings & readonly settings;

    isolated function init(VerifyStore st, linkedin:PostPresencePort member, linkedin:CommunityPresencePort? page,
            crypto:TokenCipher cipher, Bearer pageBearer, VerifySettings settings) {
        self.st = st;
        self.member = member;
        self.page = page;
        self.cipher = cipher;
        self.pageBearer = pageBearer.cloneReadOnly();
        self.settings = settings.cloneReadOnly();
    }

    public isolated function verify(scoring:VerifyCandidate candidate, time:Utc now)
            returns scoring:CheckResult|scoring:VerifyStop|error {
        sharing:Engagement? e = check self.st.engagement(candidate.engagementId);
        if e is () {
            return unverifiable(scoring:VERIFY_SOURCE_NOT_FOUND);
        }
        if e.deletedAt !is () {
            // An earlier check already saw it gone.
            return {outcome: scoring:CHECK_GONE};
        }
        sharing:VerifyTarget|string target = sharing:verifyTarget(e);
        if target is string {
            return unverifiable(target);
        }
        if target.kind == sharing:TARGET_MEMBER_POST {
            return self.memberPost(e, target.urn, now);
        }
        linkedin:CommunityPresencePort? page = self.page;
        Bearer bearer = self.pageBearer;
        if page is () || bearer !is string {
            return unverifiable(bearer is string ? scoring:VERIFY_NO_TOKEN : bearer.reason);
        }
        scoring:VerifyStop? spent = check self.takeCall(types:COMMUNITY_MANAGEMENT, self.settings.pageBudget, now);
        if spent is scoring:VerifyStop {
            return spent;
        }
        string? actor = target.actorUrn;
        linkedin:Presence|linkedin:ProviderError found = target.kind == sharing:TARGET_REACTION && actor is string
            ? page.reactionPresence(bearer, actor, target.urn) : page.commentPresence(bearer, target.urn);
        return self.outcome(e.id, types:COMMUNITY_MANAGEMENT, now, found);
    }

    # The employee's post, with their own token; with the page token when they have none or it may not read it.
    #
    # + e - Engagement
    # + urn - Post URN
    # + now - Run time
    # + return - The check result, a stop, or an error
    private isolated function memberPost(sharing:Engagement e, string urn, time:Utc now)
            returns scoring:CheckResult|scoring:VerifyStop|error {
        Bearer own = check self.memberBearer(e.employeeId, now);
        scoring:CheckResult first = unverifiable(own is string ? scoring:VERIFY_NO_TOKEN : own.reason);
        if own is string {
            scoring:VerifyStop? spent = check self.takeCall(types:SHARE_ON_LINKEDIN, self.settings.memberBudget, now);
            if spent is scoring:VerifyStop {
                return spent;
            }
            scoring:CheckResult|scoring:VerifyStop|error checked = self.outcome(e.id, types:SHARE_ON_LINKEDIN, now,
                    self.member.postPresence(own, urn));
            if checked !is scoring:CheckResult || checked.outcome != scoring:CHECK_UNVERIFIABLE {
                return checked;
            }
            first = checked;
        }
        linkedin:CommunityPresencePort? page = self.page;
        Bearer pageBearer = self.pageBearer;
        if page is () || pageBearer !is string {
            return first;
        }
        scoring:VerifyStop? spent = check self.takeCall(types:COMMUNITY_MANAGEMENT, self.settings.pageBudget, now);
        if spent is scoring:VerifyStop {
            return spent;
        }
        scoring:CheckResult|scoring:VerifyStop|error second = self.outcome(e.id, types:COMMUNITY_MANAGEMENT, now,
                page.postPresence(pageBearer, urn));
        // Both refused: the employee's reason says more (no token, expired) than the page's 403.
        return second is scoring:CheckResult && second.outcome == scoring:CHECK_UNVERIFIABLE ? first : second;
    }

    # Takes one call from the UTC day's budget of an API, before the call is made.
    #
    # + providerApi - API
    # + budget - Its daily budget
    # + now - Run time
    # + return - `BUDGET_REACHED` when spent, `()` to go on, or a database error
    private isolated function takeCall(types:ProviderApi providerApi, int budget, time:Utc now)
            returns scoring:VerifyStop|error? {
        return check self.st.takeCall(providerApi, now, budget) ? () : scoring:verifyStop(scoring:VERIFY_STOP_BUDGET);
    }

    # What LinkedIn answered: an answer is recorded on the sharing side; a failure is mapped (`fromProviderError`).
    #
    # + engagementId - Engagement
    # + providerApi - API read
    # + now - Run time
    # + result - The presence, or the failure
    # + return - The check result, a stop, or a database error
    private isolated function outcome(string engagementId, types:ProviderApi providerApi, time:Utc now,
            linkedin:Presence|linkedin:ProviderError result) returns scoring:CheckResult|scoring:VerifyStop|error {
        if result is linkedin:ProviderError {
            return fromProviderError(result);
        }
        check self.st.recordCheck(engagementId, providerApi, result == linkedin:PRESENT, now);
        return {outcome: result == linkedin:PRESENT ? scoring:CHECK_PRESENT : scoring:CHECK_GONE};
    }

    # The employee's member token, or why there is none.
    #
    # + employeeId - Employee
    # + now - Run time
    # + return - The bearer or a reason, or a database error
    private isolated function memberBearer(types:EmployeeId employeeId, time:Utc now) returns Bearer|error {
        connection:LinkedInConnection? conn = check self.st.memberConnection(employeeId);
        if conn is () || connection:connectionStatus(conn, now) == connection:REMOVED {
            return {reason: scoring:VERIFY_NO_TOKEN};
        }
        if !connection:canShare(conn, now) {
            return {reason: scoring:VERIFY_TOKEN_EXPIRED};
        }
        connection:TokenRef? ref = conn.currentToken;
        connection:StoredToken? stored = ref is () ? () : check self.st.token(ref);
        if stored is () {
            return {reason: scoring:VERIFY_NO_TOKEN};
        }
        string|error bearer = connection:openToken(self.cipher, stored);
        if bearer is error {
            log:printError("Verification: member token could not be decrypted (key ring?)", bearer);
            return {reason: scoring:VERIFY_NO_TOKEN};
        }
        return bearer;
    }
}

isolated function unverifiable(string reason) returns scoring:CheckResult =>
    {outcome: scoring:CHECK_UNVERIFIABLE, reason};

# What a LinkedIn failure means for the check: 429 and an outage stop the run; a refused token or request makes the
# row action required.
#
# + err - Provider error
# + return - The check result or the stop
isolated function fromProviderError(linkedin:ProviderError err) returns scoring:CheckResult|scoring:VerifyStop {
    linkedin:ProviderErrorCode code = err.detail().code;
    if code == linkedin:RATE_LIMITED {
        return scoring:verifyStop(scoring:VERIFY_STOP_RATE_LIMITED);
    }
    if code == linkedin:UNAVAILABLE || code == linkedin:OUTCOME_UNKNOWN {
        return scoring:verifyStop(scoring:VERIFY_STOP_UNAVAILABLE);
    }
    if code == linkedin:UNAUTHORIZED {
        return unverifiable(scoring:VERIFY_TOKEN_EXPIRED);
    }
    if code == linkedin:FORBIDDEN {
        return unverifiable(scoring:VERIFY_NOT_PERMITTED);
    }
    return unverifiable(scoring:VERIFY_NO_ACTIVITY);
}

# The verification settings from rows; missing or malformed values keep the defaults (off, 48 h, 450, 1000).
#
# + rows - Setting rows
# + return - Settings
isolated function toVerifySettings(store:Setting[] rows) returns VerifySettings {
    VerifySettings s = {};
    foreach store:Setting row in rows {
        json v = row.value;
        match row.key {
            "coin.wallets_enabled" => {
                s.walletsEnabled = v == true;
            }
            "coin.verify_max_age_hours" => {
                s.maxAgeHours = v is int && v > 0 ? v : s.maxAgeHours;
            }
            "engagement.daily_call_budget" => {
                s.pageBudget = v is int && v >= 0 ? v : s.pageBudget;
            }
            "coin.verify_member_daily_call_budget" => {
                s.memberBudget = v is int && v >= 0 ? v : s.memberBudget;
            }
        }
    }
    return s;
}

# Logs a finished verification: counts only.
#
# + result - The result
# + correlationId - Trigger correlation id
isolated function logCoinVerification(scoring:VerifyReport|VerifySkipped result, string? correlationId) {
    if result is VerifySkipped {
        log:printInfo("Pre-coin verification skipped", skipReason = result.reason, correlationId = correlationId);
        return;
    }
    log:printInfo("Pre-coin verification", status = result.status, stopReason = result.stopReason,
            checked = result.checked, verified = result.verified, removed = result.removed,
            actionRequired = result.actionRequired, correlationId = correlationId);
}

// ---- PostgreSQL -----------------------------------------------------------------------------------

# `VerifyStore` over the Coins jobs' single-connection client, composed from the contexts that own each table.
isolated class PgVerifyStore {
    *VerifyStore;

    private final postgresql:Client db;
    private final sharing:PgEngagementVerificationRepository sharingRepo;

    isolated function init(postgresql:Client db) {
        self.db = db;
        self.sharingRepo = new (db);
    }

    isolated function settings() returns VerifySettings|error => toVerifySettings(check store:readSettings(self.db));

    isolated function ledger() returns scoring:VerificationRepository =>
        new scoring:PgVerificationRepository(self.db, store:SYSTEM, leaderboardTopN);

    isolated function engagement(string id) returns sharing:Engagement|error? => self.sharingRepo.find(id);

    isolated function recordCheck(string engagementId, types:ProviderApi providerApi, boolean stillExists, time:Utc now)
            returns error? => self.sharingRepo.recordCheck(engagementId, providerApi, stillExists, now);

    isolated function takeCall(types:ProviderApi providerApi, time:Utc now, int budget) returns boolean|error =>
        self.sharingRepo.takeCall(providerApi, now, budget);

    isolated function memberConnection(types:EmployeeId employeeId) returns connection:LinkedInConnection|error? =>
        (new connection:PgConnectionRepository(self.db)).findByEmployee(employeeId, types:LINKEDIN);

    isolated function orgConnection() returns connection:OrgConnection|error? =>
        (new connection:PgOrgConnectionRepository(self.db)).findActive(types:LINKEDIN);

    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error? =>
        (new connection:PgTokenRepository(self.db)).find(ref);
}
