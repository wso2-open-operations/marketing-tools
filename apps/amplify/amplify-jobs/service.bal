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
import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.recognition;
import amplify_domain.store;

import ballerina/http;
import ballerina/log;
import ballerinax/postgresql;

# Port the worker listens on (Project visibility only, never published).
configurable int port = 9091;

listener http:Listener jobsListener = new (port);

# Returned when another partition maintenance pass holds the lock.
type MaintenanceSkipped record {|
    # `SKIPPED`
    string status = "SKIPPED";
    # `MAINTENANCE_IN_PROGRESS`
    string reason = "MAINTENANCE_IN_PROGRESS";
|};

function init() returns error? {
    check checkKeys(internalApiKey, schedulerApiKey);
    check validateSweepConfig(sweepConfig(), peopleDirectoryUrl.trim() != "");
    // The database may still be starting: create the next two weeks of token partitions in the background.
    _ = start ensurePartitionsAtStartup();
    check validateRunConfig(runConfig(), longestCallSeconds());
    log:printInfo(string `${COMPONENT} starting on port ${port}`);
    string? tls = store:tlsWarning(dbConfig());
    if tls is string {
        log:printWarn(tls);
    }
}

# Amplify worker. No internal timer: the scheduler (ADR-026) and "Save & Share Now" call it (ADR-003).
@display {
    label: "Amplify Jobs",
    id: "amplify/amplify-jobs"
}
service http:InterceptableService / on jobsListener {

    public function createInterceptors() returns InternalKeyInterceptor => new;

    # Liveness probe.
    #
    # + return - Component health
    resource function get health() returns types:HealthStatus => {component: COMPONENT, status: types:UP};

    # Readiness probe: the database breaker isn't open and the database answers. LinkedIn, Chat and the
    # token keys are reported but don't fail readiness (a run defers those rows, ADR-025). Each probe also
    # refreshes the `amplify_breaker_state` gauges (ADR-028).
    #
    # A database blip (breaker open for a few seconds) keeps the worker in rotation: Choreo stops routing on
    # any non-2xx readiness response, and `POST /runs` already answers a clean, scheduler-retryable 503 while
    # the database is unavailable. Only a missing database configuration is 503.
    #
    # + return - Readiness with the checks; 503 only when the database isn't configured
    resource function get ready() returns http:Ok|http:ServiceUnavailable {
        boolean database = dbBreaker.state() != "OPEN" && dbReachable();
        map<string> breakers = breakerStates();
        resilience:exportBreakerStates(COMPONENT, breakers);
        postgresql:Client|error pg = database ? db() : error("database down");
        ReadyReport body = readiness(database, breakers, isRunInProgress(), pg is postgresql:Client ? outboxReport(pg) : (),
                pg is postgresql:Client ? tokenPartitionReport(pg) : ());
        return readyKeepsRouting(dbHost.trim() != "") ? <http:Ok>{body} : <http:ServiceUnavailable>{body};
    }

    # Runs the outbox once (announcements, sharing, scoring) and returns the run log. Safe to call any time
    # and concurrently: a second caller gets 202 `SKIPPED` while a run is in progress (here or on another
    # replica). Any scheduler can call it (ADR-003).
    #
    # + correlationId - Trigger correlation id (`X-Correlation-ID`), logged with the run
    # + return - The run log, 202 when another run is in progress, 503 when the database isn't reachable,
    # or 500
    resource function post runs(@http:Header {name: "X-Correlation-ID"} string? correlationId)
            returns RunReport|http:Accepted|http:ServiceUnavailable|http:InternalServerError {
        postgresql:Client|error dbc = db();
        postgresql:Client|error lockDbc = lockDb();
        if dbc is error || lockDbc is error {
            log:printError("Run: database unavailable", resilience:loggable(dbc is error ? dbc : <error>lockDbc));
            return <http:ServiceUnavailable>{body: {message: "Database unavailable"}};
        }
        RunReport|RunSkipped|error result = runOnce(productionDeps(new PgRunStore(dbc), new PgRunLock(lockDbc)),
                correlationId);
        if result is error {
            recordDbFailure(result);
            log:printError("Run failed", resilience:loggable(result), correlationId = correlationId);
            return <http:InternalServerError>{body: {message: "Run failed"}};
        }
        if result is RunSkipped {
            log:printInfo("Run skipped: another run is in progress", correlationId = correlationId);
            return <http:Accepted>{body: result};
        }
        return result;
    }

    # Daily upkeep (B10): token and audit partitions ahead, expired token days and audit months past
    # retention dropped (each audited), DONE outbox rows purged, expired OAuth states swept.
    #
    # Also purges expired `Idempotency-Key` records (ADR-024 item 3) and re-seals token rows written under
    # an older key with the active one (key rotation; the result is in `token_rotation`, never fatal).
    #
    # One pass at a time across replicas: a pass that outlives the scheduler's deadline is not started again
    # by its retry (a second 10k-row reseal sweep, a second partition drop); the retry gets 202 `SKIPPED`.
    #
    # + return - What was done, 202 when another pass is in progress, 503 when the database isn't reachable,
    # or 500
    resource function post maintenance/partitions()
            returns MaintenanceReport|MaintenanceSkipped|http:Accepted|http:ServiceUnavailable|http:InternalServerError {
        postgresql:Client|error dbc = maintenanceDb();
        if dbc is error {
            log:printError("Partition maintenance: database unavailable", resilience:loggable(dbc));
            return <http:ServiceUnavailable>{body: {message: "Database unavailable"}};
        }
        PgRunLock guard = new (dbc, MAINTENANCE_LOCK_KEY);
        boolean|error acquired = guard.tryAcquire();
        if acquired is error {
            log:printError("Partition maintenance: could not take the maintenance lock", resilience:loggable(acquired));
            return <http:ServiceUnavailable>{body: {message: "Database unavailable"}};
        }
        if !acquired {
            log:printInfo("Partition maintenance skipped: another pass is in progress");
            return <http:Accepted>{body: <MaintenanceSkipped>{}};
        }
        // `trap`: however the pass ends (error or panic), the session lock is released below.
        MaintenanceReport|error result = trap runMaintenance(dbc);
        error? released = guard.release();
        if released is error {
            log:printError("Maintenance lock release failed (the session drop releases it)", released);
        }
        if result is error {
            recordDbFailure(result);
            log:printError("Partition maintenance failed", resilience:loggable(result));
            return <http:InternalServerError>{body: {message: "Partition maintenance failed"}};
        }
        log:printInfo(string `Partition maintenance done: ${result.toString()}`);
        return result;
    }

    # Runs only the leaver sweep (the daily maintenance run includes it). With `leaverSweepMode = DRY_RUN` it
    # reports who would be erased; with `OFF` it does nothing.
    #
    # + return - What the sweep did, 503 when the database isn't reachable
    resource function post maintenance/leavers() returns LeaverSweepReport|http:ServiceUnavailable {
        postgresql:Client|error dbc = db();
        if dbc is error {
            log:printError("Leaver sweep: database unavailable", resilience:loggable(dbc));
            return <http:ServiceUnavailable>{body: {message: "Database unavailable"}};
        }
        return runConfiguredSweep(dbc);
    }

    # Rebuilds every recognition read model from the ledger (recognition is never a source of truth).
    #
    # + return - The new standing version, 503 when the database isn't reachable, or 500
    resource function post maintenance/rebuild\-recognition()
            returns RebuildResult|http:ServiceUnavailable|http:InternalServerError {
        postgresql:Client|error dbc = db();
        if dbc is error {
            log:printError("Recognition rebuild: database unavailable", resilience:loggable(dbc));
            return <http:ServiceUnavailable>{body: {message: "Database unavailable"}};
        }
        int|error version = recognition:rebuild(dbc, leaderboardTopN);
        if version is error {
            recordDbFailure(version);
            log:printError("Recognition rebuild failed", resilience:loggable(version));
            return <http:InternalServerError>{body: {message: "Recognition rebuild failed"}};
        }
        log:printInfo(string `Recognition rebuilt, standing version ${version}`);
        return {standingVersion: version};
    }
}

# The partition maintenance steps, in the order B10 lists them. Kept in one function so the resource can
# release the maintenance lock however the pass ends (an error or a panic, through `trap`).
#
# + dbc - The maintenance client
# + return - What was done, or an error naming the step that failed
isolated function runMaintenance(postgresql:Client dbc) returns MaintenanceReport|error {
    store:MaintenanceResult result = check store:runPartitionMaintenance(dbc);
    int|error purged = store:purgeExpiredIdempotencyKeys(dbc);
    if purged is error {
        return error("Idempotency key purge failed", purged);
    }
    TokenRotation rotation = rotateTokenKeys(tokenCipher, new connection:PgTokenRepository(dbc));
    // Never fatal and off by default: the sweep reports what it did (or why it did nothing).
    LeaverSweepReport leavers = runConfiguredSweep(dbc);
    return {...result, idempotency_keys_purged: purged, token_rotation: rotation, leaver_sweep: leavers};
}
