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

// Team rosters from the people directory (D13): grouping by sub-team with the team as fallback, and the
// viewer's roster lookup.

import amplify_domain.recognition;

import ballerina/test;

final DirectoryRecord[] & readonly DIRECTORY = [
    {workEmail: "Ada@WSO2.com", team: "Customer Success", subTeam: "Forward Deployed Engineering"},
    {workEmail: "grace@wso2.com", team: "Customer Success", subTeam: "Forward Deployed Engineering"},
    {workEmail: "linus@wso2.com", team: "Customer Success", subTeam: "Support"},
    {workEmail: "ken@wso2.com", team: "Marketing", subTeam: ()},
    {workEmail: "dennis@wso2.com", team: "Marketing", subTeam: "  "},
    // Same sub-team name under another team: a different team.
    {workEmail: "barbara@wso2.com", team: "Engineering", subTeam: "Support"},
    // No team at all: left out.
    {workEmail: "nobody@wso2.com", team: (), subTeam: ()},
    // No email (null or missing): skipped, and the rest of the directory still works.
    {workEmail: (), team: "Customer Success", subTeam: "Forward Deployed Engineering"},
    {team: "Customer Success", subTeam: "Forward Deployed Engineering"}
];

@test:Config
function testRosterGroupsBySubTeam() {
    Roster? roster = rosterFrom(indexDirectory(DIRECTORY), "grace@wso2.com");
    test:assertEquals(roster, {teamName: "Forward Deployed Engineering", emails: ["ada@wso2.com", "grace@wso2.com"], houses: {}, names: {}});
}

@test:Config
function testRosterFallsBackToTeam() {
    Roster? roster = rosterFrom(indexDirectory(DIRECTORY), "ken@wso2.com");
    test:assertEquals(roster, {teamName: "Marketing", emails: ["ken@wso2.com", "dennis@wso2.com"], houses: {}, names: {}});
}

@test:Config
function testRosterCarriesEachMembersHouse() {
    DirectoryRecord[] rows = [
        {workEmail: "a@wso2.com", team: "Marketing", house: " Oak "},
        {workEmail: "b@wso2.com", team: "Marketing"},
        {workEmail: "c@wso2.com", team: "Marketing", house: "Elm"}
    ];
    Roster roster = <Roster>rosterFrom(indexDirectory(rows), "A@wso2.com");
    test:assertEquals(roster.houses, {"a@wso2.com": "Oak", "c@wso2.com": "Elm"}, "a member with no house is left out");
}

@test:Config
function testRosterKeepsSameNamedSubTeamsApart() {
    DirectoryIndex index = indexDirectory(DIRECTORY);
    test:assertEquals(rosterFrom(index, "linus@wso2.com")?.emails, ["linus@wso2.com"]);
    test:assertEquals(rosterFrom(index, "barbara@wso2.com")?.emails, ["barbara@wso2.com"]);
}

@test:Config
function testRosterMatchesEmailIgnoringCase() {
    test:assertEquals(rosterFrom(indexDirectory(DIRECTORY), " ADA@wso2.COM ")?.teamName,
            "Forward Deployed Engineering");
}

@test:Config
function testNoRosterWithoutTeamOrDirectoryRow() {
    DirectoryIndex index = indexDirectory(DIRECTORY);
    test:assertEquals(rosterFrom(index, "nobody@wso2.com"), ());
    test:assertEquals(rosterFrom(index, "stranger@wso2.com"), ());
}

@test:Config
function testRowsWithoutEmailDontBreakTheDirectory() returns error? {
    json raw = [{workEmail: "ada@wso2.com", team: "T", subTeam: "S"}, {workEmail: (), team: "T", subTeam: "S"},
        {firstName: "No email at all", team: "T", subTeam: "S"}];
    DirectoryRecord[] rows = check raw.cloneWithType();
    test:assertEquals(rosterFrom(indexDirectory(rows), "ada@wso2.com")?.emails, ["ada@wso2.com"]);
}


// ---- Business units, employee count, group boards (ADR-035) ------------------------------------------

final DirectoryRecord[] & readonly BU_DIRECTORY = [
    {workEmail: "a@wso2.com", team: "Engineering", subTeam: "Platform", businessUnit: "Product"},
    {workEmail: "b@wso2.com", team: "Engineering", subTeam: "Platform", businessUnit: "Product"},
    {workEmail: "c@wso2.com", team: "Engineering", subTeam: "Digital", businessUnit: "Corporate"},
    {workEmail: "d@wso2.com", team: "Engineering", subTeam: "Digital", businessUnit: "Product"},
    {workEmail: "e@wso2.com", team: "Marketing", subTeam: (), businessUnit: "Corporate"},
    // Counted in the headcount and its BU, but in no team.
    {workEmail: "f@wso2.com", team: (), subTeam: (), businessUnit: "Corporate"},
    // Same person twice: counted once.
    {workEmail: "A@wso2.com", team: "Engineering", subTeam: "Platform", businessUnit: "Product"},
    // No email: not an employee we can count.
    {workEmail: (), team: "Marketing", subTeam: (), businessUnit: "Corporate"}
];

@test:Config
function testIndexKeepsBusinessUnitsAndTheFullCount() {
    DirectoryIndex index = indexDirectory(BU_DIRECTORY);
    test:assertEquals(index.total, 6, "everyone with a work email, once, team or not");
    test:assertEquals(index.buMembers["Corporate"], ["c@wso2.com", "e@wso2.com", "f@wso2.com"]);
    test:assertEquals(index.buOf["a@wso2.com"], "Product");
    test:assertEquals(index.teamBu["Product/Engineering/Platform"], "Product");
    // Two people in one team under different BUs are two teams: the BU is the directory's, never worked out.
    test:assertEquals(index.teamBu["Corporate/Engineering/Digital"], "Corporate");
    test:assertEquals(index.teamBu["Product/Engineering/Digital"], "Product");
}

@test:Config
function testIndexAndHeadcountByHouse() {
    DirectoryIndex index = indexDirectory([
        {workEmail: "a@wso2.com", house: "Oak"},
        {workEmail: "b@wso2.com", house: " Oak "},
        {workEmail: "c@wso2.com", house: "Elm"},
        {workEmail: "d@wso2.com"}
    ]);
    test:assertEquals(index.houseOf["b@wso2.com"], "Oak");
    test:assertEquals(index.houseMembers["Oak"], ["a@wso2.com", "b@wso2.com"]);
    test:assertEquals(index.houseOf["d@wso2.com"], (), "no house, left out");
    test:assertEquals(headcountOf(index, [1760000000, 0]).houses, [{name: "Oak", headcount: 2}, {name: "Elm", headcount: 1}]);
}

@test:Config
function testHeadcountByBuAndTeam() {
    HeadcountSnapshot snapshot = headcountOf(indexDirectory(BU_DIRECTORY), [1760000000, 0]);
    test:assertEquals(snapshot.total, 6);
    test:assertEquals(snapshot.businessUnits, [{name: "Corporate", headcount: 3}, {name: "Product", headcount: 3}]);
    test:assertEquals(snapshot.teams.map(t => [t.name, t.businessUnit, t.headcount]),
            [["Platform", "Product", 2], ["Digital", "Corporate", 1], ["Digital", "Product", 1],
            ["Marketing", "Corporate", 1]]);
}

@test:Config
function testGroupRowsSumPointsAndKeepUnplacedPeople() returns error? {
    DirectoryIndex index = indexDirectory(BU_DIRECTORY);
    HeadcountSnapshot snapshot = headcountOf(index, [1760000000, 0]);
    recognition:EmailPoints[] points = [
        {email: "a@wso2.com", totalPoints: 50}, {email: "b@wso2.com", totalPoints: 30},
        {email: "e@wso2.com", totalPoints: 80}, {email: "stranger@wso2.com", totalPoints: 7},
        // In a BU but no team: unplaced on the team board, counted on the BU board.
        {email: "f@wso2.com", totalPoints: 4}
    ];
    var [teams, unplaced, unplacedPoints] = groupRows(index, snapshot, points, "TEAM", ());
    test:assertEquals(teams.length(), 4, "teams with no points are listed too");
    test:assertEquals(unplaced, 2);
    test:assertEquals(unplacedPoints, 11);
    json[] ranked = rankGroups(teams);
    test:assertEquals(check ranked[0].key, "Corporate/Marketing/", "Marketing and Platform tie on 80: by name");
}

@test:Config
function testRankGroupsShareARankOnATie() returns error? {
    GroupRow[] rows = [
        {key: "a", name: "Alpha", businessUnit: (), points: 80, participants: 2, headcount: 4},
        {key: "b", name: "Beta", businessUnit: (), points: 80, participants: 1, headcount: 0},
        {key: "c", name: "Gamma", businessUnit: (), points: 10, participants: 1, headcount: 2}
    ];
    json[] ranked = rankGroups(rows);
    test:assertEquals(ranked.map(r => checkpanic r.rank), [1, 1, 2], "dense rank");
    test:assertEquals(ranked.map(r => checkpanic r.key), ["a", "b", "c"], "ties: by name");
    test:assertEquals(check ranked[0].participationRate, 0.5d);
    test:assertEquals(check ranked[1].participationRate, 0.0d, "no headcount: 0, never a division by zero");
}

@test:Config
function testGroupRowsFilterTeamsByBu() {
    DirectoryIndex index = indexDirectory(BU_DIRECTORY);
    HeadcountSnapshot snapshot = headcountOf(index, [1760000000, 0]);
    var [teams, _, _] = groupRows(index, snapshot, [{email: "a@wso2.com", totalPoints: 5}], "TEAM", "Product");
    test:assertEquals(teams.map(t => t.name).sort(), ["Digital", "Platform"]);
    var [bus, _, _] = groupRows(index, snapshot, [{email: "a@wso2.com", totalPoints: 5}], "BU", ());
    test:assertEquals(bus.map(t => t.name).sort(), ["Corporate", "Product"]);
}

@test:Config
function testGroupSortReordersButKeepsThePointsRank() returns error? {
    GroupRow[] rows = [
        {key: "a", name: "Alpha", businessUnit: (), points: 100, participants: 1, headcount: 50},
        {key: "b", name: "Beta", businessUnit: (), points: 60, participants: 9, headcount: 10},
        {key: "c", name: "Gamma", businessUnit: (), points: 80, participants: 4, headcount: 8}
    ];
    test:assertEquals(rankGroups(rows).map(r => checkpanic r.key), ["a", "c", "b"], "default: by rank, best first");
    json[] byRate = rankGroups(rows, "participation", "desc");
    test:assertEquals(byRate.map(r => checkpanic r.key), ["b", "c", "a"], "participation, highest on top");
    test:assertEquals(byRate.map(r => checkpanic r.rank), [3, 2, 1], "the points rank doesn't change");
    test:assertEquals(rankGroups(rows, "participation", "asc").map(r => checkpanic r.key), ["a", "c", "b"]);
    test:assertEquals(rankGroups(rows, "name", "desc").map(r => checkpanic r.key), ["c", "b", "a"]);
    test:assertEquals(rankGroups(rows, "headcount", "desc").map(r => checkpanic r.key), ["a", "b", "c"]);
    test:assertEquals(rankGroups(rows, "participants", "desc").map(r => checkpanic r.key), ["b", "c", "a"]);
    test:assertEquals(rankGroups(rows, "points", "asc").map(r => checkpanic r.key), ["b", "c", "a"]);
    test:assertEquals(rankGroups(rows, "rank", "desc").map(r => checkpanic r.key), ["b", "c", "a"]);
}

@test:Config
function testRosterCarriesDirectoryNames() {
    DirectoryRecord[] rows = [
        {workEmail: "a@wso2.com", firstName: " Ada ", lastName: "Lovelace", team: "Marketing"},
        {workEmail: "b@wso2.com", firstName: "Grace", team: "Marketing"},
        {workEmail: "c@wso2.com", team: "Marketing"},
        {workEmail: "d@wso2.com", firstName: "Dee", lastName: "Outsider", team: ()}
    ];
    DirectoryIndex index = indexDirectory(rows);
    Roster roster = <Roster>rosterFrom(index, "a@wso2.com");
    test:assertEquals(roster.names, {"a@wso2.com": "Ada Lovelace", "b@wso2.com": "Grace"},
            "a member with no name is left out, so the standing's name or the email fills in");
    recognition:RosterMember[] team = membersOf(roster);
    test:assertEquals(team, [{email: "a@wso2.com", name: "Ada Lovelace"}, {email: "b@wso2.com", name: "Grace"},
        {email: "c@wso2.com", name: ""}]);
    recognition:RosterMember[] company = everyoneIn(index);
    test:assertEquals(company.length(), 4, "the company roster includes people with no team");
    test:assertEquals(company[3], {email: "d@wso2.com", name: "Dee Outsider"});
}

@test:Config
function testDirectoryCacheDefaultsToTwentyFourHours() {
    test:assertEquals(rosterCacheSeconds, 86400d, "teams and names are reused for 24 hours");
    test:assertEquals(headcountCacheSeconds, 86400d, "the same directory read, the same TTL");
}
