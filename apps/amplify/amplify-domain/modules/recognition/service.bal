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

# Ranks totals the way `recognition.standing` stores them: SQL dense rank by points (ties share a rank,
# so the top N may hold more than N people), then name for a stable order.
# `pointsToTopN` = points of the lowest-ranked person inside the top N − own points + 1, or 0 when already
# in (leaderboards.md). `pointsToNextRank` = points of the next better rank − own points.
#
# + periodKey - Period
# + totals - Totals for the period
# + previousRanks - Ranks before this re-rank, by employee id
# + topN - `leaderboard.top_n`
# + return - Standings, best first
public isolated function rankStandings(string periodKey, EmployeeTotal[] totals, map<int> previousRanks = {},
        int topN = DEFAULT_TOP_N) returns Standing[] {
    EmployeeTotal[] sorted = from EmployeeTotal t in totals
        order by t.totalPoints descending, t.displayName ascending, t.employeeId ascending
        select t;
    int[] rankPoints = [];
    foreach EmployeeTotal t in sorted {
        if rankPoints.length() == 0 || rankPoints[rankPoints.length() - 1] != t.totalPoints {
            rankPoints.push(t.totalPoints);
        }
    }
    int lastTopIndex = (topN < rankPoints.length() ? topN : rankPoints.length()) - 1;
    int topNFloor = lastTopIndex >= 0 ? rankPoints[lastTopIndex] : 0;
    Standing[] standings = [];
    foreach EmployeeTotal t in sorted {
        int rank = <int>rankPoints.indexOf(t.totalPoints) + 1;
        standings.push({
            periodKey,
            employeeId: t.employeeId,
            displayName: t.displayName,
            email: t.email,
            totalPoints: t.totalPoints,
            rank,
            previousRank: previousRanks[t.employeeId],
            pointsToNextRank: rank == 1 ? 0 : rankPoints[rank - 2] - t.totalPoints,
            pointsToTopN: rank <= topN ? 0 : topNFloor - t.totalPoints + 1,
            lastActivityAt: t.lastActivityAt
        });
    }
    return standings;
}

# Company top N (B15): everyone whose dense rank is within `topN`.
#
# + standings - Ranked standings
# + topN - `leaderboard.top_n`
# + return - Top rows; may be more than `topN` on ties
public isolated function topN(Standing[] standings, int topN = DEFAULT_TOP_N) returns Standing[] =>
    from Standing s in standings
    where s.rank <= topN
    select s;

# My Team (B15): the viewer's team ranked within itself (dense rank over that set).
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
