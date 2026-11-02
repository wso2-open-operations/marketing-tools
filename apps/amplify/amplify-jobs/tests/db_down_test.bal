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

// DB down mid-run (plan M11, ADR-028): group `db-down-it`, needs `AMPLIFY_IT=true` and
// `AMPLIFY_IT_PG_CONTAINER` (the Postgres container the IT uses; `scripts/test-all.sh` sets both). A run
// claims rows, the database is stopped after the first row settles, and the run must end in an error
// (no panic, no row lost). The error is transient, so it feeds the DB breaker; the breaker opens on failed
// probes, stays open while Postgres is down, and closes through the half-open trial once it's back. The
// next run (after the lease) settles every row exactly once.

import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.store;

import ballerina/lang.runtime;
import ballerina/os;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

final string pgContainer = os:getEnv("AMPLIFY_IT_PG_CONTAINER");

function docker(string... args) returns error? {
    os:Process p = check os:exec({value: "docker", arguments: args});
    int code = check p.waitForExit();
    if code != 0 {
        return error(string `docker ${args[0]} exited ${code}`);
    }
}

# Delegates to the real store, but stops Postgres right after the first row is marked `DONE`.
isolated class StopDbAfterFirstRow {
    *RunStore;
    private final PgRunStore inner;
    private boolean stopped = false;

    isolated function init(PgRunStore inner) {
        self.inner = inner;
    }

    isolated function claim(string runId, int batchSize, int leaseSeconds) returns store:OutboxRow[]|error =>
        self.inner.claim(runId, batchSize, leaseSeconds);

    isolated function complete(int id, string runId) returns error? {
        boolean stopNow;
        lock {
            stopNow = !self.stopped;
            self.stopped = true;
        }
        if !stopNow {
            return self.inner.complete(id, runId);
        }
        check self.inner.complete(id, runId);
        check stopContainer();
    }

    isolated function requeue(int id, string runId, decimal delaySeconds, string? lastError, boolean countAttempt)
            returns error? => self.inner.requeue(id, runId, delaySeconds, lastError, countAttempt);

    isolated function failRow(int id, string runId, string lastError) returns error? =>
        self.inner.failRow(id, runId, lastError);

    isolated function releaseStale() returns int|error => self.inner.releaseStale();

    isolated function settings() returns RunSettings|error => self.inner.settings();

    isolated function connectionSweep() returns ConnectionSweep|error => self.inner.connectionSweep();

    isolated function publishedToday(time:Utc now) returns int|error => self.inner.publishedToday(now);

    isolated function forRow(string correlationId, int topN) returns Store => self.inner.forRow(correlationId, topN);
}

isolated function stopContainer() returns error? {
    os:Process p = check os:exec({value: "docker", arguments: ["stop", "-t", "2", pgContainer]});
    _ = check p.waitForExit();
}

function bareDeps(RunStore runStore, RunLock runLock, RunConfig cfg) returns Deps =>
    {runStore, runLock, chat: (), linkedIn: (), cipher: (), config: cfg, breakers: noBreakers};

function waitForDb(postgresql:Client db, decimal timeoutSeconds) returns boolean {
    decimal waited = 0;
    while waited < timeoutSeconds {
        if store:probe(db) is () {
            return true;
        }
        runtime:sleep(1);
        waited += 1d;
    }
    return false;
}

@test:Config {groups: ["db-down-it"], enable: itEnabled && pgContainer != ""}
function testDbDownMidRunBreakerOpensAndRecovers() returns error? {
    postgresql:Client jobsDb = check itConnect("amplify_jobs", itJobsPassword);
    postgresql:Client lockDb = check itConnect("amplify_jobs", itJobsPassword, 1);
    RunConfig cfg = {...TEST_CONFIG};
    cfg.maxRows = 1000;
    cfg.batchSize = 10;
    cfg.leaseSeconds = 3;
    Deps base = bareDeps(new PgRunStore(jobsDb), new PgRunLock(lockDb), cfg);
    // Drain anything earlier suites left, so only this test's rows are pending.
    RunReport|RunSkipped|error drained = runOnce(base, "it-dbdown-drain");
    test:assertFalse(drained is error, "drain run");

    string tag = "it-dbdown-" + types:newUuidV7().substring(24);
    foreach int i in 0 ..< 6 {
        string key = string `${tag}-${i}`;
        _ = check jobsDb->execute(`INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload,
                idempotency_key, correlation_id) VALUES ('ExternalShare', ${key}, 'ExternalShareApproved', '{}'::jsonb,
                ${key}, ${tag})`);
    }

    // 1. Postgres goes away mid-run: the run fails cleanly with a transient error.
    Deps failing = bareDeps(new StopDbAfterFirstRow(new PgRunStore(jobsDb)), new PgRunLock(lockDb), cfg);
    RunReport|RunSkipped|error broken = runOnce(failing, tag);
    test:assertTrue(broken is error, "a run whose database dies mid-run ends in an error");
    if broken is error {
        test:assertTrue(resilience:isTransientDbError(broken), string `transient, so it feeds the breaker: ${broken.message()}`);
    }

    // 2. The breaker opens on failed probes and refuses calls while Postgres is down.
    resilience:DbBreaker breaker = new ({failureThreshold: 2, windowSeconds: 30, resetTimeSeconds: 2});
    foreach int i in 0 ..< 2 {
        test:assertEquals(breaker.admit(), "PASS");
        error? probed = store:probe(jobsDb);
        test:assertTrue(probed is error, "Postgres is stopped");
        if probed is error {
            _ = breaker.onFailure(probed);
        }
    }
    test:assertEquals(breaker.state(), "OPEN");
    test:assertEquals(breaker.admit(), "REJECT");

    // 3. Postgres comes back; after the reset time the half-open trial succeeds and the breaker closes.
    check docker("start", pgContainer);
    test:assertTrue(waitForDb(jobsDb, 60), "the pool reconnects once Postgres is back");
    runtime:sleep(2.1);
    test:assertEquals(breaker.admit(), "TRIAL");
    test:assertEquals(store:probe(jobsDb), ());
    breaker.onSuccess();
    test:assertEquals(breaker.state(), "CLOSED");

    // 4. After the lease, the next run settles every row exactly once (the first one stayed DONE).
    runtime:sleep(<decimal>cfg.leaseSeconds + 0.5);
    Deps again = bareDeps(new PgRunStore(jobsDb), new PgRunLock(check itConnect("amplify_jobs", itJobsPassword, 1)),
            cfg);
    RunReport|RunSkipped|error recovered = runOnce(again, tag + "-recover");
    test:assertTrue(recovered is RunReport, "the run after recovery completes");
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM messaging.outbox
            WHERE correlation_id = ${tag} AND status = 'DONE'`), 6);
    test:assertEquals(check itCount(jobsDb, `SELECT count(*)::int FROM messaging.outbox
            WHERE correlation_id = ${tag} AND status <> 'DONE'`), 0);
}
