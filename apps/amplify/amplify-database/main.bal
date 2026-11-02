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
# a pending one that sorts below an applied one (out of order). Creates nothing either: `public.schema_version`
# is only read, and a database without it reports every script as pending.
configurable boolean dryRun = false;

# Database host.
configurable string dbHost = "localhost";
# Database port.
configurable int dbPort = 5432;
# Database name.
configurable string dbName = "amplify";
# Bootstrap admin user (Choreo/Aiven `avnadmin`, local `postgres`). Needs CREATEROLE for V001.
configurable string dbUser = "postgres";
# Bootstrap admin password (secret).
configurable string dbPassword = "";
# TLS mode. `VERIFY_FULL` (default) checks the server certificate against `dbSslRootCert` and the host
# name, as the deployment security checklist requires (same default as amplify-api and amplify-jobs);
# `DISABLE` only for local Docker.
configurable postgresql:SSLMode dbSslMode = DEFAULT_SSL_MODE;
# PEM file with the CA that signs the managed Postgres certificate (Choreo file mount, set per environment
# through `BAL_CONFIG_VAR_DBSSLROOTCERT`). Empty = the driver default `~/.postgresql/root.crt`.
configurable string dbSslRootCert = "";

# Login password for `amplify_api` (secret). Empty leaves the role as it is (NOLOGIN on first run).
configurable string apiDbPassword = "";
# Login password for `amplify_jobs` (secret).
configurable string jobsDbPassword = "";
# Login password for `amplify_readonly` (secret, phase 2 reports).
configurable string readonlyDbPassword = "";

final regexp:RegExp MIGRATION_FILE = re `V[0-9]{3}__[a-z0-9_]+\.sql`;
final regexp:RegExp SEED_FILE = re `S[0-9]{3}__[a-z0-9_]+\.sql`;

# Key for the transaction-level advisory lock that serializes concurrent runners.
const int MIGRATE_LOCK_KEY = 4242001;

# TLS mode when `dbSslMode` is not configured: verify the server, like amplify-api and amplify-jobs.
const postgresql:SSLMode DEFAULT_SSL_MODE = postgresql:VERIFY_FULL;

# Oldest server the scripts run on: V002 uses `uuidv7()` (PostgreSQL 18).
const int MIN_SERVER_VERSION_NUM = 180000;

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
# `public.schema_version`, sets role passwords from secrets, and exits. Safe to rerun: applied scripts are
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
        connectionPool = {maxOpenConnections: 2, minIdleConnections: 0});
    if dryRun {
        error? planned = dryRunReport(db, migrationsDir, seedDir);
        check db.close();
        if planned is error {
            log:printError("Dry run found a problem", planned);
        }
        return planned;
    }
    RunSummary|error summary = migrate(db, migrationsDir, seedDir);
    if summary is error {
        log:printError("Migration run failed", summary);
        check db.close();
        return summary;
    }
    error? passwords = setRolePasswords(db, {
        amplify_api: apiDbPassword,
        amplify_jobs: jobsDbPassword,
        amplify_readonly: readonlyDbPassword
    });
    check db.close();
    if passwords is error {
        log:printError("Setting role passwords failed", passwords);
        return passwords;
    }
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
# + db - Client connected as the bootstrap admin
# + migrationsPath - Migrations folder
# + seedPath - Seed folder
# + return - What ran, or the first error
public function migrate(postgresql:Client db, string migrationsPath, string seedPath) returns RunSummary|error {
    check checkServerVersion(db);
    check ensureVersionTable(db);
    check checkBootstrapRole(db);
    string[] migrations = check listMigrations(migrationsPath);
    string[] seeds = check listScripts(seedPath, SEED_FILE);
    map<string> recorded = check readRecorded(db);
    string[] outOfOrder = [...findOutOfOrder(migrations, recorded), ...findOutOfOrder(seeds, recorded)];
    if outOfOrder.length() > 0 {
        return error(string:'join("; ", ...outOfOrder));
    }
    RunSummary summary = {applied: [], skipped: 0};
    foreach string script in migrations {
        check applyScript(db, migrationsPath, script, "MIGRATION", summary);
    }
    foreach string script in seeds {
        check applyScript(db, seedPath, script, "SEED", summary);
    }
    return summary;
}

# Reports what a real run would do, without changing anything: connects, reads `public.schema_version` if it
# exists (it is not created), logs each script as pending, applied or changed, and fails when an applied
# script was changed or a pending script sorts below an applied one.
#
# + db - Client connected as the bootstrap admin
# + migrationsPath - Migrations folder
# + seedPath - Seed folder
# + return - An error naming every changed or out-of-order script, or a read error
public function dryRunReport(postgresql:Client db, string migrationsPath, string seedPath) returns error? {
    string[] migrations = check listMigrations(migrationsPath);
    string[] seeds = check listScripts(seedPath, SEED_FILE);
    boolean exists = check db->queryRow(`SELECT to_regclass('public.schema_version') IS NOT NULL`);
    map<string> recorded = exists ? check readRecorded(db) : {};
    if !exists {
        log:printInfo("public.schema_version doesn't exist yet; every script is pending");
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
# + db - Client connected as the bootstrap admin
# + return - Version key to checksum, or an error
function readRecorded(postgresql:Client db) returns map<string>|error {
    map<string> recorded = {};
    stream<record {|string version; string checksum;|}, sql:Error?> rows = db->query(
        `SELECT version, checksum FROM public.schema_version`);
    check from record {|string version; string checksum;|} row in rows
        do {
            recorded[row.version] = row.checksum;
        };
    return recorded;
}

# SHA-256 of a script, hex.
#
# + content - Script text
# + return - Checksum as stored in `public.schema_version`
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

# Version key of a script: its name without `.sql`, for example `V001__schemas_roles`.
#
# + script - File name
# + return - Version key
function versionOf(string script) returns string => script.substring(0, script.length() - 4);

# Stops before any script runs when the server is older than the scripts need, instead of recording V001 and
# failing on V002.
#
# + db - Client connected as the bootstrap admin
# + return - An error when the server is too old or can't be asked
function checkServerVersion(postgresql:Client db) returns error? {
    int versionNum = check db->queryRow(`SELECT current_setting('server_version_num')::int`);
    if versionNum < MIN_SERVER_VERSION_NUM {
        return error(string `Amplify needs PostgreSQL 18 or later (uuidv7); the server reports version number ${versionNum}`);
    }
}

# V001 grants `amplify_migrate` to whoever ran it, and later scripts `SET LOCAL ROLE amplify_migrate`. When the
# bootstrap login has changed since (`dbUser` rotated), those scripts would fail with a bare "permission denied
# to set role"; say why instead. Skipped on a fresh database, where V001 has not created the role yet.
#
# + db - Client connected as the bootstrap admin
# + return - An error when V001 ran but this login can't switch to `amplify_migrate`
function checkBootstrapRole(postgresql:Client db) returns error? {
    boolean v001Recorded = check db->queryRow(
            `SELECT EXISTS (SELECT 1 FROM public.schema_version WHERE version = 'V001__schemas_roles')`);
    if !v001Recorded {
        return;
    }
    boolean canSwitch = check db->queryRow(`SELECT pg_has_role(current_user, 'amplify_migrate', 'SET')`);
    if !canSwitch {
        return error("This login cannot SET ROLE amplify_migrate: V001 granted the role to the login that first ran "
            + "it, and V001 is already recorded so it will not grant again. Run as that login, or grant it: "
            + "GRANT amplify_migrate TO <this login> WITH SET TRUE");
    }
}

# Creates `public.schema_version` once. Under the same advisory lock the scripts use, so two runners starting
# on an empty database can't race on the CREATE.
#
# + db - Client connected as the bootstrap admin
# + return - An error on failure
function ensureVersionTable(postgresql:Client db) returns error? {
    transaction {
        _ = check db->queryRow(`SELECT 1 FROM (SELECT pg_advisory_xact_lock(${MIGRATE_LOCK_KEY})) l`, int);
        _ = check db->execute(`
            CREATE TABLE IF NOT EXISTS public.schema_version (
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

function applyScript(postgresql:Client db, string dir, string script, ScriptKind kind, RunSummary summary)
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
        string|sql:Error recorded = db->queryRow(`SELECT checksum FROM public.schema_version WHERE version = ${version}`);
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
            // Scripts switch to amplify_migrate with SET LOCAL ROLE; record the version as the runner.
            sql:ProcedureCallResult reset = check db->call(`RESET ROLE`);
            check reset.close();
            int elapsed = <int>(time:utcDiffSeconds(time:utcNow(), started) * 1000);
            _ = check db->execute(`
                INSERT INTO public.schema_version (version, kind, checksum, execution_ms)
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

# Sets LOGIN passwords for the app roles. The password is a bind parameter; the database function
# quotes it with format(%L). Empty secrets are skipped.
#
# + db - Client connected as the bootstrap admin
# + passwords - Role name to password
# + return - An error on failure
public function setRolePasswords(postgresql:Client db, map<string> passwords) returns error? {
    foreach [string, string] [role, password] in passwords.entries() {
        if password.length() == 0 {
            log:printInfo(string `No password configured for ${role}; left unchanged`);
            continue;
        }
        _ = check db->queryRow(`SELECT 1 FROM (SELECT public.amplify_set_login_password(${role}, ${password})) p`, int);
        log:printInfo(string `Password set for ${role}`);
    }
}
