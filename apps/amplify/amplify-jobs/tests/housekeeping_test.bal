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

// Housekeeping step (V029), run-level audit rows of the engagement sync and the Coins conversion.

import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

final time:Utc HK_T0 = [1790100000, 0];

# Fake housekeeping store: each table has `rows` left; a call deletes up to the batch. `failOn` names a table whose
# call fails.
isolated class FakeHousekeepingStore {
    *HousekeepingStore;

    private int intents;
    private int usage;
    private int cursors;
    private final string failOn;
    private final boolean settingsFail;
    private final store:Setting[] & readonly rows;
    private store:AuditEntry[] audits = [];
    private int[] calls = [0, 0, 0];
    private int[] daysSeen = [0, 0, 0];

    isolated function init(int intents = 0, int usage = 0, int cursors = 0, string failOn = "",
            boolean settingsFail = false, store:Setting[] rows = []) {
        self.intents = intents;
        self.usage = usage;
        self.cursors = cursors;
        self.failOn = failOn;
        self.settingsFail = settingsFail;
        self.rows = rows.cloneReadOnly();
    }

    isolated function settings() returns HousekeepingSettings|error {
        if self.settingsFail {
            return error("settings down");
        }
        return toHousekeepingSettings(self.rows);
    }

    isolated function pruneNativeIntents(int days, int batchRows) returns int|error {
        lock {
            if self.failOn == "intents" {
                return error("refused");
            }
            self.calls[0] += 1;
            self.daysSeen[0] = days;
            int n = int:min(self.intents, batchRows);
            self.intents -= n;
            return n;
        }
    }

    isolated function pruneApiUsage(int days, int batchRows) returns int|error {
        lock {
            if self.failOn == "usage" {
                return error("refused");
            }
            self.calls[1] += 1;
            self.daysSeen[1] = days;
            int n = int:min(self.usage, batchRows);
            self.usage -= n;
            return n;
        }
    }

    isolated function pruneSyncCursors(int days, int batchRows) returns int|error {
        lock {
            self.calls[2] += 1;
            self.daysSeen[2] = days;
            int n = int:min(self.cursors, batchRows);
            self.cursors -= n;
            return n;
        }
    }

    isolated function audit(store:AuditEntry entry) returns error? {
        lock {
            self.audits.push(entry.clone());
        }
    }

    isolated function auditRows() returns store:AuditEntry[] {
        lock {
            return self.audits.clone();
        }
    }

    isolated function callCounts() returns int[] {
        lock {
            return self.calls.clone();
        }
    }

    isolated function days() returns int[] {
        lock {
            return self.daysSeen.clone();
        }
    }
}

isolated function hkSetting(string key, json value) returns store:Setting =>
    {key, value, updatedBy: "system", updatedAt: HK_T0, version: 1};

@test:Config
function testHousekeepingSettingsKeepDefaultsOutOfRange() {
    test:assertEquals(toHousekeepingSettings([]), {nativeIntentDays: 7, apiUsageDays: 90, syncCursorDays: 180,
        batchRows: 5000});
    test:assertEquals(toHousekeepingSettings([
        hkSetting("housekeeping.native_intent_days", 14),
        hkSetting("housekeeping.api_usage_days", 365),
        hkSetting("housekeeping.sync_cursor_days", 30),
        hkSetting("housekeeping.batch_rows", 100)
    ]), {nativeIntentDays: 14, apiUsageDays: 365, syncCursorDays: 30, batchRows: 100});
    test:assertEquals(toHousekeepingSettings([
        hkSetting("housekeeping.native_intent_days", 1),
        hkSetting("housekeeping.api_usage_days", 29),
        hkSetting("housekeeping.sync_cursor_days", 731),
        hkSetting("housekeeping.batch_rows", "lots")
    ]), {nativeIntentDays: 7, apiUsageDays: 90, syncCursorDays: 180, batchRows: 5000}, "the V029 ranges");
}

@test:Config
function testHousekeepingPrunesInBatchesAndAuditsOnce() {
    FakeHousekeepingStore st = new (intents = 250, usage = 3, cursors = 0,
        rows = [hkSetting("housekeeping.batch_rows", 100), hkSetting("housekeeping.native_intent_days", 10)]);
    HousekeepingReport report = runHousekeeping(st, "corr-hk");
    test:assertEquals(report, {status: "DONE", native_intents_deleted: 250, api_usage_deleted: 3,
        sync_cursors_deleted: 0});
    test:assertEquals(st.callCounts(), [3, 1, 1], "100 + 100 + 50: the short batch ends the table");
    test:assertEquals(st.days(), [10, 90, 180]);
    store:AuditEntry[] audits = st.auditRows();
    test:assertEquals(audits.length(), 1, "one row per run");
    test:assertEquals(audits[0].action, "HousekeepingRun");
    test:assertEquals(audits[0].outcome, "SUCCESS");
    test:assertEquals(audits[0].actorId, "system");
    test:assertEquals(audits[0].correlationId, "corr-hk");
    json after = audits[0].after;
    test:assertEquals(after, {status: "DONE", native_intents_deleted: 250, api_usage_deleted: 3,
        sync_cursors_deleted: 0, settings: {nativeIntentDays: 10, apiUsageDays: 90, syncCursorDays: 180,
            batchRows: 100}});
}

@test:Config
function testHousekeepingAuditsAnEmptyRunToo() {
    FakeHousekeepingStore st = new ();
    test:assertEquals(runHousekeeping(st).status, "DONE");
    test:assertEquals(st.auditRows().length(), 1);
}

@test:Config
function testHousekeepingStopsAtTheBatchCapAsPartial() {
    FakeHousekeepingStore st = new (cursors = 100 * (HOUSEKEEPING_MAX_BATCHES + 5),
        rows = [hkSetting("housekeeping.batch_rows", 100)]);
    HousekeepingReport report = runHousekeeping(st);
    test:assertEquals(report.status, "PARTIAL");
    test:assertEquals(report.sync_cursors_deleted, 100 * HOUSEKEEPING_MAX_BATCHES);
    test:assertEquals(st.callCounts()[2], HOUSEKEEPING_MAX_BATCHES, "never more calls than the cap");
}

@test:Config
function testHousekeepingFailureIsReportedAndAuditedNotThrown() {
    FakeHousekeepingStore st = new (intents = 5, usage = 5, failOn = "usage");
    HousekeepingReport report = runHousekeeping(st);
    test:assertEquals(report, {status: "FAILED", native_intents_deleted: 5, api_usage_deleted: 0,
        sync_cursors_deleted: 0}, "what was deleted before the failure is kept in the report");
    test:assertEquals(st.callCounts()[2], 0, "stops at the failing table");
    store:AuditEntry[] audits = st.auditRows();
    test:assertEquals(audits.length(), 1);
    test:assertEquals(audits[0].outcome, "FAILED");

    FakeHousekeepingStore down = new (intents = 5, settingsFail = true);
    test:assertEquals(runHousekeeping(down).status, "FAILED");
    test:assertEquals(down.callCounts(), [0, 0, 0], "nothing is deleted without the settings");
    test:assertEquals(down.auditRows()[0].outcome, "FAILED");
}

@test:Config
function testEngagementSyncAuditOnlyWhenTheSyncRan() {
    test:assertTrue(engagementSyncAudit({status: "OFF"}, ()) is ());
    test:assertTrue(engagementSyncAudit({status: "NOT_CONNECTED"}, ()) is ());
    test:assertTrue(engagementSyncAudit({status: "NEEDS_RECONNECT", tokenRefreshed: true}, ()) is ());
    sharing:SyncReport sync = {status: "BUDGET_REACHED", campaigns: 2, calls: 9, reactions: 3, comments: 1, reposts: 1,
        alreadyRecorded: 4, dropped: 2};
    store:AuditEntry? entry = engagementSyncAudit({status: "BUDGET_REACHED", tokenRefreshed: true, sync}, "corr-s");
    if entry is () {
        test:assertFail("a run that read LinkedIn is audited");
    }
    test:assertEquals(entry.action, "EngagementSyncRun");
    test:assertEquals(entry.entityType, "sharing_engagement");
    test:assertEquals(entry.entityId, "COMMUNITY_MANAGEMENT");
    test:assertEquals(entry.correlationId, "corr-s");
    test:assertEquals(entry.actorRoles, ["amplify_jobs"]);
    test:assertEquals(entry.after, {status: "BUDGET_REACHED", tokenRefreshed: true, campaigns: 2, calls: 9,
        reactions: 3, comments: 1, reposts: 1, alreadyRecorded: 4, dropped: 2});
}

@test:Config
function testCoinRunAuditForRunsNotSkips() {
    test:assertTrue(coinRunAudit(<CoinsSkipped>{reason: "WALLETS_OFF"}, ()) is ());
    scoring:CoinRunReport run = {status: "DONE", period: "2026-12", sent: 3, coinsSent: 30, skippedNoWallet: 1};
    store:AuditEntry? entry = coinRunAudit(run, "corr-c");
    if entry is () {
        test:assertFail("a conversion run is audited");
    }
    test:assertEquals(entry.action, "CoinRunCompleted");
    test:assertEquals(entry.entityType, "scoring_coin_run");
    test:assertEquals(entry.entityId, "2026-12");
    test:assertEquals(entry.correlationId, "corr-c");
    test:assertEquals(entry.after, run.toJson());
    store:AuditEntry? stopped = coinRunAudit({status: "STOPPED", stopReason: "MASTER_WALLET_SHORT"}, ());
    test:assertEquals(stopped is () ? () : stopped.entityId, "STOPPED", "no period: the status names it");
}

// Against a migrated PostgreSQL (`AMPLIFY_IT=true`, the amplify-database integration run first): the real prunes and
// the one audit row, through the same store the maintenance pass uses.
@test:Config {groups: ["integration"], enable: itEnabled}
function testHousekeepingAgainstPostgres() returns error? {
    postgresql:Client db = check itConnect(itLoginUser, itLoginPassword, 2);
    _ = check db->execute(`
        INSERT INTO sharing_native_intent (employee_id, campaign_id, opened_at, detected_at)
        VALUES ('hk-it-old', '0192f0e0-0000-7000-8000-0000000029a1', now() - interval '30 days', NULL)
        ON CONFLICT DO NOTHING`);
    int auditsBefore = check itCount(db, `SELECT count(*)::int FROM audit_log WHERE action = 'HousekeepingRun'`);
    HousekeepingReport report = runHousekeeping(new PgHousekeepingStore(db), "hk-it");
    test:assertEquals(report.status, "DONE");
    test:assertTrue(report.native_intents_deleted >= 1);
    test:assertEquals(check itCount(db, `SELECT count(*)::int FROM sharing_native_intent WHERE employee_id = 'hk-it-old'`),
            0);
    test:assertEquals(check itCount(db, `SELECT count(*)::int FROM audit_log WHERE action = 'HousekeepingRun'`),
            auditsBefore + 1, "one audit row per run");
    test:assertEquals(check itCount(db, `SELECT count(*)::int FROM audit_log
                                         WHERE action = 'HousekeepingRun' AND correlation_id = 'hk-it'
                                           AND after ->> 'status' = 'DONE'`), 1);
    check db.close();
}
