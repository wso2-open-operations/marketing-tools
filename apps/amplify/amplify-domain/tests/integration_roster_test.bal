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
    // Zero-point members: no employee id, no company rank, ordered by name, each with its own position.
    test:assertEquals(page.items[1].email, alsoNever);
    test:assertEquals(page.items[2].email, neverSignedIn);
    test:assertEquals(page.items.map(e => e.teamRank), [1, 2, 3], "positions, no ties");
    foreach recognition:RosterEntry e in page.items.slice(1) {
        test:assertEquals(e.employeeId, ());
        test:assertEquals(e.rank, ());
        test:assertEquals(e.totalPoints, 0);
    }
    // Same answer asked again, and by name / points; a search ranks and counts against the whole roster.
    recognition:RosterPage byName = check recognition:rosterPage(db, recognition:PERIOD_ALL, members, (),
            recognition:SORT_NAME, 0, 10);
    test:assertEquals(byName.items.map(e => e.email), [alsoNever, earnerEmail, neverSignedIn], "Abe, Wendy, Zed");
    recognition:RosterPage found = check recognition:rosterPage(db, recognition:PERIOD_ALL, members,
            "Zed", recognition:SORT_RANK, 0, 10);
    test:assertEquals(found.total, 1);
    test:assertEquals(found.activeCount, 1, "the active count is of the roster, not the search");
    test:assertEquals(found.items[0].teamRank, 3, "the position in the whole roster, not in the search");
    recognition:RosterPage pastEnd = check recognition:rosterPage(db, recognition:PERIOD_ALL, members, (),
            recognition:SORT_RANK, 5, 10);
    test:assertEquals(pastEnd.items.length(), 0);
    test:assertEquals(pastEnd.total, 3);
    test:assertEquals(pastEnd.activeCount, 1);
    recognition:RosterPage empty = check recognition:rosterPage(db, recognition:PERIOD_ALL, [], (),
            recognition:SORT_RANK, 0, 10);
    test:assertEquals(empty.total, 0);
}

// Equal points: positions still run 1, 2, 3... Whoever reached the points first (earliest last activity) goes
// first, ahead of name order, as on the company top three; pages keep counting from the offset.
@test:Config {groups: ["integration"], enable: itEnabled}
function testRosterAndTeamPagesNumberTiesByWhoReachedThePointsFirst() returns error? {
    postgresql:Client db = check api();
    string tag = uniq();
    string po = check newEmployee(db, "tiepo");
    string first = check newEmployee(db, "tiefirst");
    string second = check newEmployee(db, "tiesecond");
    string leader = check newEmployee(db, "tielead");
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    // `first` reaches 10 before `second`; the ledger stamps each row with its insert time.
    _ = check scoring:adjustPoints(ledger, first, 10, "IT tie first", po, (), "it-tie-1-" + tag, time:utcNow());
    _ = check scoring:adjustPoints(ledger, second, 10, "IT tie second", po, (), "it-tie-2-" + tag, time:utcNow());
    _ = check scoring:adjustPoints(ledger, leader, 20, "IT tie leader", po, (), "it-tie-3-" + tag, time:utcNow());
    string zero = "tiezero-" + tag + "@wso2.com";
    // Names sort the other way round, so only the time can put `first` ahead of `second`.
    recognition:RosterMember[] members = [
        {email: first + "@wso2.com", name: "Zoe First " + tag},
        {email: second + "@wso2.com", name: "Abe Second " + tag},
        {email: leader + "@wso2.com", name: "Lee Leader " + tag},
        {email: zero, name: "Aaron Zero " + tag}
    ];
    recognition:RosterPage roster = check recognition:rosterPage(db, recognition:PERIOD_ALL, members, (),
            recognition:SORT_RANK, 0, 10);
    test:assertEquals(roster.items.map(e => e.email),
            [leader + "@wso2.com", first + "@wso2.com", second + "@wso2.com", zero]);
    test:assertEquals(roster.items.map(e => e.teamRank), [1, 2, 3, 4], "no shared positions");
    recognition:RosterPage secondPage = check recognition:rosterPage(db, recognition:PERIOD_ALL, members, (),
            recognition:SORT_RANK, 1, 2);
    test:assertEquals(secondPage.items.map(e => e.teamRank), [3, 4], "page two carries on from page one");
    test:assertEquals(secondPage.items.map(e => e.email), [second + "@wso2.com", zero]);
    recognition:RosterPage byName = check recognition:rosterPage(db, recognition:PERIOD_ALL, members, (),
            recognition:SORT_NAME, 0, 10);
    test:assertEquals(byName.items.map(e => e.teamRank), [4, 3, 1, 2], "sorting by name keeps each position");

    string[] emails = [first + "@wso2.com", second + "@wso2.com", leader + "@wso2.com"];
    recognition:TeamPage team = check recognition:teamPage(db, recognition:PERIOD_ALL, emails, (),
            recognition:SORT_RANK, 0, 10);
    test:assertEquals(team.items.map(e => e.standing.employeeId), [leader, first, second]);
    test:assertEquals(team.items.map(e => e.teamRank), [1, 2, 3]);

    // Whole company (stored-rank fast path): positions follow the page offset and match the window path's order.
    recognition:TeamPage company = check recognition:teamPage(db, recognition:PERIOD_ALL, (), (),
            recognition:SORT_RANK, 0, 1000);
    foreach int i in 0 ..< company.items.length() {
        test:assertEquals(company.items[i].teamRank, i + 1, "company positions run 1, 2, 3...");
    }
    int firstAt = <int>company.items.indexOf(company.items.filter(e => e.standing.employeeId == first)[0]);
    test:assertEquals(company.items[firstAt + 1].standing.employeeId, second, "earlier one first on the company list too");
    recognition:TeamPage companyPage = check recognition:teamPage(db, recognition:PERIOD_ALL, (), (),
            recognition:SORT_RANK, 1, 2);
    test:assertEquals(companyPage.items.map(e => e.teamRank), [3, 4]);
    test:assertEquals(companyPage.items.map(e => e.standing.employeeId),
            company.items.slice(2, 4).map(e => e.standing.employeeId));
    recognition:TeamPage companyByPoints = check recognition:teamPage(db, recognition:PERIOD_ALL, (), (),
            recognition:SORT_POINTS, 0, 1000);
    foreach recognition:TeamEntry e in companyByPoints.items {
        recognition:TeamEntry[] same = company.items.filter(c => c.standing.employeeId == e.standing.employeeId);
        test:assertEquals(e.teamRank, same[0].teamRank, "the position doesn't depend on the sort");
    }
}

// The stored company rank (the Team page's "Company rank", the podium and the people boards) is a position:
// 1, 2, 3... with no ties. Equal points go to whoever reached them first, then name, then employee id.
@test:Config {groups: ["integration"], enable: itEnabled}
function testCompanyRankIsAPositionWithTiesBrokenByTimeThenName() returns error? {
    postgresql:Client db = check api();
    string tag = uniq();
    string po = check newEmployee(db, "rankpo");
    string leader = check newEmployee(db, "ranklead");
    string early = check newEmployee(db, "rankearly");
    string tiedA = check newEmployee(db, "ranktieA");
    string tiedB = check newEmployee(db, "ranktieB");
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    // Far above anything another test awards, so these four are the top of the board.
    _ = check scoring:adjustPoints(ledger, leader, 3000000, "IT rank leader", po, (), "it-rk-1-" + tag, time:utcNow());
    _ = check scoring:adjustPoints(ledger, early, 2000000, "IT rank early", po, (), "it-rk-2-" + tag, time:utcNow());
    _ = check scoring:adjustPoints(ledger, tiedA, 2000000, "IT rank tie a", po, (), "it-rk-3-" + tag, time:utcNow());
    _ = check scoring:adjustPoints(ledger, tiedB, 2000000, "IT rank tie b", po, (), "it-rk-4-" + tag, time:utcNow());
    // `early` reached 2,000,000 first (the ledger stamps insert time). Make the last two reach it at the same
    // instant, and give them names that sort the other way round from their ids, so only the name decides.
    _ = check db->execute(`UPDATE recognition_standing SET last_activity_at = '2026-01-01T00:00:00Z',
                                  display_name = 'Zed Tie ' || ${tag} WHERE period_key = 'ALL' AND employee_id = ${tiedA}`);
    _ = check db->execute(`UPDATE recognition_standing SET last_activity_at = '2026-01-01T00:00:00Z',
                                  display_name = 'Abe Tie ' || ${tag} WHERE period_key = 'ALL' AND employee_id = ${tiedB}`);
    _ = check db->execute(`UPDATE recognition_standing SET last_activity_at = '2025-12-31T00:00:00Z'
                           WHERE period_key = 'ALL' AND employee_id = ${early}`);
    _ = check db->queryRow(`SELECT recognition_rerank('ALL', 3)`, int);

    // Stored ranks: one place each, none shared, and the order is points, time, name.
    int total = check count(db, `SELECT count(*)::int FROM recognition_standing WHERE period_key = 'ALL'`);
    int distinctRanks = check count(db, `SELECT count(DISTINCT rank)::int FROM recognition_standing
                                         WHERE period_key = 'ALL'`);
    int maxRank = check count(db, `SELECT max(rank)::int FROM recognition_standing WHERE period_key = 'ALL'`);
    test:assertEquals(distinctRanks, total, "no two people share a company rank");
    test:assertEquals(maxRank, total, "ranks run 1 to the number of people, no gaps");
    // The early one sits behind the leader, and the same-time pair is ordered by name: tiedB (Abe) first.
    int[] places = [];
    foreach string id in [leader, early, tiedB, tiedA] {
        recognition:Standing? s = check recognition:standingOf(db, id);
        places.push(s is recognition:Standing ? s.rank : -1);
    }
    test:assertEquals(places, [1, 2, 3, 4], "points, then earliest, then name");

    // The podium holds exactly three, even with three people on equal points at places two to four.
    recognition:Standing[] podium = check recognition:topStandings(db);
    test:assertEquals(podium.map(s => s.employeeId), [leader, early, tiedB]);
    test:assertEquals(podium.map(s => s.rank), [1, 2, 3]);

    // The gaps: 3,000,000 - 2,000,000 + 1 to pass the leader, 1 to pass the person tied ahead, and 1 to get into
    // the top three from fourth place.
    recognition:Standing? fourth = check recognition:standingOf(db, tiedA);
    if fourth is () {
        test:assertFail("standing missing");
    }
    test:assertEquals(fourth.pointsToNextRank, 1, "a tie goes to whoever got there first, so one more point");
    test:assertEquals(fourth.pointsToTopN, 1);
    recognition:Standing? second = check recognition:standingOf(db, early);
    test:assertEquals(second is recognition:Standing ? second.pointsToNextRank : -1, 1000001);
    test:assertEquals(second is recognition:Standing ? second.pointsToTopN : -1, 0);

    // The Team page (whole company, stored-rank fast path): company rank and position agree on every row, on
    // every page.
    recognition:TeamPage everyone = check recognition:teamPage(db, recognition:PERIOD_ALL, (), (),
            recognition:SORT_RANK, 0, 1000);
    foreach int i in 0 ..< everyone.items.length() {
        test:assertEquals(everyone.items[i].standing.rank, i + 1, "company rank is the position");
        test:assertEquals(everyone.items[i].teamRank, i + 1);
    }
    recognition:TeamPage pageTwo = check recognition:teamPage(db, recognition:PERIOD_ALL, (), (),
            recognition:SORT_RANK, 1, 2);
    test:assertEquals(pageTwo.items.map(e => e.standing.rank), [3, 4], "page two carries on from page one");
    test:assertEquals(pageTwo.items.map(e => e.teamRank), [3, 4]);
    // The window path (a name search) agrees with the stored rank.
    recognition:TeamPage found = check recognition:teamPage(db, recognition:PERIOD_ALL, (), "Tie " + tag,
            recognition:SORT_RANK, 0, 10);
    test:assertEquals(found.items.map(e => e.standing.employeeId), [tiedB, tiedA]);
    test:assertEquals(found.items.map(e => e.standing.rank), [3, 4]);
}
