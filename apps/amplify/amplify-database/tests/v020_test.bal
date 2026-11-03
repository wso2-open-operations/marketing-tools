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


// V020: identity_employee_alias maps a re-created Asgardeo account's `sub` to the employee id the person already has.
// One mapping per `sub`, never a self-alias.

import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV020EmployeeAliasTable() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client api = check apiClient();
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version = 'V020__employee_alias'`);
    test:assertEquals(applied, 1);

    _ = check api->execute(`INSERT INTO identity_employee_alias (alias_sub, employee_id) VALUES ('v020-new-sub', 'v020-first')`);
    assertViolates(failure(api, `INSERT INTO identity_employee_alias (alias_sub, employee_id)
            VALUES ('v020-new-sub', 'v020-other')`), "employee_alias_pkey");
    assertViolates(failure(api, `INSERT INTO identity_employee_alias (alias_sub, employee_id)
            VALUES ('v020-self', 'v020-self')`), "employee_alias_not_self_ck");
    string mapped = check api->queryRow(`SELECT employee_id FROM identity_employee_alias WHERE alias_sub = 'v020-new-sub'`);
    test:assertEquals(mapped, "v020-first");
    int seen = check jobs->queryRow(`SELECT count(*)::int FROM identity_employee_alias WHERE alias_sub = 'v020-new-sub'`);
    test:assertEquals(seen, 1);
    check admin.close();
    check api.close();
    check jobs.close();
}
