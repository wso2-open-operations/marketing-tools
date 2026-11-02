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

import ballerina/test;
import ballerina/time;

function totals() returns EmployeeTotal[] => [
    total("e1", "Avery", 100),
    total("e2", "Blake", 80),
    total("e3", "Casey", 80),
    total("e4", "Devon", 60),
    total("e5", "Emery", 40)
];

function total(string id, string name, int points) returns EmployeeTotal =>
    {employeeId: id, displayName: name, email: name.toLowerAscii() + "@wso2.com", totalPoints: points, lastActivityAt: ()};

@test:Config
function denseRankSharesTies() {
    Standing[] s = rankStandings(PERIOD_ALL, totals(), {"e4": 2});
    test:assertEquals(s.map(r => r.rank), [1, 2, 2, 3, 4]);
    test:assertEquals(s[3].previousRank, 2, "movement arrow source");
    test:assertEquals(topN(s).length(), 4, "ties can return more than N rows");
}

@test:Config
function gapsToNextRankAndTopN() {
    Standing[] s = rankStandings(PERIOD_ALL, totals());
    test:assertEquals(s.map(r => r.pointsToNextRank), [0, 20, 20, 20, 20]);
    test:assertEquals(s.map(r => r.pointsToTopN), [0, 0, 0, 0, 21], "lowest in top 3 has 60: 60 - 40 + 1");
}

@test:Config
function fewerPeopleThanTopN() {
    Standing[] s = rankStandings(PERIOD_ALL, [total("e1", "Avery", 5)]);
    test:assertEquals(s[0].rank, 1);
    test:assertEquals(s[0].pointsToTopN, 0);
    test:assertEquals(rankStandings(PERIOD_ALL, []), []);
}

@test:Config
function myTeamRanksWithinTheTeam() {
    Standing[] company = rankStandings(PERIOD_ALL, totals());
    Standing[] team = teamStandings(PERIOD_ALL, company, ["DEVON@wso2.com", "emery@wso2.com"]);
    test:assertEquals(team.map(r => [r.employeeId, r.rank]), [["e4", 1], ["e5", 2]]);
}

@test:Config
function monthStartsOnTheFirstUtc() {
    time:Utc first = checkpanic time:utcFromString("2026-10-01T00:00:00Z");
    test:assertEquals(monthStartOf(checkpanic time:utcFromString("2026-10-22T16:22:57Z")), first);
    test:assertEquals(monthStartOf(first), first, "the 1st 00:00 starts its own month");
    test:assertEquals(monthStartOf(checkpanic time:utcFromString("2026-10-31T23:59:59Z")), first, "the last second is still that month");
    time:Utc nov = checkpanic time:utcFromString("2026-11-01T00:00:00Z");
    test:assertEquals(monthStartOf(nov), nov, "the next 1st starts a new month");
    test:assertEquals(nextMonthStartOf(first), nov);
    test:assertEquals(nextMonthStartOf(checkpanic time:utcFromString("2026-12-15T00:00:00Z")),
        checkpanic time:utcFromString("2027-01-01T00:00:00Z"), "December rolls into January");
}

@test:Config
function rosterColumnsLowercasesTrimsAndDropsRepeats() {
    var [emails, names] = rosterColumns([
        {email: " Ada@WSO2.com ", name: " Ada Lovelace "},
        {email: "ada@wso2.com", name: "Ada Again"},
        {email: "", name: "Nobody"},
        {email: "grace@wso2.com"}
    ]);
    test:assertEquals(emails, ["ada@wso2.com", "grace@wso2.com"]);
    test:assertEquals(names, ["Ada Lovelace", ""], "first name wins; no name stays blank for the fallback");
}
