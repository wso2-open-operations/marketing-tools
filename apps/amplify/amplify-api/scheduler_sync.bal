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

// SchedulerSync (ADR-026): the database settings are the source of truth; the scheduler holds a copy as two
// jobs with stable ids. After a settings commit, at startup and on `POST /admin/scheduler/sync`, amplify-api
// reads the settings and upserts both jobs. The scheduler being down never fails a settings save: the
// answer says `PENDING` and the next reconcile converges.

import amplify_api.auth;
import amplify_api.scheduler;
import amplify_common.resilience;
import amplify_domain.store;

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/log;

# Scheduler base URL (Project visibility / internal network only, ADR-026). Empty = not configured:
# schedule changes are saved and reported as `NOT_CONFIGURED`.
configurable string schedulerUrl = "";
# Scheduler call timeout, seconds.
configurable decimal schedulerTimeoutSeconds = 5;
# Scheduler breaker and pool.
configurable resilience:HttpResilience schedulerResilience = {requestVolumeThreshold: 2};
# amplify-jobs base URL as the scheduler reaches it. Empty = `jobsUrl`.
configurable string schedulerJobsUrl = "";
# Scheduler collection holding the Amplify jobs.
configurable string schedulerCollection = "amplify";
# Deadline the scheduler gives one `POST /runs` call and its retries, seconds. `POST /runs` is synchronous,
# so this must be longer than amplify-jobs `runMaxSeconds` (240) or the scheduler cancels a healthy run.
configurable int runDeadlineSeconds = 300;
# Deadline for `POST /maintenance/partitions`, seconds.
configurable int maintenanceDeadlineSeconds = 180;
# Shortest `@every` interval an admin may set for `run.schedule`, seconds.
configurable int minRunIntervalSeconds = 60;
# Startup reconcile attempts (the scheduler or the database may start after amplify-api).
configurable int reconcileAttempts = 20;
# Wait between startup reconcile attempts, seconds.
configurable decimal reconcileDelaySeconds = 15;

final scheduler:Api? schedulerClient = check newSchedulerClient();

isolated function newSchedulerClient() returns scheduler:Api?|error {
    if schedulerUrl == "" {
        return ();
    }
    if runDeadlineSeconds < 1 || maintenanceDeadlineSeconds < 1 {
        return error("runDeadlineSeconds and maintenanceDeadlineSeconds must be positive");
    }
    check schedulerTargetError(schedulerJobsUrl, jobsUrl);
    return check new scheduler:Client(schedulerUrl, schedulerTimeoutSeconds, schedulerResilience);
}

# Refuses a configured scheduler with no target for its jobs: every job's URI would be just "/runs", which
# would log an error per job on every reconcile and answer 503 on /admin/scheduler/sync for what is a
# configuration mistake. One clear startup error instead.
#
# + schedulerJobsUrl - amplify-jobs URL as the scheduler reaches it
# + jobsUrl - fallback amplify-jobs URL
# + return - An error when both are empty
isolated function schedulerTargetError(string schedulerJobsUrl, string jobsUrl) returns error? {
    if schedulerJobsUrl.trim() != "" || jobsUrl.trim() != "" {
        return ();
    }
    return error("schedulerUrl is set but neither schedulerJobsUrl nor jobsUrl is: the scheduler has nowhere to call");
}

# Test seam: the scheduler client.
#
# + return - The client, or `()` when not configured
isolated function schedulerApi() returns scheduler:Api? => schedulerClient;

# Sync outcome. `SYNCED`: the scheduler matches the settings. `PENDING`: it couldn't be reached or refused;
# startup reconcile or `POST /admin/scheduler/sync` converges it. `NOT_CONFIGURED`: no scheduler URL.
type SyncStatus "SYNCED"|"PENDING"|"NOT_CONFIGURED";

# What a sync did to one job (openapi `SchedulerSync.jobs.result`).
type JobResult scheduler:UpsertResult|"FAILED"|"SKIPPED";

# One job's outcome.
type SchedulerJobResult record {|
    # Stable job id
    string id;
    # Schedule pushed
    string schedule;
    # Whether the job fires
    boolean enabled;
    # `CREATED`, `UPDATED`, `UNCHANGED`, `FAILED` or `SKIPPED`
    JobResult result;
|};

# Result of one sync.
type SchedulerSyncResult record {|
    # Overall status
    SyncStatus status;
    # Per job
    SchedulerJobResult[] jobs;
|};

# The scheduler jobs the settings call for.
#
# + s - Settings
# + return - Job specs
isolated function desiredJobs(Settings s) returns scheduler:JobSpec[] {
    string base = schedulerJobsUrl.trim() != "" ? schedulerJobsUrl.trim() : jobsUrl.trim();
    if base.endsWith("/") {
        base = base.substring(0, base.length() - 1);
    }
    return [
        {
            id: JOB_RUN,
            name: "Amplify Run",
            schedule: s.runSchedule,
            enabled: s.runEnabled,
            uri: base + "/runs",
            // One retry for a 5xx or a dropped connection; 202 SKIPPED (run in progress) is a success.
            retryCount: 1,
            retryIntervalSeconds: 30,
            deadlineSeconds: runDeadlineSeconds,
            headers: schedulerKeyHeaders()
        },
        {
            id: JOB_MAINTENANCE,
            name: "Amplify partition maintenance",
            schedule: s.maintenanceSchedule,
            uri: base + "/maintenance/partitions",
            retryCount: 2,
            retryIntervalSeconds: 60,
            deadlineSeconds: maintenanceDeadlineSeconds,
            headers: schedulerKeyHeaders()
        }
    ];
}

// Serializes syncs, so two admins saving at once push in commit order: each sync reads the settings
// after taking the lock, so the last one pushes the latest committed state.
isolated int syncCount = 0;

# Pushes the settings to the scheduler. Never fails: an unreachable scheduler gives `PENDING`.
#
# + s - Settings to push, or `()` to read them now (inside the lock)
# + correlationId - Sent to the scheduler
# + return - Outcome
isolated function syncScheduler(Settings? s, string? correlationId) returns SchedulerSyncResult {
    scheduler:Api? api = schedulerApi();
    if api is () {
        return {status: "NOT_CONFIGURED", jobs: []};
    }
    readonly & Settings? given = s.cloneReadOnly();
    lock {
        syncCount += 1;
        // Fresh from the database, never the 5 s cache: a reader may have cached the rows from just before
        // the commit this sync follows, and pushing those would report SYNCED with the old schedule.
        Settings|error settings = given is Settings ? given : freshSettings();
        if settings is error {
            log:printError("Scheduler sync: settings unreadable", resilience:loggable(settings),
                    correlationId = correlationId);
            return {status: "PENDING", jobs: []};
        }
        return pushJobs(api, settings.cloneReadOnly(), correlationId).cloneReadOnly();
    }
}

isolated function pushJobs(scheduler:Api api, Settings settings, string? correlationId) returns SchedulerSyncResult {
    scheduler:JobSpec[] specs = desiredJobs(settings);
    SchedulerJobResult[] jobs = from scheduler:JobSpec j in specs
        select {id: j.id, schedule: j.schedule, enabled: j.enabled, result: "SKIPPED"};
    if api.breakerState() == "OPEN" {
        log:printWarn("Scheduler sync deferred: breaker open", correlationId = correlationId);
        return {status: "PENDING", jobs};
    }
    error? collection = api.ensureCollection(schedulerCollection, "Amplify", correlationId);
    if collection is error {
        log:printError("Scheduler sync: collection", collection, correlationId = correlationId);
        return {status: "PENDING", jobs};
    }
    SyncStatus status = "SYNCED";
    foreach int i in 0 ..< specs.length() {
        scheduler:UpsertResult|error result = api.upsertJob(schedulerCollection, specs[i], correlationId);
        if result is error {
            log:printError("Scheduler sync: job", result, job = specs[i].id, correlationId = correlationId);
            jobs[i].result = "FAILED";
            status = "PENDING";
        } else {
            jobs[i].result = result;
        }
    }
    log:printInfo("Scheduler sync", status = status, jobs = jobs.toString(), correlationId = correlationId);
    return {status, jobs};
}

# Whether a change list touches a schedule setting.
#
# + keys - Changed keys
# + return - True when the scheduler needs a push
isolated function touchesSchedule(string[] keys) returns boolean {
    foreach string k in keys {
        if SCHEDULE_SETTINGS.indexOf(k) !is () {
            return true;
        }
    }
    return false;
}

# Audits a push (`SchedulerSynced`), in its own transaction. A failed audit write is logged, not returned:
# the scheduler already changed.
#
# + actor - Who caused it (`system` at startup)
# + result - Outcome
isolated function auditSync(store:Actor actor, SchedulerSyncResult result) {
    if result.status == "NOT_CONFIGURED" {
        return;
    }
    error? written = recordAudit(store:auditOf(actor, "SchedulerSynced", "scheduler.job", schedulerCollection,
            result.toJson()));
    if written is error {
        log:printError("Scheduler sync audit not written", resilience:loggable(written),
                correlationId = actor.correlationId);
    }
}

# Startup reconcile: retries until the scheduler matches the settings or the attempts run out.
isolated function reconcileAtStartup() {
    if schedulerUrl == "" {
        log:printInfo("Scheduler not configured (schedulerUrl empty); schedules aren't pushed");
        return;
    }
    foreach int attempt in 1 ... reconcileAttempts {
        SchedulerSyncResult result = syncScheduler((), "startup-reconcile");
        if result.status != "PENDING" {
            auditSync(store:SYSTEM, result);
            return;
        }
        log:printWarn("Scheduler reconcile pending; retrying", attempt = attempt, of = reconcileAttempts);
        runtime:sleep(reconcileDelaySeconds);
    }
    log:printError(string `Scheduler reconcile gave up after ${reconcileAttempts} attempts; use POST /admin/scheduler/sync`);
}

# `POST /admin/scheduler/sync`: converge the scheduler to the settings now.
#
# + p - Admin
# + correlationId - Correlation id
# + return - 200 with the outcome, or 503 when the scheduler can't be reached
isolated function syncSchedulerNow(auth:Principal p, string? correlationId) returns http:StatusCodeResponse {
    SchedulerSyncResult result = syncScheduler((), correlationId);
    auditSync(actorOf(p, correlationId), result);
    if result.status == "PENDING" {
        return <http:ServiceUnavailable>{
            mediaType: PROBLEM_JSON,
            body: problem(503, "Service Unavailable", SCHEDULER_UNAVAILABLE,
                    "The scheduler couldn't be updated; the settings are saved, try the sync again shortly",
                    correlationId)
        };
    }
    return <http:Ok>{body: {schedulerSync: result.status, jobs: result.jobs.toJson()}};
}
