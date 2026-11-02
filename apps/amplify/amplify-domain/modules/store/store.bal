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

// Infrastructure shared by every context repository: the PostgreSQL client, the outbox and audit
// writers used inside a repository's transaction, and SQL error mapping. No domain rules here.

import amplify_common.types;

import ballerina/lang.runtime;
import ballerina/sql;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

# Connection settings for one component's DB user (`amplify_api` or `amplify_jobs`). Filled from
# `configurable` values in the component; the password is a Choreo secret.
public type DbConfig record {|
    # Host
    string host;
    # Port
    int port = 5432;
    # Database name
    string database;
    # DB user
    string user;
    # Password (secret)
    string password;
    # TLS mode. `VERIFY_FULL` (the default) checks the server certificate chain against `sslRootCert` and
    # the host name, as the deployment security checklist requires; `REQUIRE` encrypts without checking
    # who answers; `DISABLE` only for local Docker
    postgresql:SSLMode sslMode = postgresql:VERIFY_FULL;
    # PEM file with the CA certificate(s) that sign the server certificate (`sslrootcert`), for
    # `VERIFY_CA` / `VERIFY_FULL`. `()` = the driver default `~/.postgresql/root.crt`
    string? sslRootCert = ();
    # Pool: maximum open connections
    int maxOpenConnections = 10;
    # Pool: minimum idle connections
    int minIdleConnections = 1;
    # Pool: idle connection lifetime, seconds
    decimal maxConnectionLifeTime = 1800;
    # Pool: longest wait for a connection from the pool, seconds (HikariCP `connectionTimeout`; its 30 s
    # default holds a request for half a minute when the database is gone)
    decimal poolAcquireTimeoutSeconds = 3;
    # TCP connect timeout, seconds (kept tight so a dead database fails fast and feeds the breaker, M9)
    decimal connectTimeoutSeconds = 5;
    # Login timeout, seconds
    decimal loginTimeoutSeconds = 5;
    # Socket read timeout, seconds (long enough for maintenance and the recognition rebuild)
    decimal socketTimeoutSeconds = 30;
|};

# Opens a pooled client. Every query runs in UTC so dates (`issued_on`, months) match the domain.
#
# + config - Settings
# + return - The client, or an error
public isolated function newClient(DbConfig config) returns postgresql:Client|sql:Error =>
    new (host = config.host, username = config.user, password = config.password, database = config.database,
        port = config.port,
        options = {
            ssl: secureSocketOf(config),
            connectTimeout: config.connectTimeoutSeconds,
            loginTimeout: config.loginTimeoutSeconds,
            socketTimeout: config.socketTimeoutSeconds
        },
        connectionPool = {
            maxOpenConnections: config.maxOpenConnections,
            minIdleConnections: config.minIdleConnections,
            maxConnectionLifeTime: config.maxConnectionLifeTime,
            connectionTimeout: config.poolAcquireTimeoutSeconds,
            validationTimeout: config.poolAcquireTimeoutSeconds < 2d ? config.poolAcquireTimeoutSeconds : 2
        });

# TLS settings for the driver: the mode, plus the CA file when the mode verifies the server.
#
# + config - Settings
# + return - The `ssl` option
public isolated function secureSocketOf(DbConfig config) returns postgresql:SecureSocket {
    string? rootCert = types:trimToNil(config.sslRootCert);
    boolean verifies = config.sslMode == postgresql:VERIFY_CA || config.sslMode == postgresql:VERIFY_FULL;
    return verifies && rootCert is string ? {mode: config.sslMode, rootcert: rootCert} : {mode: config.sslMode};
}

# Whether the settings check who the database server is (`VERIFY_CA` or `VERIFY_FULL`). Components log
# a warning at start-up when this is false outside local Docker.
#
# + config - Settings
# + return - True when the server certificate is verified
public isolated function verifiesServer(DbConfig config) returns boolean =>
    config.sslMode == postgresql:VERIFY_CA || config.sslMode == postgresql:VERIFY_FULL;

# Start-up warning for a connection that doesn't verify the database server (domain review H-1). api and
# jobs log it from `init`.
#
# + config - Settings
# + return - The warning, or `()` when the server is verified, the host is local or none is configured
public isolated function tlsWarning(DbConfig config) returns string? {
    if config.host.trim() == "" || verifiesServer(config) || isLocalHost(config.host) {
        return ();
    }
    return string `Database TLS mode ${config.sslMode} doesn't verify the server; set dbSslMode=VERIFY_FULL `
        + "and dbSslRootCert (deployment security checklist)";
}

# Hosts that never leave the machine or the local Compose network: loopback and single-label names
# (`postgres` in compose.yaml). A managed database always has a dotted host name.
#
# + host - Database host
# + return - True when local
public isolated function isLocalHost(string host) returns boolean {
    string h = host.trim().toLowerAscii();
    return h == "localhost" || h.startsWith("127.") || h == "::1" || h == "[::1]" || !h.includes(".");
}

# Advisory lock key that serializes the re-rank of `recognition.standing` (one lock for the period
# `ALL`; distinct from the jobs run lock and the migrate lock).
#
# Lock order: two transaction-scoped advisory locks guard recognition writes, and they are always taken
# in this order: (1) this app-level key `4242101`, taken here by `lockRecognition`, then (2) the SQL-level
# key `1634561133`, taken inside `recognition.apply_ledger_entry` / `recognition.rebuild` /
# `recognition.rerank` (V012; documented again on those functions by V013). Call `lockRecognition` before
# any of those functions in the same transaction, never after: the reverse order can deadlock against a
# writer that follows the rule. `tests/lock_order_test.bal` fails if a call site breaks it, and the
# database IT checks that no SQL function takes `4242101`. Keep both locks.
public const int RECOGNITION_LOCK_KEY = 4242101;

# SQL-level recognition lock key taken by the V012 functions (second in the lock order above).
public const int RECOGNITION_SQL_LOCK_KEY = 1634561133;

# Idle-in-transaction limit set (transaction-local) by every holder of the recognition lock, milliseconds.
public const int RECOGNITION_IDLE_TIMEOUT_MS = 5000;

# Longest wait for the recognition lock, seconds. Short on purpose: the wait happens inside a gated
# transaction (`inTransaction`, R-13), so every other write of this process waits with it. Inside one
# process the gate already serializes recognition writers; the advisory lock now only arbitrates between
# processes (api replicas and jobs), whose holders keep it for milliseconds.
public const decimal RECOGNITION_LOCK_WAIT_SECONDS = 2;

# Takes the transaction-scoped recognition lock. Every writer that re-ranks a period
# (`recognition.apply_ledger_entry`, `recognition.rebuild`) takes it first, so two ledger appends can't
# deadlock in the re-rank UPDATE or store ranks computed without each other's row. Released at commit
# or rollback.
#
# It polls `pg_try_advisory_xact_lock` with a short, growing sleep instead of blocking in
# `pg_advisory_xact_lock`, so a waiter never sits inside a JDBC call and gives up after `maxWaitSeconds`
# with an error instead of hanging. In the review's concurrency test a blocking wait hung the process
# for good when a holder stopped committing (a Ballerina runtime race, R-13 in
# docs/reviews/2026-10-26-code-review-backend.md); polling plus the idle timeout below bounds
# that to seconds.
#
# Runs inside the transaction gate (`inTransaction`, round 2 item 12), so the poll is capped at
# `RECOGNITION_LOCK_WAIT_SECONDS` (2 s): while it waits, no other transaction of this process can start.
#
# Lock order: this is lock (1) of two. Take it before calling any `recognition.*` function that takes
# the SQL-level key `RECOGNITION_SQL_LOCK_KEY` (1634561133, lock (2)), never after; see
# `RECOGNITION_LOCK_KEY`.
#
# + db - Client, inside the caller's transaction
# + maxWaitSeconds - Give up after this long
# + return - An error on failure, or when the lock stays busy for `maxWaitSeconds`
public isolated transactional function lockRecognition(postgresql:Client db,
        decimal maxWaitSeconds = RECOGNITION_LOCK_WAIT_SECONDS) returns error? {
    // A transaction that holds this lock and then goes quiet (a client that never commits: seen in the
    // R-13 concurrency test, where a runtime race left a connection idle in transaction) would block every
    // ledger append in api and jobs. PostgreSQL ends such a session after a few idle seconds, which
    // releases the lock; a healthy append is idle for milliseconds between its statements.
    _ = check db->queryRow(`SELECT set_config('idle_in_transaction_session_timeout',
        CAST(${RECOGNITION_IDLE_TIMEOUT_MS} AS text), true)`, string);
    decimal waited = 0;
    decimal pause = 0.005;
    while true {
        boolean acquired = check db->queryRow(
            `SELECT pg_try_advisory_xact_lock(CAST(${RECOGNITION_LOCK_KEY} AS bigint))`);
        if acquired {
            return;
        }
        if waited >= maxWaitSeconds {
            return error("The leaderboard is busy; retry");
        }
        runtime:sleep(pause);
        waited += pause;
        pause = pause < 0.1d ? pause * 2 : 0.1d;
    }
}

# Readiness check (`GET /ready`).
#
# + db - Client
# + return - True when a trivial query succeeds
public isolated function ping(postgresql:Client db) returns boolean => probe(db) is ();

# Trivial query for the database breaker's half-open trial (M9): `()` when the database answers.
#
# + db - Client
# + return - The error when it doesn't
public isolated function probe(postgresql:Client db) returns sql:Error? {
    int|sql:Error one = db->queryRow(`SELECT 1`);
    return one is sql:Error ? one : ();
}

# Normalized paging for list queries: a negative page is page 0 and a size below 1 is 1, so a bad
# query string never reaches the database as a negative `OFFSET` / `LIMIT` (a raw SQL error).
#
# + page - Zero-based page as asked
# + size - Page size as asked
# + maxSize - Largest size allowed, or `()` for no upper bound
# + return - `[limit, offset]`
public isolated function pageWindow(int page, int size, int? maxSize = ()) returns [int, int] {
    int 'limit = size < 1 ? 1 : size;
    if maxSize is int && 'limit > maxSize {
        'limit = maxSize;
    }
    int p = page < 0 ? 0 : page;
    // A huge page would overflow `int` (a panic); past the end is past the end.
    int offset = p > int:MAX_VALUE / 'limit ? int:MAX_VALUE : p * 'limit;
    return ['limit, offset];
}
