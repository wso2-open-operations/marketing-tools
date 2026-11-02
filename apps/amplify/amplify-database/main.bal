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
import ballerina/crypto;
import ballerina/file;
import ballerina/io;
import ballerina/lang.regexp;
import ballerina/log;
import ballerina/sql;
import ballerina/time;
import ballerinax/postgresql;
import ballerinax/postgresql.driver as _;

# Folder holding the forward-only versioned scripts.
configurable string migrationsDir = "migrations";
# Folder holding the reference-data scripts, applied after the migrations.
configurable string seedDir = "seed";
# Connect and report each script as pending, applied or changed; apply nothing. Fails on a changed script or
# a pending one that sorts below an applied one (out of order). Creates nothing either: `schema_version`
# is only read, and a database without it reports every script as pending.
configurable boolean dryRun = false;

# Database host.
configurable string dbHost = "localhost";
# Database port.
configurable int dbPort = 5432;
# Database name.
configurable string dbName = "amplify";
# Login user: the one database user Amplify gets (staging `amplify_stg_user`, production its own name; local
# `amplify_local_user`). It owns every object and every component connects as it (ADR-043); see `checks/d3_single_user.sql`.
configurable string dbUser = "amplify_local_user";
# Login password (secret).
configurable string dbPassword = "";
# Schema every table lives in. Empty = the login user's name (the schema the DBA created for it). The scripts
# name no schema; the runner puts this one first on the `search_path`.
configurable string dbSchema = "";
# TLS mode. `VERIFY_FULL` (default) checks the server certificate against `dbSslRootCert` and the host
# name, as the deployment security checklist requires (same default as amplify-api and amplify-jobs);
# `DISABLE` only for local Docker.
configurable postgresql:SSLMode dbSslMode = DEFAULT_SSL_MODE;
# PEM file with the CA that signs the managed Postgres certificate (Choreo file mount, set per environment
# through `BAL_CONFIG_VAR_DBSSLROOTCERT`). Empty = the driver default `~/.postgresql/root.crt`.
configurable string dbSslRootCert = "";

final regexp:RegExp MIGRATION_FILE = re `V[0-9]{3}__[a-z0-9_]+\.sql`;
final regexp:RegExp SEED_FILE = re `S[0-9]{3}__[a-z0-9_]+\.sql`;

# Key for the transaction-level advisory lock that serializes concurrent runners.
const int MIGRATE_LOCK_KEY = 4242001;

# TLS mode when `dbSslMode` is not configured: verify the server, like amplify-api and amplify-jobs.
const postgresql:SSLMode DEFAULT_SSL_MODE = postgresql:VERIFY_FULL;

# Oldest server the scripts run on: the views use `security_invoker` (PostgreSQL 15).
const int MIN_SERVER_VERSION_NUM = 150000;

# Kind of a recorded script.
public type ScriptKind "MIGRATION"|"SEED";

# Result of one run.
public type RunSummary record {|
    # Scripts applied in this run, in order
    string[] applied;
    # Scripts already recorded and unchanged
    int skipped;
|};

# Amplify DB Migrate: applies pending migrations, then seeds, each in its own transaction, records them in
# `schema_version`, and exits. Safe to rerun: applied scripts are
# skipped, and a changed applied script stops the run (forward-only).
#
# + return - Error when a script fails, an applied script changed, or the database is unreachable
@display {
    label: "Amplify DB Migrate",
    id: "amplify/amplify-db-migrate"
}
public function main() returns error? {
    string[] migrations = check listMigrations(migrationsDir);
    string[] seeds = check listScripts(seedDir, SEED_FILE);
    log:printInfo(string `Found ${migrations.length()} migration(s) in ${migrationsDir}, ${seeds.length()} seed(s) in ${seedDir}`);
    string? tls = tlsWarning(dbHost, dbSslMode);
    if tls is string {
        log:printWarn(tls);
    }
    postgresql:Client db = check new (host = dbHost, username = dbUser, password = dbPassword, database = dbName,
        port = dbPort, options = {ssl: secureSocketOf(dbSslMode, dbSslRootCert), connectTimeout: 10},
        connectionPool = {maxOpenConnections: 1, minIdleConnections: 1});
    string schema = dbSchema.trim() == "" ? dbUser : dbSchema.trim();
    if dryRun {
        error? planned = dryRunReport(db, migrationsDir, seedDir, schema);
        check db.close();
        if planned is error {
            log:printError("Dry run found a problem", planned);
        }
        return planned;
    }
    RunSummary|error summary = migrate(db, migrationsDir, seedDir, schema);
    if summary is error {
        log:printError("Migration run failed", summary);
        check db.close();
        return summary;
    }
    check db.close();
    log:printInfo(string `Migration run done: ${summary.applied.length()} applied, ${summary.skipped} already current`);
}

# The `ssl` client option: the root certificate is passed only when the mode verifies the server and a
# path is set (same rule as `amplify_domain.store:secureSocketOf`, which this runner doesn't depend on).
#
# + mode - TLS mode
# + rootCert - CA PEM path; blank = driver default
# + return - The `ssl` option
function secureSocketOf(postgresql:SSLMode mode, string rootCert) returns postgresql:SecureSocket {
    string cert = rootCert.trim();
    return verifiesServer(mode) && cert != "" ? {mode, rootcert: cert} : {mode};
}

# Whether the mode checks who the database server is.
#
# + mode - TLS mode
# + return - True for `VERIFY_CA` and `VERIFY_FULL`
function verifiesServer(postgresql:SSLMode mode) returns boolean =>
    mode == postgresql:VERIFY_CA || mode == postgresql:VERIFY_FULL;

# Start-up warning for a connection that doesn't verify a remote database server (same wording and local
# rule as `amplify_domain.store:tlsWarning`).
#
# + host - Database host
# + mode - TLS mode
# + return - The warning, or `()` when the server is verified or the host is local
function tlsWarning(string host, postgresql:SSLMode mode) returns string? {
    if host.trim() == "" || verifiesServer(mode) || isLocalHost(host) {
        return ();
    }
    return string `Database TLS mode ${mode} doesn't verify the server; set dbSslMode=VERIFY_FULL `
        + "and dbSslRootCert (deployment security checklist)";
}

# Hosts that never leave the machine or the local Compose network: loopback and single-label names
# (`postgres` in compose.yaml). A managed database always has a dotted host name.
#
# + host - Database host
# + return - True when local
function isLocalHost(string host) returns boolean {
    string h = host.trim().toLowerAscii();
    return h == "localhost" || h.startsWith("127.") || h == "::1" || h == "[::1]" || !h.includes(".");
}

# Applies every pending migration then every pending seed.
#
# + db - Client connected as the login user (a pool of one connection: the schema is set on the session)
# + migrationsPath - Migrations folder
# + seedPath - Seed folder
# + schema - Schema every table lives in
# + return - What ran, or the first error
public function migrate(postgresql:Client db, string migrationsPath, string seedPath, string schema)
        returns RunSummary|error {
    check useSchema(db, schema, false);
    check checkServerVersion(db);
    check ensureVersionTable(db, schema);
    string[] migrations = check listMigrations(migrationsPath);
    string[] seeds = check listScripts(seedPath, SEED_FILE);
    map<string> recorded = check readRecorded(db);
    string[] outOfOrder = [...findOutOfOrder(migrations, recorded), ...findOutOfOrder(seeds, recorded)];
    if outOfOrder.length() > 0 {
        return error(string:'join("; ", ...outOfOrder));
    }
    RunSummary summary = {applied: [], skipped: 0};
    foreach string script in migrations {
        check applyScript(db, migrationsPath, script, "MIGRATION", schema, summary);
    }
    foreach string script in seeds {
        check applyScript(db, seedPath, script, "SEED", schema, summary);
    }
    return summary;
}

# Reports what a real run would do, without changing anything: connects, reads `schema_version` if it
# exists (it is not created), logs each script as pending, applied or changed, and fails when an applied
# script was changed or a pending script sorts below an applied one.
#
# + db - Client connected as the login user
# + migrationsPath - Migrations folder
# + seedPath - Seed folder
# + schema - Schema every table lives in
# + return - An error naming every changed or out-of-order script, or a read error
public function dryRunReport(postgresql:Client db, string migrationsPath, string seedPath, string schema) returns error? {
    check useSchema(db, schema, false);
    string[] migrations = check listMigrations(migrationsPath);
    string[] seeds = check listScripts(seedPath, SEED_FILE);
    boolean exists = check db->queryRow(`SELECT to_regclass('schema_version') IS NOT NULL`);
    map<string> recorded = exists ? check readRecorded(db) : {};
    if !exists {
        log:printInfo("schema_version doesn't exist yet; every script is pending");
    }
    string[] problems = [...findOutOfOrder(migrations, recorded), ...findOutOfOrder(seeds, recorded)];
    int pending = 0;
    foreach [string, string] [dir, script] in [...from string m in migrations select [migrationsPath, m],
            ...from string s in seeds select [seedPath, s]] {
        string content = check io:fileReadString(check file:joinPath(dir, script));
        ScriptState state = classifyScript(versionOf(script), checksumOf(content), recorded);
        log:printInfo(string `${state}: ${script}`); // log-pii: ok state is PENDING, APPLIED or CHANGED
        if state == "PENDING" {
            pending += 1;
        } else if state == "CHANGED" {
            problems.push(string `${script} was changed after it was applied; add a new script instead (forward-only)`);
        }
    }
    log:printInfo(string `Dry run: ${pending} pending of ${migrations.length() + seeds.length()} script(s); nothing applied`);
    if problems.length() > 0 {
        return error(string:'join("; ", ...problems));
    }
}

# State of a script against the recorded checksums.
public type ScriptState "PENDING"|"APPLIED"|"CHANGED";

# Classifies a script.
#
# + version - Version key of the script
# + checksum - SHA-256 of the file now
# + recorded - Version key to recorded checksum
# + return - PENDING when not recorded, APPLIED when the checksum matches, CHANGED when it differs
function classifyScript(string version, string checksum, map<string> recorded) returns ScriptState {
    string? was = recorded[version];
    if was is () {
        return "PENDING";
    }
    return was == checksum ? "APPLIED" : "CHANGED";
}

# Finds pending scripts that sort below an applied script of the same kind (V or S), which would run out
# of order (Flyway's default, `outOfOrder=false`, rejects them too).
#
# + scripts - Script file names of one kind, sorted
# + recorded - Version key to recorded checksum
# + return - One message per out-of-order pending script
function findOutOfOrder(string[] scripts, map<string> recorded) returns string[] {
    string[] problems = [];
    foreach string script in scripts {
        string version = versionOf(script);
        if recorded.hasKey(version) {
            continue;
        }
        string prefix = version.substring(0, 1);
        string? highest = ();
        foreach string key in recorded.keys() {
            if key.startsWith(prefix) && (highest is () || key.substring(0, 4) > highest.substring(0, 4)) {
                highest = key;
            }
        }
        if highest is string && version.substring(0, 4) < highest.substring(0, 4) {
            problems.push(string `${version} is pending but ${highest} is already applied; renumber it`);
        }
    }
    return problems;
}

# Reads the recorded checksums.
#
# + db - Client connected as the login user
# + return - Version key to checksum, or an error
function readRecorded(postgresql:Client db) returns map<string>|error {
    map<string> recorded = {};
    stream<record {|string version; string checksum;|}, sql:Error?> rows = db->query(
        `SELECT version, checksum FROM schema_version`);
    check from record {|string version; string checksum;|} row in rows
        do {
            recorded[row.version] = row.checksum;
        };
    return recorded;
}

# SHA-256 of a script, hex.
#
# + content - Script text
# + return - Checksum as stored in `schema_version`
function checksumOf(string content) returns string => crypto:hashSha256(content.toBytes()).toBase16();

# Lists versioned migration scripts, sorted by version.
#
# + dir - Folder to scan
# + return - Script file names, or an error if the folder can't be read
function listMigrations(string dir) returns string[]|error => listScripts(dir, MIGRATION_FILE);

# Lists scripts matching a pattern, sorted by name (the 3-digit number orders them). A `.sql` file that
# doesn't match the pattern, or two scripts with the same number, stop the run: a misnamed script would
# otherwise be skipped without a word, and two `V012` scripts would apply in name order by accident.
#
# + dir - Folder to scan
# + pattern - File name pattern
# + return - File names, or an error if the folder can't be read or holds a misnamed or duplicate script
function listScripts(string dir, regexp:RegExp pattern) returns string[]|error {
    file:MetaData[] entries = check file:readDir(dir);
    string[] names = [];
    foreach file:MetaData entry in entries {
        string name = check file:basename(entry.absPath);
        if entry.dir {
            continue;
        }
        if pattern.isFullMatch(name) {
            names.push(name);
        } else if name.toLowerAscii().endsWith(".sql") {
            return error(string `${dir}/${name} is not a valid script name (V###__snake_name.sql / S###__snake_name.sql)`);
        }
    }
    string[] sorted = names.sort();
    foreach int i in 1 ..< sorted.length() {
        if sorted[i].substring(0, 4) == sorted[i - 1].substring(0, 4) {
            return error(string `${dir}: ${sorted[i - 1]} and ${sorted[i]} share the version ${sorted[i].substring(0, 4)}`);
        }
    }
    return sorted;
}

# Version key of a script: its name without `.sql`, for example `V001__schema_and_extensions`.
#
# + script - File name
# + return - Version key
function versionOf(string script) returns string => script.substring(0, script.length() - 4);

# Stops before any script runs when the server is older than the scripts need, instead of recording V001 and
# failing on V002.
#
# + db - Client connected as the login user
# + return - An error when the server is too old or can't be asked
function checkServerVersion(postgresql:Client db) returns error? {
    int versionNum = check db->queryRow(`SELECT current_setting('server_version_num')::int`);
    if versionNum < MIN_SERVER_VERSION_NUM {
        return error(string `Amplify needs PostgreSQL 15 or later (security_invoker views); the server reports version number ${versionNum}`);
    }
}

# Creates `schema_version` (in the schema) once. Under the same advisory lock the scripts use, so two runners starting
# on an empty database can't race on the CREATE.
#
# + db - Client connected as the login user
# + return - An error on failure
function ensureVersionTable(postgresql:Client db, string schema) returns error? {
    transaction {
        _ = check db->queryRow(`SELECT 1 FROM (SELECT pg_advisory_xact_lock(${MIGRATE_LOCK_KEY})) l`, int);
        check useSchema(db, schema, true);
        _ = check db->execute(`
            CREATE TABLE IF NOT EXISTS schema_version (
                version      text        PRIMARY KEY,
                kind         text        NOT NULL CHECK (kind IN ('MIGRATION', 'SEED')),
                checksum     text        NOT NULL,
                applied_at   timestamptz NOT NULL DEFAULT now(),
                applied_by   text        NOT NULL DEFAULT current_user,
                execution_ms int         NOT NULL
            )`);
        check commit;
    }
}

function applyScript(postgresql:Client db, string dir, string script, ScriptKind kind, string schema, RunSummary summary)
        returns error? {
    string path = check file:joinPath(dir, script);
    string content = check io:fileReadString(path);
    string checksum = checksumOf(content);
    string version = versionOf(script);
    time:Utc started = time:utcNow();
    boolean applied = false;
    transaction {
        // Serialize concurrent runners; re-check after the lock so the loser of a race skips.
        _ = check db->queryRow(`SELECT 1 FROM (SELECT pg_advisory_xact_lock(${MIGRATE_LOCK_KEY})) l`, int);
        check useSchema(db, schema, true);
        string|sql:Error recorded = db->queryRow(`SELECT checksum FROM schema_version WHERE version = ${version}`);
        if recorded is string {
            if recorded != checksum {
                fail error(string `${script} was changed after it was applied; add a new script instead (forward-only)`);
            }
        } else if recorded is sql:NoRowsError {
            // The script file is trusted code shipped in the image, never user input: it is the one place
            // SQL text is executed as-is (it holds DDL and dollar-quoted bodies, which can't be bound).
            // `call`, not `execute`: execute asks the driver for generated keys, which appends RETURNING.
            log:printInfo(string `Applying ${kind} ${script}`);
            sql:ProcedureCallResult|sql:Error result = db->call(scriptQuery(content));
            if result is sql:Error {
                // Name the script: the driver's own message ("relation x already exists") doesn't.
                fail error(string `${kind} ${script} failed: ${result.message()}`, result);
            }
            check result.close();
            int elapsed = <int>(time:utcDiffSeconds(time:utcNow(), started) * 1000);
            _ = check db->execute(`
                INSERT INTO schema_version (version, kind, checksum, execution_ms)
                VALUES (${version}, ${kind}, ${checksum}, ${elapsed})`);
            applied = true;
        } else {
            fail recorded;
        }
        check commit;
    }
    if applied {
        summary.applied.push(script);
        log:printInfo(string `Applied ${kind} ${script}`);
    } else {
        summary.skipped += 1;
    }
}

# Wraps a trusted script file as a query with no parameters.
#
# + content - Script text
# + return - The query
function scriptQuery(string content) returns sql:ParameterizedCallQuery {
    sql:ParameterizedCallQuery query = ``;
    query.strings = [content].cloneReadOnly();
    return query;
}


# Puts the schema first on the `search_path`, so scripts and the version table need no schema name. The name is
# bound and quoted by the database (`quote_ident`), never spliced into SQL. The check first, so a missing schema
# says so instead of "no schema has been selected to create in".
#
# + db - Client connected as the login user
# + schema - Schema every table lives in
# + transactionOnly - False sets it for the session; true only for the current transaction
# + return - An error when the schema does not exist or can't be set
function useSchema(postgresql:Client db, string schema, boolean transactionOnly) returns error? {
    boolean exists = check db->queryRow(`SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = ${schema})`);
    if !exists {
        return error(string `Schema ${schema} does not exist: the DBA creates the schema named after the login user, `
            + "or set dbSchema to one that exists");
    }
    // pg_temp last, so a temporary table can't shadow a real one; public holds citext and pg_trgm.
    _ = check db->queryRow(`SELECT 1 FROM (SELECT set_config('search_path',
        quote_ident(${schema}) || ', public, pg_temp', ${transactionOnly})) s`, int);
}
