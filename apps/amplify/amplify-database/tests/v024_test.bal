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

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

isolated function insertClaim(postgresql:Client db, string id, string employeeId, string? note) returns sql:ExecutionResult|sql:Error {
    string url = "https://www.linkedin.com/feed/update/urn:li:activity:" + id.substring(id.length() - 12);
    return db->execute(`
        INSERT INTO external_sharing_external_share (id, employee_id, action, evidence_url, evidence_url_submitted,
            evidence_host, provider, certified_at, note)
        VALUES (CAST(${id} AS uuid), ${employeeId}, 'OWN_POST', ${url}, ${url}, 'www.linkedin.com', 'linkedin',
            now(), ${note})`);
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testV024ExternalShareNote() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    int applied = check admin->queryRow(`SELECT count(*)::int FROM schema_version
                                         WHERE version = 'V024__external_share_note'`);
    test:assertEquals(applied, 1);

    _ = check insertClaim(admin, "0192f0e0-0000-7000-8000-000000000241", "note-writer", "A post about our new agent platform");
    _ = check insertClaim(admin, "0192f0e0-0000-7000-8000-000000000242", "note-writer", ());
    record {|string? note; string status;|} row = check admin->queryRow(`
        SELECT note, status FROM external_sharing_external_share_v WHERE id = '0192f0e0-0000-7000-8000-000000000241'`);
    test:assertEquals(row.note, "A post about our new agent platform", "the recreated view carries the note");
    test:assertEquals(row.status, "PENDING", "and still derives the status");

    string long = "";
    foreach int i in 0 ..< 501 {
        long += "x";
    }
    test:assertTrue(insertClaim(admin, "0192f0e0-0000-7000-8000-000000000243", "note-writer", long) is error,
            "a note over 500 characters is refused");
    test:assertTrue(insertClaim(admin, "0192f0e0-0000-7000-8000-000000000244", "note-writer", "") is error,
            "an empty note is stored as no note, never as ''");

    // Erasure clears the note: it is the person's own words. The claim itself stays (pseudonymous).
    string result = check jobs->queryRow(`SELECT identity_erase_employee('note-writer', 'system', 'leaver sweep')::text`);
    test:assertTrue(result.includes("\"claimNotes\": 1"), result);
    int notes = check admin->queryRow(`SELECT count(*)::int FROM external_sharing_external_share
                                        WHERE employee_id = 'note-writer' AND note IS NOT NULL`);
    test:assertEquals(notes, 0);
    int claims = check admin->queryRow(`SELECT count(*)::int FROM external_sharing_external_share
                                         WHERE employee_id = 'note-writer'`);
    test:assertEquals(claims, 2, "the claims stay");
    string again = check jobs->queryRow(`SELECT identity_erase_employee('note-writer', 'system', 'again')::text`);
    test:assertTrue(again.includes("\"claimNotes\": 0"), again);

    check jobs.close();
    check admin.close();
}
