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

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

isolated function insertRun(postgresql:Client db, string id, string period) returns sql:ExecutionResult|sql:Error {
    return db->execute(`INSERT INTO scoring_coin_run (id, period, status, started_at)
                        VALUES (CAST(${id} AS uuid), ${period}, 'RUNNING', now())`);
}

isolated function insertIssue(postgresql:Client db, string runId, string employeeId, string reference, int pointsIn,
        int carryIn, int coins, int carryOut, string status, string? wallet, string? transferRef = (),
        boolean sent = false) returns sql:ExecutionResult|sql:Error {
    return db->execute(`INSERT INTO scoring_coin_issue (run_id, employee_id, points_in, carry_in, coins, carry_out,
            block_points, block_coins, wallet_address, reference, transfer_reference, status, sent_at, created_at,
            updated_at)
        VALUES (CAST(${runId} AS uuid), ${employeeId}, ${pointsIn}, ${carryIn}, ${coins}, ${carryOut}, 100, 10,
            ${wallet}, ${reference}, ${transferRef}, ${status}, CASE WHEN ${sent} THEN now() END, now(), now())`);
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV026Coins() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version IN ('V026__coins', 'S014__coin_caps')`);
    test:assertEquals(applied, 2);
    record {|string perPerson; string perRun;|} caps = check admin->queryRow(`
        SELECT (SELECT value::text FROM config_app_setting WHERE key = 'coin.max_coins_per_person') AS "perPerson",
               (SELECT value::text FROM config_app_setting WHERE key = 'coin.max_coins_per_run') AS "perRun"`);
    test:assertEquals(caps, {perPerson: "500", perRun: "50000"});

    // Ledger rows can become PAID now, but only naming the issue that paid them, and then never change again.
    _ = check jobs->execute(`INSERT INTO scoring_points_ledger (reference, employee_id, source_type, points, actor_id,
            reason, status) VALUES ('ADJ-v026-1', 'v026-employee', 'ADJUSTMENT', 120, 'po-1', 'test', 'HELD')`);
    sql:ExecutionResult|sql:Error noRef = jobs->execute(`UPDATE scoring_points_ledger
            SET status = 'PAID', paid_at = now() WHERE reference = 'ADJ-v026-1'`);
    test:assertTrue(noRef is sql:Error && noRef.message().includes("points_ledger_paid_coin_ck"),
            "PAID without a coin reference");
    _ = check jobs->execute(`UPDATE scoring_points_ledger SET coin_reference = 'CNV-v026-1'
            WHERE reference = 'ADJ-v026-1'`);
    _ = check jobs->execute(`UPDATE scoring_points_ledger SET status = 'PAID', paid_at = now(), status_changed_at = now()
            WHERE reference = 'ADJ-v026-1'`);
    sql:ExecutionResult|sql:Error repaid = jobs->execute(`UPDATE scoring_points_ledger SET status = 'HELD'
            WHERE reference = 'ADJ-v026-1'`);
    test:assertTrue(repaid is sql:Error && repaid.message().includes("PAID row is final"), "a PAID row is final");
    sql:ExecutionResult|sql:Error retag = jobs->execute(`UPDATE scoring_points_ledger SET coin_reference = 'CNV-other'
            WHERE reference = 'ADJ-v026-1'`);
    test:assertTrue(retag is sql:Error, "its coin reference is final too");

    // Runs: one per period, a known period shape, STOPPED iff a reason.
    string runId = "0192f0e0-0000-7000-8000-000000002601";
    _ = check insertRun(jobs, runId, "2026-12");
    test:assertTrue(insertRun(jobs, "0192f0e0-0000-7000-8000-000000002602", "2026-12") is sql:Error, "one run per period");
    _ = check insertRun(jobs, "0192f0e0-0000-7000-8000-000000002603", "2026-W49");
    _ = check insertRun(jobs, "0192f0e0-0000-7000-8000-000000002604", "2026-12-01");
    test:assertTrue(insertRun(jobs, "0192f0e0-0000-7000-8000-000000002605", "December") is sql:Error, "period shape");
    sql:ExecutionResult|sql:Error noReason = jobs->execute(`UPDATE scoring_coin_run SET status = 'STOPPED'
            WHERE id = CAST(${runId} AS uuid)`);
    test:assertTrue(noReason is sql:Error, "STOPPED needs a reason");

    // Issues: whole blocks, the points add up, SENT iff a transfer reference, a wallet unless skipped.
    _ = check insertIssue(jobs, runId, "v026-a", "CNV-a", 230, 40, 20, 70, "PENDING", "wallet-a");
    test:assertTrue(insertIssue(jobs, runId, "v026-a", "CNV-a2", 100, 0, 10, 0, "PENDING", "wallet-a") is sql:Error,
            "one issue per employee per run");
    test:assertTrue(insertIssue(jobs, runId, "v026-b", "CNV-b", 230, 40, 25, 20, "PENDING", "wallet-b") is sql:Error,
            "whole blocks only");
    test:assertTrue(insertIssue(jobs, runId, "v026-c", "CNV-c", 230, 40, 20, 60, "PENDING", "wallet-c") is sql:Error,
            "carry in + points in = blocks + carry out");
    test:assertTrue(insertIssue(jobs, runId, "v026-d", "CNV-d", 100, 0, 10, 0, "SENT", "wallet-d") is sql:Error,
            "SENT needs the transfer reference");
    _ = check insertIssue(jobs, runId, "v026-e", "CNV-e", 100, 0, 10, 0, "SENT", "wallet-e", "tx-e", true);
    test:assertTrue(insertIssue(jobs, runId, "v026-f", "CNV-f", 100, 0, 10, 0, "PENDING", ()) is sql:Error,
            "a wallet unless skipped");
    _ = check insertIssue(jobs, runId, "v026-g", "CNV-g", 100, 0, 10, 0, "SKIPPED_NO_WALLET", ());
    test:assertTrue(insertIssue(jobs, runId, "v026-h", "XYZ-h", 100, 0, 10, 0, "PENDING", "wallet-h") is sql:Error,
            "our references start with CNV-");
    test:assertTrue(insertIssue(jobs, runId, "v026-i", "CNV-i", 100, 0, 10, 0, "SENT", "wallet-i", "tx-e", true)
            is sql:Error, "a transfer pays one issue");

    // Erasure deletes the captured wallet; the issues stay (pseudonymous, needed to reconcile).
    _ = check jobs->execute(`INSERT INTO scoring_coin_wallet (employee_id, wallet_address, captured_at, updated_at)
            VALUES ('v026-a', 'wallet-a', now(), now())`);
    string result = check jobs->queryRow(`SELECT identity_erase_employee('v026-a', 'system', 'leaver sweep')::text`);
    test:assertTrue(result.includes("\"coinWallets\": 1"), result);
    test:assertTrue(result.includes("\"claimNotes\": 0"), "V024's erasure is kept: " + result);
    int wallets = check admin->queryRow(`SELECT count(*)::int FROM scoring_coin_wallet WHERE employee_id = 'v026-a'`);
    test:assertEquals(wallets, 0);
    int issues = check admin->queryRow(`SELECT count(*)::int FROM scoring_coin_issue WHERE employee_id = 'v026-a'`);
    test:assertEquals(issues, 1, "the issue stays");
    string again = check jobs->queryRow(`SELECT identity_erase_employee('v026-a', 'system', 'again')::text`);
    test:assertTrue(again.includes("\"coinWallets\": 0"), again);

    check jobs.close();
    check admin.close();
}
