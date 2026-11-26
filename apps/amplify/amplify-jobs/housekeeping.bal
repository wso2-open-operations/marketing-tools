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

// Housekeeping step of the daily `POST /maintenance/partitions` pass (V029): prunes the phase 2-4 working tables that
// grow without bound (`sharing_native_intent`, `sharing_api_usage`, post rows of `sharing_sync_cursor`) in batches,
// so no statement holds locks for long, then writes one `HousekeepingRun` audit row with the counts. Never fails the
// pass: partition upkeep has already run, and a failed prune is reported (`FAILED`) and audited with what it did.
// Business data (ledger, engagements, coin runs and issues, external shares, audit) is never pruned here.

import amplify_common.resilience;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/log;
import ballerinax/postgresql;

# Most delete calls per table in one pass; a table still full after them is `PARTIAL` (the next pass carries on).
const int HOUSEKEEPING_MAX_BATCHES = 20;

# The housekeeping settings (`config_app_setting`, S017). Values outside the V029 ranges keep the defaults.
type HousekeepingSettings record {|
    # `housekeeping.native_intent_days` (2-365)
    int nativeIntentDays = 7;
    # `housekeeping.api_usage_days` (30-730)
    int apiUsageDays = 90;
    # `housekeeping.sync_cursor_days` (30-730)
    int syncCursorDays = 180;
    # `housekeeping.batch_rows` (100-50000)
    int batchRows = 5000;
|};

# What the housekeeping step did.
type HousekeepingReport record {|
    # `DONE`; `PARTIAL` when a table still had rows after `HOUSEKEEPING_MAX_BATCHES` calls; `FAILED` when the
    # database refused (the counts say what was deleted before)
    "DONE"|"PARTIAL"|"FAILED" status;
    # `sharing_native_intent` rows deleted
    int native_intents_deleted = 0;
    # `sharing_api_usage` rows deleted
    int api_usage_deleted = 0;
    # `sharing_sync_cursor` rows deleted
    int sync_cursors_deleted = 0;
|};

# What housekeeping needs from the database (a port, so the tests run on fakes).
type HousekeepingStore isolated object {
    isolated function settings() returns HousekeepingSettings|error;
    isolated function pruneNativeIntents(int days, int batchRows) returns int|error;
    isolated function pruneApiUsage(int days, int batchRows) returns int|error;
    isolated function pruneSyncCursors(int days, int batchRows) returns int|error;
    isolated function audit(store:AuditEntry entry) returns error?;
};

# One prune: the table's delete call with its age and batch size.
type Prune isolated function (int days, int batchRows) returns int|error;

# Runs the housekeeping step and audits it. Never returns an error.
#
# + st - Database side
# + correlationId - Correlation id for the audit row
# + return - What was done
isolated function runHousekeeping(HousekeepingStore st, string? correlationId = ()) returns HousekeepingReport {
    HousekeepingReport report = {status: "DONE"};
    HousekeepingSettings|error settings = st.settings();
    if settings is error {
        log:printError("Housekeeping: settings unreadable", resilience:loggable(settings));
        report.status = "FAILED";
        auditHousekeeping(st, report, (), correlationId);
        return report;
    }
    error? failed = pruneAll(st, settings, report);
    if failed is error {
        log:printError("Housekeeping failed", resilience:loggable(failed));
        report.status = "FAILED";
    }
    auditHousekeeping(st, report, settings, correlationId);
    return report;
}

isolated function pruneAll(HousekeepingStore st, HousekeepingSettings s, HousekeepingReport report) returns error? {
    [int, boolean] intents = check pruneInBatches(isolated function(int d, int b) returns int|error => st.pruneNativeIntents(d, b),
            s.nativeIntentDays, s.batchRows);
    report.native_intents_deleted = intents[0];
    [int, boolean] usage = check pruneInBatches(isolated function(int d, int b) returns int|error => st.pruneApiUsage(d, b),
            s.apiUsageDays, s.batchRows);
    report.api_usage_deleted = usage[0];
    [int, boolean] cursors = check pruneInBatches(isolated function(int d, int b) returns int|error => st.pruneSyncCursors(d, b),
            s.syncCursorDays, s.batchRows);
    report.sync_cursors_deleted = cursors[0];
    if intents[1] || usage[1] || cursors[1] {
        report.status = "PARTIAL";
    }
}

# Calls one prune while it deletes a full batch, at most `HOUSEKEEPING_MAX_BATCHES` times. Each call is its own
# statement (and transaction), so locks are held for one batch only.
#
# + prune - The table's delete call
# + days - Age
# + batchRows - Rows per call
# + return - Rows deleted and whether rows may be left (the last call was full), or an error
isolated function pruneInBatches(Prune prune, int days, int batchRows) returns [int, boolean]|error {
    int total = 0;
    foreach int _ in 1 ... HOUSEKEEPING_MAX_BATCHES {
        int deleted = check prune(days, batchRows);
        total += deleted;
        if deleted < batchRows {
            return [total, false];
        }
    }
    return [total, true];
}

# Writes the run's one audit row (`HousekeepingRun`); a failed write is logged, not returned.
#
# + st - Database side
# + report - What was done
# + settings - The settings used, `()` when they couldn't be read
# + correlationId - Correlation id
isolated function auditHousekeeping(HousekeepingStore st, HousekeepingReport report, HousekeepingSettings? settings,
        string? correlationId) {
    error? written = st.audit(housekeepingAudit(report, settings, correlationId));
    if written is error {
        log:printError("Housekeeping audit not written", resilience:loggable(written));
    }
}

# The audit row of a housekeeping run.
#
# + report - What was done
# + settings - The settings used
# + correlationId - Correlation id
# + return - The entry (`FAILED` outcome when the step failed)
isolated function housekeepingAudit(HousekeepingReport report, HousekeepingSettings? settings, string? correlationId)
        returns store:AuditEntry {
    store:AuditEntry entry = store:auditOf(systemActor(correlationId), "HousekeepingRun", "housekeeping",
            "maintenance", {...report, settings: settings.toJson()});
    entry.outcome = report.status == "FAILED" ? "FAILED" : "SUCCESS";
    return entry;
}

# The housekeeping settings from rows; missing or out-of-range values keep the defaults.
#
# + rows - Setting rows
# + return - Settings
isolated function toHousekeepingSettings(store:Setting[] rows) returns HousekeepingSettings {
    HousekeepingSettings s = {};
    foreach store:Setting row in rows {
        json v = row.value;
        match row.key {
            "housekeeping.native_intent_days" => {
                s.nativeIntentDays = v is int && v >= 2 && v <= 365 ? v : s.nativeIntentDays;
            }
            "housekeeping.api_usage_days" => {
                s.apiUsageDays = v is int && v >= 30 && v <= 730 ? v : s.apiUsageDays;
            }
            "housekeeping.sync_cursor_days" => {
                s.syncCursorDays = v is int && v >= 30 && v <= 730 ? v : s.syncCursorDays;
            }
            "housekeeping.batch_rows" => {
                s.batchRows = v is int && v >= 100 && v <= 50000 ? v : s.batchRows;
            }
        }
    }
    return s;
}

// ---- PostgreSQL -----------------------------------------------------------------------------------

# `HousekeepingStore` over the maintenance client.
isolated class PgHousekeepingStore {
    *HousekeepingStore;

    private final postgresql:Client db;

    isolated function init(postgresql:Client db) {
        self.db = db;
    }

    isolated function settings() returns HousekeepingSettings|error =>
        toHousekeepingSettings(check store:readSettings(self.db));

    isolated function pruneNativeIntents(int days, int batchRows) returns int|error =>
        sharing:pruneNativeIntents(self.db, days, batchRows);

    isolated function pruneApiUsage(int days, int batchRows) returns int|error =>
        sharing:pruneApiUsage(self.db, days, batchRows);

    isolated function pruneSyncCursors(int days, int batchRows) returns int|error =>
        sharing:pruneSyncCursors(self.db, days, batchRows);

    isolated function audit(store:AuditEntry entry) returns error? => store:recordAudit(self.db, entry);
}
