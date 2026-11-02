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

// Database client for amplify-jobs (DB user `amplify_jobs`). Opened lazily on first use, so the service
// starts (and `/health` answers) even while the database is down; `dbHost = ""` means not configured.

import amplify_common.resilience;
import amplify_domain.store;

import ballerina/log;
import ballerinax/postgresql;

# Database host; empty = not configured (maintenance answers 503).
configurable string dbHost = "";
# Database port.
configurable int dbPort = 5432;
# Database name.
configurable string dbName = "amplify";
# DB user.
configurable string dbUser = "amplify_jobs";
# DB password (Choreo secret).
configurable string dbPassword = "";
# TLS mode. `VERIFY_FULL` (default) checks the server certificate against `dbSslRootCert` and the host
# name, as the deployment security checklist requires; `DISABLE` only for local Docker.
configurable postgresql:SSLMode dbSslMode = postgresql:VERIFY_FULL;
# PEM file with the CA that signs the managed Postgres certificate (Choreo file mount, set per environment
# through `BAL_CONFIG_VAR_DBSSLROOTCERT`). Empty = the driver default `~/.postgresql/root.crt`.
configurable string dbSslRootCert = "";
# TCP connect and login timeout, seconds (tight: a dead database fails fast and trips the breaker).
configurable decimal dbConnectTimeoutSeconds = 5;
# Longest wait for a pooled connection, seconds (HikariCP `connectionTimeout`).
configurable decimal dbPoolAcquireTimeoutSeconds = 3;
# DB breaker: transient failures inside the window that open it.
configurable int dbBreakerFailureThreshold = 3;
# DB breaker: failure window, seconds.
configurable decimal dbBreakerWindowSeconds = 60;
# DB breaker: wait before the half-open trial, seconds.
configurable decimal dbBreakerResetSeconds = 30;
# `leaderboard.top_n` used by the recognition rebuild.
configurable int leaderboardTopN = 3;
# Longest wait for one partition-maintenance statement, seconds. Must stay below amplify-api's
# `maintenanceDeadlineSeconds` (180) so the client gives up first and returns a clean 500; the scheduler's
# retry then finds the maintenance lock still held and answers 202 SKIPPED instead of starting a second pass.
configurable decimal dbMaintenanceSocketTimeoutSeconds = 150;

isolated postgresql:Client? dbClient = ();

# Circuit breaker in front of both pools (plan M9, ADR-028). A run that hits a dead database stops at
# once; while the breaker is open the scheduler's calls answer 503 without opening connections.
final resilience:DbBreaker dbBreaker = new ({failureThreshold: dbBreakerFailureThreshold,
    windowSeconds: dbBreakerWindowSeconds, resetTimeSeconds: dbBreakerResetSeconds});

# The shared client, through the breaker (half-open trial = `SELECT 1`).
#
# + return - The client, or an error when not configured, unreachable or the breaker is open
isolated function db() returns postgresql:Client|error {
    resilience:DbAdmission admission = dbBreaker.admit();
    if admission == "REJECT" {
        return error("Database breaker is open");
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
            return error("Database is unreachable", probed);
        }
        dbBreaker.onSuccess();
    }
    return pg;
}

# Readiness check: the client opens through the breaker and `SELECT 1` answers.
#
# + return - True when the database answers
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

# Counts a failed database call against the breaker (only transient errors count).
#
# + err - Error from a run, maintenance or rebuild
isolated function recordDbFailure(error err) {
    if dbBreaker.onFailure(err) {
        log:printWarn("Database call failed (transient)", breaker = dbBreaker.state());
    }
}

isolated function openDb() returns postgresql:Client|error {
    lock {
        postgresql:Client? existing = dbClient;
        if existing is postgresql:Client {
            return existing;
        }
        if dbHost == "" {
            return error("Database is not configured");
        }
        postgresql:Client created = check store:newClient(dbConfig());
        dbClient = created;
        return created;
    }
}

isolated postgresql:Client? lockClient = ();

# Dedicated single-connection client for the run's session advisory lock (lock and unlock must share a
# session, so it never shares the pool). The connection is never retired (`maxConnectionLifeTime = 0`): a
# pooled connection retired mid-run would take the session lock with it.
#
# + return - The client, or an error when not configured or unreachable
isolated function lockDb() returns postgresql:Client|error {
    lock {
        postgresql:Client? existing = lockClient;
        if existing is postgresql:Client {
            return existing;
        }
        if dbHost == "" {
            return error("Database is not configured");
        }
        postgresql:Client created = check store:newClient(dbConfig(maxOpenConnections = 1,
            maxConnectionLifeTime = 0));
        lockClient = created;
        return created;
    }
}

isolated postgresql:Client? maintenanceClient = ();

# Dedicated single-connection client for partition maintenance: one connection carries both the maintenance
# session lock and the work, is never retired, and allows a longer statement than the run's pool.
#
# + return - The client, or an error when not configured
isolated function maintenanceDb() returns postgresql:Client|error {
    lock {
        postgresql:Client? existing = maintenanceClient;
        if existing is postgresql:Client {
            return existing;
        }
        if dbHost == "" {
            return error("Database is not configured");
        }
        postgresql:Client created = check store:newClient(dbConfig(maxOpenConnections = 1,
            maxConnectionLifeTime = 0, socketTimeoutSeconds = dbMaintenanceSocketTimeoutSeconds));
        maintenanceClient = created;
        return created;
    }
}

# Connection settings from the configurables (the pool, the run-lock and the maintenance clients).
#
# + maxOpenConnections - Pool size
# + maxConnectionLifeTime - Idle connection lifetime, seconds; 0 = never retire (a session advisory lock
#   must outlive the run)
# + socketTimeoutSeconds - Longest wait for one statement, seconds
# + return - Settings, TLS included
isolated function dbConfig(int maxOpenConnections = 10, decimal maxConnectionLifeTime = 1800,
        decimal socketTimeoutSeconds = 30) returns store:DbConfig => {
    host: dbHost,
    port: dbPort,
    database: dbName,
    user: dbUser,
    password: dbPassword,
    sslMode: dbSslMode,
    sslRootCert: dbSslRootCert,
    maxOpenConnections,
    maxConnectionLifeTime,
    socketTimeoutSeconds,
    minIdleConnections: 1,
    connectTimeoutSeconds: dbConnectTimeoutSeconds,
    loginTimeoutSeconds: dbConnectTimeoutSeconds,
    poolAcquireTimeoutSeconds: dbPoolAcquireTimeoutSeconds
};
