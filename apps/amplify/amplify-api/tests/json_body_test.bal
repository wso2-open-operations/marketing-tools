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

// `json_body.bal` must put the same bytes on the wire as a plain `json` return did (M11b): `/team` moved
// onto it to dodge the JDK 21 writer's buffer growth, and the response body is a published contract.

import ballerina/http;
import ballerina/test;

# A `/team` page of `rows` rows, the shape `teamView` builds.
#
# + rows - Rows
# + return - The body
function teamPageShape(int rows) returns json {
    json[] entries = [];
    foreach int i in 0..<rows {
        entries.push({
            employeeId: string `lt-0${100 + i}`,
            displayName: string `Load Tester ${100 + i}`,
            email: string `lt-0${100 + i}@wso2.com`,
            points: 590 - i,
            rank: i + 1,
            teamRank: i + 1,
            previousRank: (),
            lastActivityAt: "2026-10-15T13:53:55.428Z",
            actions: {canAdjust: true, canReverse: true}
        });
    }
    return {period: "ALL", scope: "COMPANY", page: 0, size: rows, total: 1000, teamStatus: "OK",
            summary: {headcount: (), activeCount: 1000}, entries};
}

@test:Config
function testJsonTextMatchesTheStandardEncoder() returns error? {
    json[] bodies = [
        {},
        {period: "ALL", entries: []},
        {escapes: "quote \" backslash \\ newline \n tab \t unicode é", empty: "", nothing: ()},
        {numbers: [0, -1, 2147483647, 1.5], flags: [true, false, ()]},
        teamPageShape(1),
        teamPageShape(25)
    ];
    foreach json body in bodies {
        test:assertEquals(check jsonText(body), body.toJsonString(),
                string `jsonText must match the encoder for a ${body.toJsonString().length()} byte body`);
    }
}

@test:Config
function testJsonBodyIsJsonWithTheSameBytes() returns error? {
    json body = teamPageShape(25);
    http:Response res = check jsonBody(body);
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(res.getContentType(), "application/json");
    test:assertEquals(check res.getTextPayload(), body.toJsonString());
}
