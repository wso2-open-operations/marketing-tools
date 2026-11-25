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

// Reference implementation of the re-rank step (M3 does it with one window-function UPDATE). Tests pin
// the rules so the SQL can be checked against the same cases.

import ballerina/time;

# Ranks totals the way `recognition_standing` stores them: SQL row_number by points, so places run 1, 2, 3...
# with no ties. Equal points go to whoever reached them first (the earliest `lastActivityAt`; no timestamp
# sorts last), then name and id for a stable order. The Celebrate podium takes its first three rows.
# `pointsToTopN` = points of the person at place N − own points + 1, or 0 when already in (leaderboards.md).
# `pointsToNextRank` = points of the person one place ahead − own points + 1 (a tie goes to whoever got there
# first), 0 in first place.
#
# + periodKey - Period
# + totals - Totals for the period
# + previousRanks - Ranks before this re-rank, by employee id
# + topN - `leaderboard.top_n`
# + return - Standings, best first
public isolated function rankStandings(string periodKey, EmployeeTotal[] totals, map<int> previousRanks = {},
        int topN = DEFAULT_TOP_N) returns Standing[] {
    EmployeeTotal[] sorted = from EmployeeTotal t in totals
        order by t.totalPoints descending, reachedKey(t.lastActivityAt) ascending, t.displayName ascending,
            t.employeeId ascending
        select t;
    int topNFloor = sorted.length() == 0 ? 0 : sorted[(topN < sorted.length() ? topN : sorted.length()) - 1].totalPoints;
    Standing[] standings = [];
    foreach int index in 0 ..< sorted.length() {
        EmployeeTotal t = sorted[index];
        int rank = index + 1;
        standings.push({
            periodKey,
            employeeId: t.employeeId,
            displayName: t.displayName,
            email: t.email,
            totalPoints: t.totalPoints,
            rank,
            previousRank: previousRanks[t.employeeId],
            pointsToNextRank: index == 0 ? 0 : sorted[index - 1].totalPoints - t.totalPoints + 1,
            pointsToTopN: rank <= topN ? 0 : topNFloor - t.totalPoints + 1,
            lastActivityAt: t.lastActivityAt
        });
    }
    return standings;
}

# Sort key for "reached the points first": seconds since the epoch, or a far future value when unknown.
#
# + at - Time of the person's latest points entry
# + return - Key, smaller is earlier
isolated function reachedKey(time:Utc? at) returns decimal => at is () ? 99999999999999d : <decimal>at[0] + at[1];

# Company top N (B15): the first `topN` places.
#
# + standings - Ranked standings
# + topN - `leaderboard.top_n`
# + return - Top rows, at most `topN` (places never tie)
public isolated function topN(Standing[] standings, int topN = DEFAULT_TOP_N) returns Standing[] =>
    from Standing s in standings
    where s.rank <= topN
    select s;

# My Team (B15): the viewer's team ranked within itself (places 1, 2, 3... over that set).
#
# + periodKey - Period
# + standings - Company standings
# + teamEmails - Team roster from One WSO2 (ADR-009)
# + return - Team standings, ranked within the team
public isolated function teamStandings(string periodKey, Standing[] standings, string[] teamEmails) returns Standing[] {
    string[] roster = teamEmails.map(e => e.toLowerAscii());
    EmployeeTotal[] team = from Standing s in standings
        where roster.indexOf(s.email.toLowerAscii()) !is ()
        select {employeeId: s.employeeId, displayName: s.displayName, email: s.email, totalPoints: s.totalPoints,
            lastActivityAt: s.lastActivityAt};
    return rankStandings(periodKey, team);
}
