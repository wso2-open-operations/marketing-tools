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

import ballerina/http;
import ballerina/test;

final http:Client stubClient = check new (string `http://localhost:${port}`);

@test:Config
function servesTheDirectory() returns error? {
    json[] rows = check stubClient->get("/employees/basic-info");
    test:assertTrue(rows.length() > 0);
    test:assertTrue(rows[0].workEmail is string);
    test:assertTrue(rows[0].team is string);
}

@test:Config
function allowsTheLocalOneWso2() returns error? {
    http:Response res = check stubClient->options("/employees/basic-info", {
        "Origin": "http://localhost:3000",
        "Access-Control-Request-Method": "GET",
        "Access-Control-Request-Headers": "authorization"
    });
    test:assertEquals(res.getHeader("Access-Control-Allow-Origin"), "http://localhost:3000");
}

@test:Config
function answersTheHrEntityQuery() returns error? {
    json request = {
        query: "query getEmployees($filter: EmployeeFilter!, $limit: Int, $offset: Int) { employees { workEmail } }",
        variables: {filter: {employeeStatus: ["Active"]}, 'limit: 1, offset: 0}
    };
    json body = check stubClient->post("/graphql", request);
    json[] page = <json[]>check body.data.employees;
    test:assertEquals(page.length(), 1, "one row per page");
    test:assertTrue(page[0].workEmail is string);
}

@test:Config
function answersHouseOnlyWhenTheQueryAsksForIt() returns error? {
    json without = {
        query: "query getEmployees($filter: EmployeeFilter!, $limit: Int, $offset: Int) { employees { workEmail team } }",
        variables: {filter: {employeeStatus: ["Active"]}, 'limit: 1, offset: 0}
    };
    json plainBody = check stubClient->post("/graphql", without);
    json[] plain = <json[]>check plainBody.data.employees;
    map<json> plainRow = <map<json>>plain[0];
    test:assertFalse(plainRow.hasKey("house"), "no house unless asked");
    json asking = {
        query: "query getEmployees($filter: EmployeeFilter!, $limit: Int, $offset: Int) { employees { workEmail houseId house } }",
        variables: {filter: {employeeStatus: ["Active"]}, 'limit: 1, offset: 0}
    };
    json houseBody = check stubClient->post("/graphql", asking);
    json[] withHouse = <json[]>check houseBody.data.employees;
    map<json> houseRow = <map<json>>withHouse[0];
    test:assertTrue(houseRow.hasKey("house"), "house when asked");
}
