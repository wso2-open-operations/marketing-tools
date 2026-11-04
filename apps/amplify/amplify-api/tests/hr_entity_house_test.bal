// Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
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

import ballerina/test;

@test:Config {groups: ["reads"]}
function testTheQueryAlwaysAsksForTheHouseFields() {
    string query = employeesQuery();
    test:assertTrue(query.includes("houseId house"), "house is always pulled in");
    test:assertTrue(query.includes("workEmail firstName lastName businessUnit department subTeam"), "and the rest is unchanged");
}

@test:Config {groups: ["reads"]}
function testAnEntityEmployeeWithAHouseFeedsTheIndex() returns error? {
    json rows = [
        {workEmail: "Ada@WSO2.com", firstName: "Ada", lastName: "L", businessUnit: "Eng", department: "Core", subTeam: (), houseId: 3, house: "Titans"},
        {workEmail: "grace@wso2.com", firstName: "Grace", lastName: "H", businessUnit: "Eng", department: "Core", subTeam: (), houseId: 3, house: "Titans"},
        {workEmail: "ken@wso2.com", firstName: "Ken", lastName: "T", businessUnit: "Eng", department: "Core", subTeam: (), houseId: (), house: ()}
    ];
    DirectoryRecord[] records = check rows.cloneWithType();
    test:assertEquals(records[0].houseId, 3);
    DirectoryIndex index = indexDirectory(records);
    test:assertEquals(index.houseOf["ada@wso2.com"], "Titans");
    test:assertEquals(index.houseOf["ken@wso2.com"], (), "no house is left out, not an error");
    test:assertEquals(index.houseMembers["Titans"], ["ada@wso2.com", "grace@wso2.com"]);
}
