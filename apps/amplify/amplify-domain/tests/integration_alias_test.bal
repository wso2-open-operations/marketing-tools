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

// A re-created Asgardeo account (group `integration`, `AMPLIFY_IT=true`): the new `sub` is an alias of the
// employee id the person already has (V020), written once with an audit row; a genuine email clash stays a typed
// conflict. Nothing in the ledger or the standing is rewritten.

import amplify_common.types;
import amplify_domain.identity;
import amplify_domain.scoring;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], enable: itEnabled}
function testRecreatedAccountIsAnAliasOfTheFirstEmployee() returns error? {
    postgresql:Client db = check api();
    string po = check newEmployee(db, "aliaspo");
    string first = check newEmployee(db, "aliasold");
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    _ = check scoring:adjustPoints(ledger, first, 30, "IT alias points", po, (), "it-alias-" + uniq(), time:utcNow());
    identity:PgEmployeeRepository repo = new (db);
    string email = first + "@wso2.com";
    string newSub = "sub-recreated-" + uniq();

    identity:ResolvedEmployee r = check identity:resolveEmployee(repo, newSub, email.toUpperAscii());
    test:assertEquals(r, {employeeId: first, aliased: true});
    // Idempotent: the same call again, one alias row, one audit row.
    test:assertEquals(check identity:resolveEmployee(repo, newSub, email), {employeeId: first, aliased: true});
    test:assertEquals(check count(db, `SELECT count(*)::int FROM identity.employee_alias WHERE alias_sub = ${newSub}`), 1);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit.audit_log
                                       WHERE action = 'EMPLOYEE_ALIASED' AND actor_id = ${newSub}`), 1);
    test:assertEquals(check repo.addAlias(newSub, "someone-else"), first, "the first mapping wins");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM identity.employee_alias WHERE alias_sub = ${newSub}`), 1);
    // No second employee row, and the history still belongs to the first id.
    test:assertEquals(check repo.findById(newSub), ());
    test:assertEquals(check count(db, `SELECT total_points FROM recognition.standing
                                       WHERE period_key = 'ALL' AND employee_id = ${first}`), 30);
    test:assertEquals(check repo.findAlias(newSub), first);
    identity:Employee? byEmail = check repo.findByEmail(email.toUpperAscii());
    test:assertEquals(byEmail is identity:Employee ? byEmail.employeeId : (), first, "email lookup is case-insensitive");

    // A genuine clash: another sub with its own record now presents this email.
    string other = check newEmployee(db, "aliasother");
    identity:ResolvedEmployee|types:DomainError|error clash = identity:resolveEmployee(repo, other, email);
    test:assertTrue(clash is types:DomainError);
    if clash is types:DomainError {
        test:assertEquals(clash.detail().code, types:ERR_EMAIL_CONFLICT);
    }
    test:assertEquals(check count(db, `SELECT count(*)::int FROM identity.employee_alias WHERE alias_sub = ${other}`), 0);
}
