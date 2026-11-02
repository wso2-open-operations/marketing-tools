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

// V006: a reversal carries the action of the row it reverses (a trigger: a CHECK cannot compare two rows). A PO adjustment
// has no action, so its reversal has none either and must still be accepted.

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testReversalMustCarryTheActionOfTheRowItReverses() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    // Two originals: an adjustment that names an action, and one that does not.
    _ = check admin->execute(`INSERT INTO scoring.points_ledger (reference, employee_id, source_type, action, points, actor_id, reason)
        VALUES ('ADJ-rev-a', 'rev-1', 'ADJUSTMENT', 'SHARE', 5, 'po-1', 'with action'),
               ('ADJ-rev-b', 'rev-1', 'ADJUSTMENT', NULL, 5, 'po-1', 'no action')`);

    sql:ExecutionResult|sql:Error wrong = admin->execute(`INSERT INTO scoring.points_ledger
            (reference, employee_id, source_type, action, points, reverses_reference, actor_id, reason)
        VALUES ('REV-rev-a-wrong', 'rev-1', 'REVERSAL', NULL, -5, 'ADJ-rev-a', 'po-1', 'x')`);
    test:assertTrue(wrong is sql:Error && wrong.message().includes("must carry the action"),
            "a reversal that drops the action is refused");
    sql:ExecutionResult|sql:Error other = admin->execute(`INSERT INTO scoring.points_ledger
            (reference, employee_id, source_type, action, points, reverses_reference, actor_id, reason)
        VALUES ('REV-rev-a-other', 'rev-1', 'REVERSAL', 'REPOST', -5, 'ADJ-rev-a', 'po-1', 'x')`);
    test:assertTrue(other is sql:Error, "a reversal that names another action is refused");
    sql:ExecutionResult|sql:Error invented = admin->execute(`INSERT INTO scoring.points_ledger
            (reference, employee_id, source_type, action, points, reverses_reference, actor_id, reason)
        VALUES ('REV-rev-b-invented', 'rev-1', 'REVERSAL', 'SHARE', -5, 'ADJ-rev-b', 'po-1', 'x')`);
    test:assertTrue(invented is sql:Error, "a reversal of an action-less adjustment cannot invent one");

    // The matching reversals go in.
    _ = check admin->execute(`INSERT INTO scoring.points_ledger
            (reference, employee_id, source_type, action, points, reverses_reference, actor_id, reason)
        VALUES ('REV-rev-a-ok', 'rev-1', 'REVERSAL', 'SHARE', -5, 'ADJ-rev-a', 'po-1', 'x'),
               ('REV-rev-b-ok', 'rev-1', 'REVERSAL', NULL, -5, 'ADJ-rev-b', 'po-1', 'x')`);
    int total = check admin->queryRow(`SELECT count(*)::int FROM scoring.points_ledger WHERE employee_id = 'rev-1'`);
    test:assertEquals(total, 4);
    check admin.close();
}
