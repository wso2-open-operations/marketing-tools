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


// uuidv7(): native on PostgreSQL 18, the compatible function V001 installs before it (ADR-044). Either way an id
// is a version 7 uuid that carries the current time in its first 48 bits and sorts by creation across milliseconds.

import ballerina/test;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testUuidv7IsVersion7TimeOrderedAndRunsOnThisServer() returns error? {
    postgresql:Client db = check adminClient(itDbName);
    string first = check db->queryRow(`SELECT uuidv7()::text`);
    string _ = check db->queryRow(`SELECT pg_sleep(0.02)::text`);
    string second = check db->queryRow(`SELECT uuidv7()::text`);
    test:assertEquals(first.substring(14, 15), "7", "version nibble: " + first);
    test:assertTrue("89ab".includes(first.substring(19, 20)), "RFC 4122 variant: " + first);
    test:assertTrue(first < second, "ids made in different milliseconds sort by creation");
    // The first 48 bits are Unix milliseconds: within a minute of now.
    boolean recent = check db->queryRow(`
        SELECT abs(extract(epoch FROM now()) * 1000
                   - (('x' || replace(substring(uuidv7()::text FROM 1 FOR 13), '-', '')))::bit(48)::bigint) < 60000`);
    test:assertTrue(recent, "the timestamp is current");
    check db.close();
}
