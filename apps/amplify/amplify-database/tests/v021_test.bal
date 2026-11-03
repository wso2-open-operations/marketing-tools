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


// V021: the points ledger and the audit log can't be rewritten (ADR-043). Only the settlement columns of a ledger row
// may change, nothing is ever deleted, and an audit row is never changed. Retention still drops whole partitions.

import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV021LedgerIsAppendOnlyExceptSettlement() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client api = check apiClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version = 'V021__immutable_ledger_and_audit'`);
    test:assertEquals(applied, 1);

    _ = check api->execute(`INSERT INTO scoring_points_ledger (reference, employee_id, source_type, points, actor_id, reason)
                            VALUES ('ADJ-v021-1', 'v021-emp', 'ADJUSTMENT', 5, 'it', 'v021 test')`);

    // A fact never changes, whoever asks (the owner included) ...
    assertViolates(failure(api, `UPDATE scoring_points_ledger SET points = 99 WHERE reference = 'ADJ-v021-1'`),
            "scoring_points_ledger is append-only");
    assertViolates(failure(api, `UPDATE scoring_points_ledger SET reason = 'rewritten' WHERE reference = 'ADJ-v021-1'`),
            "only status, status_changed_at, paid_at and coin_reference may change");
    assertViolates(failure(api, `UPDATE scoring_points_ledger SET employee_id = 'someone-else' WHERE reference = 'ADJ-v021-1'`),
            "scoring_points_ledger is append-only");
    assertViolates(failure(admin, `UPDATE scoring_points_ledger SET points = 0 WHERE reference = 'ADJ-v021-1'`),
            "scoring_points_ledger is append-only");
    // ... and a row is never deleted.
    assertViolates(failure(api, `DELETE FROM scoring_points_ledger WHERE reference = 'ADJ-v021-1'`), "never deleted");
    assertViolates(failure(admin, `DELETE FROM scoring_points_ledger WHERE reference = 'ADJ-v021-1'`), "never deleted");

    // The settlement columns are the one thing that moves (the repository's updateSettlement).
    _ = check api->execute(`UPDATE scoring_points_ledger SET status = 'HELD', status_changed_at = now(), coin_reference = 'c-1'
                            WHERE reference = 'ADJ-v021-1'`);
    int points = check api->queryRow(`SELECT points FROM scoring_points_ledger WHERE reference = 'ADJ-v021-1'`);
    test:assertEquals(points, 5, "the facts are untouched");
    check admin.close();
    check api.close();
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV021AuditLogIsAppendOnlyAndPartitionRetentionStillWorks() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client api = check apiClient();
    _ = check api->execute(`INSERT INTO audit_log (actor_id, action, entity_type, entity_id, outcome)
                            VALUES ('it', 'V021_TEST', 'it', 'v021-audit', 'SUCCESS')`);
    assertViolates(failure(api, `UPDATE audit_log SET reason = 'x' WHERE entity_id = 'v021-audit'`), "audit_log is append-only");
    assertViolates(failure(admin, `UPDATE audit_log SET outcome = 'FAILED' WHERE entity_id = 'v021-audit'`), "audit_log is append-only");
    assertViolates(failure(api, `DELETE FROM audit_log WHERE entity_id = 'v021-audit'`), "audit_log is append-only");
    assertViolates(failure(admin, `DELETE FROM audit_log WHERE entity_id = 'v021-audit'`), "audit_log is append-only");

    // Every partition carries the trigger, including the ones the daily upkeep creates later.
    int partitions = check admin->queryRow(`SELECT count(*)::int FROM pg_inherits WHERE inhparent = 'audit_log'::regclass`);
    int guarded = check admin->queryRow(`
        SELECT count(*)::int FROM pg_inherits i
        WHERE i.inhparent = 'audit_log'::regclass
          AND EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = i.inhrelid AND t.tgname = 'audit_log_guard')`);
    test:assertTrue(partitions > 0);
    test:assertEquals(guarded, partitions, "every audit partition has the guard");
    // Retention is a partition drop, not a row delete, so it still runs.
    int dropped = check api->queryRow(`SELECT audit_drop_old_audit_partitions(60)`);
    test:assertTrue(dropped >= 0);
    check admin.close();
    check api.close();
}
