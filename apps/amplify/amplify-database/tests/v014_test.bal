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


// V014 and S006: every action of the pilot points table can be priced and recorded, and each one has a rule in
// force from the pilot date, so no value waits on a later phase to be remembered.

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testV012IsApplied]}
function testEveryPointActionHasARuleInForce() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client db = check adminClient(itDbName);
    map<int> expected = {REPOST: 2, SHARE: 2, REPOST_COMMENTARY: 5, SHARE_COMMENTARY: 5, OWN_POST: 10,
        OWN_POST_AMPLIFIED: 25, REACTION: 1, COMMENT: 1, CHALLENGE_ENTRY: 10, CHALLENGE_WINNER: 25};
    foreach [string, int] [action, points] in expected.entries() {
        int inForce = check db->queryRow(`
            SELECT points FROM scoring.point_rule WHERE action = ${action} AND effective_from <= now()
            ORDER BY effective_from DESC LIMIT 1`);
        test:assertEquals(inForce, points, action);
    }
    // The ledger and the rule table both refuse an action that isn't in the table.
    foreach string tbl in ["point_rule", "points_ledger"] {
        int constraints = check db->queryRow(`
            SELECT count(*)::int FROM pg_constraint
            WHERE conrelid = ('scoring.' || ${tbl})::regclass AND conname = ${tbl + "_action_check"}
              AND pg_get_constraintdef(oid) LIKE '%CHALLENGE_WINNER%'`);
        test:assertEquals(constraints, 1, tbl);
    }
    postgresql:Client api = check apiClient();
    sql:ExecutionResult|sql:Error bogus = api->execute(`INSERT INTO scoring.point_rule (action, points, effective_from, created_by)
                              VALUES ('BOGUS', 1, now(), 'it')`);
    test:assertTrue(bogus is error, "an unpriced action is refused");
    check api.close();
    check db.close();
}
