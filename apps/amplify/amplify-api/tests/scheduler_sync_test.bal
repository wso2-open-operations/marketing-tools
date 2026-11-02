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

// SchedulerSync (ADR-026): a settings save commits first and pushes after; a scheduler outage leaves the
// save standing with `PENDING`; reconcile converges; the admin sync endpoint. The IT (group
// `scheduler-it`, `AMPLIFY_IT=true`, run by scripts/it-scheduler.sh) does the same against the real
// akorn/scheduler image and a stub amplify-jobs.

import amplify_api.scheduler;
import amplify_common.resilience;
import amplify_domain.store;

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/os;
import ballerina/test;
import ballerina/time;

// ---- Fakes ----------------------------------------------------------------------------------------

# Ordered log of saves and pushes, to prove the push follows the commit.
isolated string[] syncEvents = [];

isolated function logEvent(string e) {
    lock {
        syncEvents.push(e);
    }
}

isolated function takeEvents() returns string[] {
    lock {
        string[] out = syncEvents;
        syncEvents = [];
        return out.clone();
    }
}

# In-memory scheduler: holds jobs by id, can be switched off.
isolated class FakeScheduler {
    *scheduler:Api;

    private boolean up = true;
    private map<scheduler:JobSpec> jobs = {};

    isolated function setUp(boolean up) {
        lock {
            self.up = up;
        }
    }

    isolated function job(string id) returns scheduler:JobSpec? {
        lock {
            return self.jobs[id].clone();
        }
    }

    isolated function put(scheduler:JobSpec spec) {
        lock {
            self.jobs[spec.id] = spec.clone();
        }
    }

    isolated function clear() {
        lock {
            self.jobs = {};
        }
    }

    public isolated function ensureCollection(string id, string name, string? correlationId = ()) returns error? {
        lock {
            if !self.up {
                return error("connection refused");
            }
        }
    }

    public isolated function upsertJob(string collectionId, scheduler:JobSpec spec, string? correlationId = ())
            returns scheduler:UpsertResult|error {
        // The real client builds and checks the payload first; so does the fake.
        _ = check scheduler:jobPayload(collectionId, spec);
        lock {
            if !self.up {
                return error("connection refused");
            }
            scheduler:JobSpec? old = self.jobs[spec.id];
            self.jobs[spec.id] = spec.clone();
            logEvent("push:" + spec.id + "=" + spec.schedule);
            return old is () ? "CREATED" : old == spec ? "UNCHANGED" : "UPDATED";
        }
    }

    public isolated function breakerState() returns resilience:BreakerState => "CLOSED";
}

final FakeScheduler fakeScheduler = new;

# A real client for the IT, `()` otherwise.
isolated scheduler:Api? itScheduler = ();

@test:Mock {functionName: "schedulerApi"}
isolated function mockSchedulerApi() returns scheduler:Api? {
    lock {
        scheduler:Api? real = itScheduler;
        if real !is () {
            return real;
        }
    }
    return fakeScheduler;
}

isolated boolean saveFails = false;
# When set, the save answers the optimistic-lock conflict the real `store:updateSettings` raises.
isolated boolean saveConflicts = false;

function setSaveConflicts(boolean enabled) {
    lock {
        saveConflicts = enabled;
    }
}

@test:Mock {functionName: "saveSettings"}
isolated function mockSaveSettings(store:Actor actor, store:SettingChange[] changes) returns error? {
    lock {
        if saveFails {
            return error("version conflict");
        }
    }
    boolean failWithConflict;
    lock {
        failWithConflict = saveConflicts;
    }
    if failWithConflict {
        return store:versionConflict("setting " + changes[0].key);
    }
    readonly & store:SettingChange[] saved = changes.cloneReadOnly();
    final string who = actor.actorId;
    final time:Utc now = time:utcNow();
    lock {
        foreach store:SettingChange c in saved {
            store:Setting row = {key: c.key, value: c.value, updatedBy: who, updatedAt: now, version: c.expectedVersion + 1};
            int? at = ();
            foreach int i in 0 ..< fakeSettingRows.length() {
                if fakeSettingRows[i].key == c.key {
                    at = i;
                }
            }
            if at is int {
                fakeSettingRows[at] = row;
            } else {
                fakeSettingRows.push(row);
            }
        }
    }
    logEvent("commit");
}

isolated store:AuditEntry[] syncAudit = [];

@test:Mock {functionName: "recordAudit"}
isolated function mockRecordAudit(store:AuditEntry entry) returns error? {
    lock {
        syncAudit.push(entry.clone());
    }
}

function resetSync() {
    fakeScheduler.setUp(true);
    fakeScheduler.clear();
    lock {
        fakeSettingRows = [];
    }
    lock {
        saveFails = false;
    }
    lock {
        syncAudit = [];
    }
    _ = takeEvents();
}

function adminToken() returns string|error => mint({sub: "adm-0001", email: "adm@wso2.com", groups: [ADMIN_GROUP]});

function putSetting(string key, json value) returns http:Response|error =>
    send("PUT", "/admin/settings", {changes: [{key, value, version: 1}]}, check adminToken());

// ---- Unit: use case ----------------------------------------------------------------------------------

@test:Config {groups: ["scheduler"]}
function testScheduleChangeCommitsThenPushes() returns error? {
    resetSync();
    http:Response res = check putSetting("run.schedule", "*/10 * * * *");
    test:assertEquals(res.statusCode, 200);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.schedulerSync, "SYNCED");
    test:assertEquals(takeEvents(), ["commit", "push:amplify-run=*/10 * * * *", "push:amplify-maintenance-partitions=0 2 * * *"]);
    scheduler:JobSpec run = check fakeScheduler.job(JOB_RUN).ensureType();
    test:assertEquals(run.uri, "http://amplify-jobs:9598/runs");
    test:assertEquals(run.deadlineSeconds, 300, "deadline outlives runMaxSeconds (240)");
    lock {
        test:assertEquals(syncAudit.length(), 1);
        test:assertEquals(syncAudit[0].action, "SchedulerSynced");
        test:assertEquals(syncAudit[0].actorId, "adm-0001");
    }
}

@test:Config {groups: ["scheduler"]}
function testRunEnabledFalseDisablesJob() returns error? {
    resetSync();
    http:Response res = check putSetting("run.enabled", false);
    test:assertEquals(res.statusCode, 200);
    scheduler:JobSpec run = check fakeScheduler.job(JOB_RUN).ensureType();
    test:assertFalse(run.enabled);
}

@test:Config {groups: ["scheduler"]}
function testSchedulerDownSaveStillSucceeds() returns error? {
    resetSync();
    fakeScheduler.setUp(false);
    http:Response res = check putSetting("maintenance.schedule", "30 3 * * *");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(check (check res.getJsonPayload()).schedulerSync, "PENDING");
    test:assertEquals(takeEvents(), ["commit"]);

    // Reconcile after the scheduler is back converges to the saved value; a second run changes nothing.
    fakeScheduler.setUp(true);
    SchedulerSyncResult first = syncScheduler((), "test");
    test:assertEquals(first.status, "SYNCED");
    test:assertEquals(first.jobs.map(j => j.result), ["CREATED", "CREATED"]);
    test:assertEquals((check fakeScheduler.job(JOB_MAINTENANCE).ensureType(scheduler:JobSpec)).schedule, "30 3 * * *");
    SchedulerSyncResult again = syncScheduler((), "test");
    test:assertEquals(again.jobs.map(j => j.result), ["UNCHANGED", "UNCHANGED"]);
}

@test:Config {groups: ["scheduler"]}
function testReconcileFixesDriftedJob() returns error? {
    resetSync();
    // Someone edited the job in the scheduler UI.
    scheduler:JobSpec drifted = desiredJobs({})[0];
    drifted.schedule = "@every 1m";
    fakeScheduler.put(drifted);
    SchedulerSyncResult result = syncScheduler((), "test");
    test:assertEquals(result.jobs.map(j => j.result), ["UPDATED", "CREATED"]);
    test:assertEquals((check fakeScheduler.job(JOB_RUN).ensureType(scheduler:JobSpec)).schedule, "@every 5m");
}

@test:Config {groups: ["scheduler"]}
function testFailedSaveDoesNotPush() returns error? {
    resetSync();
    lock {
        saveFails = true;
    }
    http:Response res = check putSetting("run.schedule", "@every 2m");
    test:assertNotEquals(res.statusCode, 200);
    test:assertEquals(takeEvents(), []);
}

@test:Config {groups: ["scheduler"]}
function testOtherSettingsDoNotPush() returns error? {
    resetSync();
    http:Response res = check putSetting("leaderboard.top_n", 5);
    test:assertEquals(res.statusCode, 200);
    test:assertFalse((check res.getJsonPayload()).schedulerSync is json, "no schedulerSync when no schedule changed");
    test:assertEquals(takeEvents(), ["commit"]);
}

@test:Config {groups: ["scheduler"]}
function testScheduleValidatedBeforeSave() returns error? {
    resetSync();
    foreach [string, json] [key, value] in [
        ["run.schedule", "@every 5s"],
        ["run.schedule", "61 * * * *"],
        ["run.schedule", "CRON_TZ=Asia/Colombo 0 2 * * *"],
        ["run.schedule", 5],
        ["maintenance.schedule", "@every 10m"],
        ["maintenance.schedule", "0 2 * *"]
    ] {
        http:Response res = check putSetting(key, value);
        test:assertEquals(check codeIn(res), "INVALID_SETTING", string `${key}=${value.toString()}`);
    }
    test:assertEquals(takeEvents(), [], "nothing saved or pushed");
}

@test:Config {groups: ["scheduler"]}
function testAdminSyncEndpoint() returns error? {
    resetSync();
    string token = check adminToken();
    http:Response ok = check send("POST", "/admin/scheduler/sync", {}, token);
    test:assertEquals(ok.statusCode, 200);
    json body = check ok.getJsonPayload();
    test:assertEquals(check body.schedulerSync, "SYNCED");
    test:assertEquals((<json[]>check body.jobs).length(), 2);

    fakeScheduler.setUp(false);
    http:Response down = check send("POST", "/admin/scheduler/sync", {}, token);
    test:assertEquals(down.statusCode, 503);
    test:assertEquals(check codeIn(down), "SCHEDULER_UNAVAILABLE");

    http:Response asPo = check send("POST", "/admin/scheduler/sync", {}, check po());
    test:assertEquals(asPo.statusCode, 403);
}

// ---- Integration: real scheduler (scripts/it-scheduler.sh) -------------------------------------------

final boolean schedulerItEnabled = os:getEnv("AMPLIFY_IT") == "true" && os:getEnv("AMPLIFY_IT_SCHEDULER_URL") != "";

isolated int stubRuns = 0;
# The key header the scheduler sent on the last POST /runs (the IT asserts it is the scheduler key).
isolated string? stubRunKey = ();

# Stub amplify-jobs the scheduler calls in the IT.
service / on new http:Listener(9598) {
    resource function post runs(@http:Header {name: INTERNAL_KEY_HEADER} string? key) returns http:Ok {
        lock {
            stubRuns += 1;
        }
        lock {
            stubRunKey = key;
        }
        return {body: {status: "COMPLETED"}};
    }

    resource function post maintenance/partitions() returns http:Ok => {body: {}};
}

@test:Config {groups: ["scheduler-it"], enable: schedulerItEnabled}
function testRealSchedulerReconcileUpdateAndFire() returns error? {
    resetSync();
    string url = os:getEnv("AMPLIFY_IT_SCHEDULER_URL");
    scheduler:Client real = check new (url, 5);
    lock {
        itScheduler = real;
    }
    do {
        http:Client raw = check new (url);
        // Reconcile on an empty scheduler creates both jobs (run hourly first, so it doesn't fire yet).
        lock {
            fakeSettingRows = [{key: "run.schedule", value: "@every 1h", updatedBy: "it", updatedAt: time:utcNow(), version: 1}];
        }
        SchedulerSyncResult created = syncScheduler((), "it-reconcile");
        test:assertEquals(created.status, "SYNCED");
        test:assertEquals(created.jobs.map(j => j.result), ["CREATED", "CREATED"]);
        test:assertEquals(syncScheduler((), "it-again").jobs.map(j => j.result), ["UNCHANGED", "UNCHANGED"]);
        json maintenance = check raw->get("/jobs/amplify-maintenance-partitions");
        test:assertEquals(check maintenance.schedule, "0 2 * * *");
        test:assertEquals(check maintenance.collectionId, "amplify");

        // The admin changes the interval through the API: the scheduler job follows.
        http:Response res = check putSetting("run.schedule", "@every 10s");
        test:assertEquals(check (check res.getJsonPayload()).schedulerSync, "SYNCED");
        json run = check raw->get("/jobs/amplify-run");
        test:assertEquals(check run.schedule, "@every 10s");
        test:assertEquals(check run.state, "enabled");

        // The scheduler calls the stub amplify-jobs POST /runs.
        int fired = 0;
        foreach int i in 0 ..< 45 {
            lock {
                fired = stubRuns;
            }
            if fired > 0 {
                break;
            }
            runtime:sleep(1);
        }
        test:assertTrue(fired > 0, "scheduler fired POST /runs within 45 s");
        string? sentKey;
        lock {
            sentKey = stubRunKey;
        }
        test:assertEquals(sentKey, schedulerApiKey, "the real scheduler sends the scheduler key, not the internal key");
        json history = check raw->get("/jobs/amplify-run/history");
        test:assertTrue((<json[]>check history.items).length() > 0);
    } on fail error e {
        lock {
            itScheduler = ();
        }
        return e;
    }
    lock {
        itScheduler = ();
    }
}

@test:Config
function testRegisteredJobsCarryTheSchedulerKeyNotTheInternalKey() {
    test:assertNotEquals(schedulerApiKey, internalApiKey);
    foreach scheduler:JobSpec spec in desiredJobs({}) {
        test:assertEquals(spec.headers, [{name: INTERNAL_KEY_HEADER, value: schedulerApiKey}], spec.id);
        foreach scheduler:Header h in spec.headers {
            test:assertNotEquals(h.value, internalApiKey, spec.id + " must not carry the full-access key");
        }
    }
}

@test:Config
function testKeysAreRequiredWhereUsedAndMustDiffer() {
    string i = internalApiKey;
    string s = schedulerApiKey;
    test:assertTrue(checkApiKeys("http://jobs", "", "", s) is error, "jobs needs the internal key");
    test:assertTrue(checkApiKeys("http://jobs", "", "short", s) is error);
    test:assertTrue(checkApiKeys("", "http://scheduler", i, "") is error, "scheduler needs the scheduler key");
    test:assertTrue(checkApiKeys("", "http://scheduler", i, "short") is error);
    test:assertTrue(checkApiKeys("http://jobs", "http://scheduler", i, i) is error, "same value");
    test:assertTrue(checkApiKeys("http://jobs", "http://scheduler", i, i + "\n") is error, "same value after trim");
    test:assertEquals(checkApiKeys("http://jobs", "http://scheduler", i, s), ());
    test:assertEquals(checkApiKeys("", "", "", ""), (), "nothing to call, nothing to authenticate");
}

@test:Config
function testSchedulerWithNoJobTargetIsRefused() {
    // Both job URLs empty: every job's URI would be just "/runs". One clear startup error, not one per job.
    test:assertTrue(schedulerTargetError("", "") is error, "both empty: the scheduler has nowhere to call");
    test:assertTrue(schedulerTargetError("   ", "") is error);
    test:assertEquals(schedulerTargetError("http://amplify-jobs:9598", ""), (), "schedulerJobsUrl is enough");
    test:assertEquals(schedulerTargetError("", "http://amplify-jobs:9598"), (), "jobsUrl is enough");
}
