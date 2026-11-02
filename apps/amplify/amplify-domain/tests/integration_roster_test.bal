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

// Roster page (group `integration`, `AMPLIFY_IT=true`): the people directory's roster joined to the
// standings, so a member nobody has recorded points for still shows with 0 points.

import amplify_domain.recognition;
import amplify_domain.scoring;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], enable: itEnabled}
function testRosterPageListsTheWholeTeamIncludingZeroPoints() returns error? {
    postgresql:Client db = check api();
    string tag = uniq();
    string po = check newEmployee(db, "rosterpo");
    string earner = check newEmployee(db, "rosterw");
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    _ = check scoring:adjustPoints(ledger, earner, 25, "IT roster points", po, (), "it-roster-" + tag, time:utcNow());
    string earnerEmail = earner + "@wso2.com";
    string neverSignedIn = "never-" + tag + "@wso2.com";
    string alsoNever = "also-" + tag + "@wso2.com";
    recognition:RosterMember[] members = [
        {email: neverSignedIn.toUpperAscii(), name: "Zed Never " + tag},
        {email: earnerEmail, name: "Wendy Earner " + tag},
        {email: alsoNever, name: "Abe Also " + tag},
        {email: neverSignedIn, name: "duplicate dropped"}
    ];
    recognition:RosterPage page = check recognition:rosterPage(db, recognition:PERIOD_ALL, members, (),
            recognition:SORT_RANK, 0, 10);
    test:assertEquals(page.total, 3, "the whole roster, repeats dropped");
    test:assertEquals(page.activeCount, 1, "one member has points");
    test:assertEquals(page.items[0].email, earnerEmail, "points first");
    test:assertEquals(page.items[0].employeeId, earner);
    test:assertEquals(page.items[0].totalPoints, 25);
    test:assertEquals(page.items[0].displayName, "Wendy Earner " + tag, "the directory's name wins");
    // Zero-point members: no employee id, no company rank, share the last team rank, ordered by name.
    test:assertEquals(page.items[1].email, alsoNever);
    test:assertEquals(page.items[2].email, neverSignedIn);
    foreach recognition:RosterEntry e in page.items.slice(1) {
        test:assertEquals(e.employeeId, ());
        test:assertEquals(e.rank, ());
        test:assertEquals(e.totalPoints, 0);
        test:assertEquals(e.teamRank, 2);
    }
    // Same answer asked again, and by name / points; a search ranks and counts against the whole roster.
    recognition:RosterPage byName = check recognition:rosterPage(db, recognition:PERIOD_ALL, members, (),
            recognition:SORT_NAME, 0, 10);
    test:assertEquals(byName.items.map(e => e.email), [alsoNever, earnerEmail, neverSignedIn], "Abe, Wendy, Zed");
    recognition:RosterPage found = check recognition:rosterPage(db, recognition:PERIOD_ALL, members,
            "Zed", recognition:SORT_RANK, 0, 10);
    test:assertEquals(found.total, 1);
    test:assertEquals(found.activeCount, 1, "the active count is of the roster, not the search");
    test:assertEquals(found.items[0].teamRank, 2);
    recognition:RosterPage pastEnd = check recognition:rosterPage(db, recognition:PERIOD_ALL, members, (),
            recognition:SORT_RANK, 5, 10);
    test:assertEquals(pastEnd.items.length(), 0);
    test:assertEquals(pastEnd.total, 3);
    test:assertEquals(pastEnd.activeCount, 1);
    recognition:RosterPage empty = check recognition:rosterPage(db, recognition:PERIOD_ALL, [], (),
            recognition:SORT_RANK, 0, 10);
    test:assertEquals(empty.total, 0);
}
