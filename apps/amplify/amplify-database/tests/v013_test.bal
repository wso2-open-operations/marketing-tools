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


// V013 (round 2 of the 2026-10-17 review): the app roles carry a 30 s idle-in-transaction limit, the two
// dashboard indexes exist, and the recognition lock order holds on the SQL side (no SQL function takes
// the app-level key 4242101; the three functions that take 1634561133 document the order).

import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testV012IsApplied]}
function testV013RoleIdleTimeoutAndIndexes() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client db = check adminClient(itDbName);
    int applied = check db->queryRow(`SELECT count(*)::int FROM public.schema_version
                                      WHERE version = 'V013__idle_timeout_dashboard_indexes'`);
    test:assertEquals(applied, 1);

    foreach string role in ["amplify_api", "amplify_jobs"] {
        int set = check db->queryRow(`
            SELECT count(*)::int FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
            WHERE r.rolname = ${role} AND s.setdatabase = 0
              AND 'idle_in_transaction_session_timeout=30s' = ANY (s.setconfig)`);
        test:assertEquals(set, 1, role + " has idle_in_transaction_session_timeout = 30s");
    }
    // A fresh session of the role picks it up.
    postgresql:Client api = check apiClient();
    string shown = check api->queryRow(`SELECT current_setting('idle_in_transaction_session_timeout')`);
    test:assertEquals(shown, "30s");
    check api.close();

    map<string> expected = {
        points_ledger_created_at_idx: "CREATE INDEX points_ledger_created_at_idx ON scoring.points_ledger USING btree (created_at)",
        share_request_failed_at_idx: "CREATE INDEX share_request_failed_at_idx ON sharing.share_request USING btree (failed_at) WHERE (failed_at IS NOT NULL)"
    };
    foreach [string, string] [name, def] in expected.entries() {
        string actual = check db->queryRow(`SELECT indexdef FROM pg_indexes WHERE indexname = ${name}`);
        test:assertEquals(actual, def);
    }
    check db.close();
}

@test:Config {groups: ["integration"], dependsOn: [testV012IsApplied]}
function testRecognitionLockOrderOnTheSqlSide() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client db = check adminClient(itDbName);
    // The app-level key is only ever taken by amplify_domain store:lockRecognition, before any SQL
    // function runs; a SQL function taking it would take the two locks in reverse.
    int appKeyInSql = check db->queryRow(`SELECT count(*)::int FROM pg_proc WHERE prosrc LIKE '%4242101%'`);
    test:assertEquals(appKeyInSql, 0, "no SQL function takes the app-level recognition lock");
    int sqlKeyHolders = check db->queryRow(`
        SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'recognition' AND p.prosrc LIKE '%pg_advisory_xact_lock(1634561133)%'
          AND obj_description(p.oid, 'pg_proc') LIKE '%4242101%'`);
    test:assertEquals(sqlKeyHolders, 3, "apply_ledger_entry, rerank and rebuild take 1634561133 and name the order");
    int otherHolders = check db->queryRow(`
        SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.prosrc LIKE '%1634561133%' AND n.nspname <> 'recognition'`);
    test:assertEquals(otherHolders, 0, "only the recognition functions take the SQL-level key");
    check db.close();
}
