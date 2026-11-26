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

// V027: pre-coin verification. The verification columns may change (and only in their allowed shapes), a PAID row stays
// final, the settings are seeded, and the member-token budget has its own usage row.

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV027PreCoinVerification() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version IN ('V027__pre_coin_verification', 'S015__coin_verify_settings')`);
    test:assertEquals(applied, 2);
    record {|string maxAge; string budget;|} settings = check admin->queryRow(`
        SELECT (SELECT value::text FROM config_app_setting WHERE key = 'coin.verify_max_age_hours') AS "maxAge",
               (SELECT value::text FROM config_app_setting WHERE key = 'coin.verify_member_daily_call_budget') AS "budget"`);
    test:assertEquals(settings, {maxAge: "48", budget: "1000"});

    _ = check jobs->execute(`INSERT INTO scoring_points_ledger (reference, employee_id, source_type, points, actor_id,
            reason, status) VALUES ('ADJ-v027-1', 'v027-employee', 'ADJUSTMENT', 5, 'po-1', 'test', 'HELD')`);
    _ = check jobs->execute(`UPDATE scoring_points_ledger SET verification = 'VERIFIED', verified_at = now()
            WHERE reference = 'ADJ-v027-1'`);
    _ = check jobs->execute(`UPDATE scoring_points_ledger SET status = NULL, verification = 'UNVERIFIABLE',
            verification_reason = 'NO_TOKEN', verified_at = now() WHERE reference = 'ADJ-v027-1'`);
    sql:ExecutionResult|sql:Error noTime = jobs->execute(`UPDATE scoring_points_ledger SET verified_at = NULL
            WHERE reference = 'ADJ-v027-1'`);
    test:assertTrue(noTime is sql:Error && noTime.message().includes("points_ledger_verified_at_ck"));
    sql:ExecutionResult|sql:Error reasonOnVerified = jobs->execute(`UPDATE scoring_points_ledger
            SET verification = 'VERIFIED' WHERE reference = 'ADJ-v027-1'`);
    test:assertTrue(reasonOnVerified is sql:Error
            && reasonOnVerified.message().includes("points_ledger_verification_reason_ck"), "a reason only when UNVERIFIABLE");
    sql:ExecutionResult|sql:Error unknown = jobs->execute(`UPDATE scoring_points_ledger SET verification = 'MAYBE',
            verification_reason = NULL WHERE reference = 'ADJ-v027-1'`);
    test:assertTrue(unknown is sql:Error, "only the four outcomes");

    // A PAID row stays final, its verification included.
    _ = check jobs->execute(`UPDATE scoring_points_ledger SET status = 'HELD', verification = 'PO_CLEARED',
            verification_reason = NULL, coin_reference = 'CNV-v027-1' WHERE reference = 'ADJ-v027-1'`);
    _ = check jobs->execute(`UPDATE scoring_points_ledger SET status = 'PAID', paid_at = now()
            WHERE reference = 'ADJ-v027-1'`);
    sql:ExecutionResult|sql:Error reverify = jobs->execute(`UPDATE scoring_points_ledger SET verified_at = now()
            WHERE reference = 'ADJ-v027-1'`);
    test:assertTrue(reverify is sql:Error && reverify.message().includes("PAID row is final"));

    _ = check jobs->execute(`INSERT INTO sharing_api_usage (provider_api, day, calls)
            VALUES ('SHARE_ON_LINKEDIN', CURRENT_DATE, 1)`);
    sql:ExecutionResult|sql:Error webhook = jobs->execute(`INSERT INTO sharing_api_usage (provider_api, day, calls)
            VALUES ('WEBHOOK', CURRENT_DATE, 1)`);
    test:assertTrue(webhook is sql:Error);
    check admin.close();
    check jobs.close();
}
