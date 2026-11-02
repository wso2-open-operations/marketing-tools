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


// Database access for the HTTP layer: the lazy shared client, one factory per repository port and one
// function per read. Each is a test seam (`@test:Mock`), so endpoint tests run on in-memory fakes.

import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.identity;
import amplify_domain.recognition;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

# Database host; empty = not configured (DB-backed calls answer 503, denials are only logged).
configurable string dbHost = "";
# Database port.
configurable int dbPort = 5432;
# Database name.
configurable string dbName = "amplify";
# DB user.
configurable string dbUser = "amplify_api";
# DB password (Choreo secret).
configurable string dbPassword = "";
# TLS mode. `VERIFY_FULL` (default) checks the server certificate against `dbSslRootCert` and the host
# name, as the deployment security checklist requires; `DISABLE` only for local Docker.
configurable postgresql:SSLMode dbSslMode = postgresql:VERIFY_FULL;
# PEM file with the CA that signs the managed Postgres certificate (Choreo file mount, set per environment
# through `BAL_CONFIG_VAR_DBSSLROOTCERT`). Empty = the driver default `~/.postgresql/root.crt`.
configurable string dbSslRootCert = "";
# Pool size.
configurable int dbMaxOpenConnections = 10;
# TCP connect and login timeout, seconds (tight: a dead database fails fast and trips the breaker).
configurable decimal dbConnectTimeoutSeconds = 5;
# Longest wait for a pooled connection, seconds (HikariCP `connectionTimeout`).
configurable decimal dbPoolAcquireTimeoutSeconds = 3;
# DB breaker: transient failures inside the window that open it.
configurable int dbBreakerFailureThreshold = 5;
# DB breaker: failure window, seconds.
configurable decimal dbBreakerWindowSeconds = 30;
# DB breaker: wait before the half-open trial, seconds.
configurable decimal dbBreakerResetSeconds = 15;
# Retries of a read after a transient database error (writes never retry here, ADR-028).
configurable int dbReadRetries = 1;

# Circuit breaker in front of the pool (plan M9, ADR-028).
final resilience:DbBreaker dbBreaker = new ({failureThreshold: dbBreakerFailureThreshold,
    windowSeconds: dbBreakerWindowSeconds, resetTimeSeconds: dbBreakerResetSeconds});

# The database (or another dependency) can't be reached or isn't configured.
type DependencyError distinct error;

isolated postgresql:Client? dbClient = ();

# The shared client, through the breaker: an open breaker answers at once (503 upstream) without
# touching the pool; the half-open trial runs `SELECT 1` and closes or re-opens it.
#
# + return - The client, or a `DependencyError` when not configured, unreachable or the breaker is open
isolated function db() returns postgresql:Client|error {
    resilience:DbAdmission admission = dbBreaker.admit();
    if admission == "REJECT" {
        return error DependencyError("Database breaker is open");
    }
    postgresql:Client|error pg = openDb();
    if pg is error {
        if admission == "TRIAL" {
            dbBreaker.onTrialFailure();
        } else {
            _ = dbBreaker.onFailure(pg);
        }
        return pg;
    }
    if admission == "TRIAL" {
        error? probed = store:probe(pg);
        if probed is error {
            dbBreaker.onTrialFailure();
            return error DependencyError("Database is unreachable", probed);
        }
        dbBreaker.onSuccess();
    }
    return pg;
}

# Counts a failed database call against the breaker (only transient errors count).
#
# + err - Error from a repository or read
isolated function recordDbFailure(error err) {
    if dbBreaker.onFailure(err) {
        log:printWarn("Database call failed (transient)", breaker = dbBreaker.state());
    }
}

# Database breaker state for `/ready` and the metrics gauge.
#
# + return - `CLOSED`, `HALF_OPEN` or `OPEN`
isolated function dbBreakerState() returns resilience:BreakerState => dbBreaker.state();

isolated function openDb() returns postgresql:Client|error {
    lock {
        postgresql:Client? existing = dbClient;
        if existing is postgresql:Client {
            return existing;
        }
        if dbHost == "" {
            return error DependencyError("Database is not configured");
        }
        postgresql:Client|error created = store:newClient(dbConfig());
        if created is error {
            return error DependencyError("Database is unreachable", created);
        }
        dbClient = created;
        return created;
    }
}

# Connection settings from the configurables.
#
# + return - Settings, TLS included
isolated function dbConfig() returns store:DbConfig => {
    host: dbHost,
    port: dbPort,
    database: dbName,
    user: dbUser,
    password: dbPassword,
    sslMode: dbSslMode,
    sslRootCert: dbSslRootCert,
    maxOpenConnections: dbMaxOpenConnections,
    connectTimeoutSeconds: dbConnectTimeoutSeconds,
    loginTimeoutSeconds: dbConnectTimeoutSeconds,
    poolAcquireTimeoutSeconds: dbPoolAcquireTimeoutSeconds
};

# Readiness: the breaker isn't open and the database answers a trivial query.
#
# + return - True when reachable
isolated function dbReachable() returns boolean {
    postgresql:Client|error pg = db();
    if pg is error {
        return false;
    }
    error? probed = store:probe(pg);
    if probed is error {
        recordDbFailure(probed);
        return false;
    }
    return true;
}

// ---- Repository factories (writes) ---------------------------------------------------------------

isolated function employeeRepository() returns identity:EmployeeRepository|error =>
    new identity:PgEmployeeRepository(check db());

isolated function connectionRepository(store:Actor actor) returns connection:ConnectionRepository|error =>
    new connection:PgConnectionRepository(check db(), actor);

isolated function consentRepository() returns connection:ConsentRepository|error =>
    new connection:PgConsentRepository(check db());

isolated function tokenRepository() returns connection:TokenRepository|error =>
    new connection:PgTokenRepository(check db());

isolated function oauthStateRepository() returns connection:OAuthStateRepository|error =>
    new connection:PgOAuthStateRepository(check db());

isolated function campaignRepository(store:Actor actor) returns campaign:CampaignRepository|error =>
    new campaign:PgCampaignRepository(check db(), actor);

isolated function shareRepository(store:Actor actor) returns sharing:ShareRepository|error =>
    new sharing:PgShareRepository(check db(), actor);

isolated function externalShareRepository(store:Actor actor, int topN) returns external_sharing:ExternalShareRepository|error =>
    new external_sharing:PgExternalShareRepository(check db(), actor, topN);

isolated function ledgerRepository(store:Actor actor, int topN) returns scoring:LedgerRepository|error =>
    new scoring:PgLedgerRepository(check db(), actor, topN);

isolated function pointRuleRepository(store:Actor actor) returns scoring:PointRuleRepository|error =>
    new scoring:PgPointRuleRepository(check db(), actor);

isolated function announcementRepository(store:Actor actor) returns announcements:AnnouncementRepository|error =>
    new announcements:PgAnnouncementRepository(check db(), actor);

# Writes one denial to `audit.audit_log` in its own transaction.
#
# + entry - Audit row (`outcome = DENIED`)
# + return - An error on failure
isolated function recordDenial(store:AuditEntry entry) returns error? {
    final postgresql:Client pg = check db();
    final readonly & store:AuditEntry row = entry.cloneReadOnly();
    return store:inTransaction(() => auditTx(pg, row));
}

# Writes one audit row in its own gated transaction (R-13).
#
# + pg - Client
# + entry - Audit row
# + return - An error on failure
isolated function auditTx(postgresql:Client pg, store:AuditEntry entry) returns error? {
    transaction {
        check store:writeAudit(pg, entry);
        check commit;
    }
}

# Writes one audit row in its own transaction (scheduler sync, ADR-026).
#
# + entry - Audit row
# + return - An error on failure
isolated function recordAudit(store:AuditEntry entry) returns error? {
    final postgresql:Client pg = check db();
    final readonly & store:AuditEntry row = entry.cloneReadOnly();
    return store:inTransaction(() => auditTx(pg, row));
}

// ---- Reads ---------------------------------------------------------------------------------------

isolated function campaignPage(campaign:CampaignQuery query, time:Utc now) returns campaign:CampaignPage|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check campaign:listCampaigns(check db(), query, now);
    }
}

isolated function tagList() returns string[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check campaign:listTags(check db());
    }
}

isolated function categoryList() returns campaign:Category[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check campaign:listCategories(check db());
    }
}

isolated function sharesOf(types:EmployeeId employeeId) returns sharing:ShareView[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check sharing:sharesOf(check db(), employeeId);
    }
}

isolated function claimsOf(types:EmployeeId employeeId) returns external_sharing:ExternalShare[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check external_sharing:claimsOf(check db(), employeeId);
    }
}

isolated function claimsForReview(external_sharing:ExternalShareStatus? status, int page, int size)
        returns external_sharing:ExternalSharePage|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check external_sharing:claimsForReview(check db(), status, page, size);
    }
}

isolated function ledgerHistory(types:EmployeeId employeeId, int page, int size) returns scoring:LedgerPage|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check scoring:historyOf(check db(), employeeId, page, size);
    }
}

isolated function topStandings(string period, int topN) returns recognition:Standing[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:topStandings(check db(), period, topN);
    }
}

isolated function monthlyTotalsRead(time:Utc monthStart) returns recognition:EmployeeTotal[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:monthlyTotals(check db(), monthStart);
    }
}

isolated function standingOf(types:EmployeeId employeeId, string period) returns recognition:Standing|error? {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:standingOf(check db(), employeeId, period);
    }
}

isolated function standingVersion(string period) returns int|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:standingVersion(check db(), period);
    }
}

isolated function teamPageOf(string period, string[]? emails, string? q, recognition:TeamSort sort, int page, int size)
        returns recognition:TeamPage|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:teamPage(check db(), period, emails, q, sort, page, size);
    }
}

isolated function rosterPageOf(string period, recognition:RosterMember[] members, string? q, recognition:TeamSort sort,
        int page, int size) returns recognition:RosterPage|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:rosterPage(check db(), period, members, q, sort, page, size);
    }
}

isolated function pointsByEmailOf(string period) returns recognition:EmailPoints[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:pointsByEmail(check db(), period);
    }
}

isolated function monthlyPoints(types:EmployeeId employeeId) returns recognition:MonthPoints[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:monthlyPointsOf(check db(), employeeId);
    }
}

isolated function standingEmailOf(types:EmployeeId employeeId) returns string|error? {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check recognition:emailOf(check db(), employeeId);
    }
}

isolated function settingRows() returns store:Setting[]|error {
    retry<resilience:TransientDbRetry> (dbReadRetries) {
        return check store:readSettings(check db());
    }
}

isolated function saveSettings(store:Actor actor, store:SettingChange[] changes) returns error? {
    check store:updateSettings(check db(), actor, changes, time:utcNow());
    forgetSettings();
}

// ---- Idempotency keys ------------------------------------------------------------------------------

isolated function claimIdempotency(types:EmployeeId employeeId, string key, string hash)
        returns store:IdempotencyRecord|error? =>
    store:claimIdempotencyKey(check db(), employeeId, key, hash, IDEMPOTENCY_TTL_SECONDS, time:utcNow());

isolated function completeIdempotency(types:EmployeeId employeeId, string key, int status, json body) returns error? =>
    store:completeIdempotencyKey(check db(), employeeId, key, status, body);

isolated function releaseIdempotency(types:EmployeeId employeeId, string key) returns error? =>
    store:releaseIdempotencyKey(check db(), employeeId, key);
