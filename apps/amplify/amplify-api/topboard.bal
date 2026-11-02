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


// The Celebrate "Top three amplifiers" board. Company wide (never narrowed to a team): the monthly top N is
// summed from the points ledger for the current calendar month (the 1st 00:00 UTC to the next 1st) and kept
// in memory for `topBoardCacheSeconds` (default 2 hours). The first caller after it runs out loads the
// totals; everyone else reuses them. The viewer's own line ("My position") comes from the same cached
// totals, so it matches the top three. `leaderboard.top_scope = ALL` serves the all-time standings instead.

import amplify_api.auth;
import amplify_common.resilience;
import amplify_domain.recognition;

import ballerina/http;
import ballerina/log;
import ballerina/time;

# How long the monthly totals are reused, seconds (2 hours). 0 = read every time.
configurable decimal topBoardCacheSeconds = 7200;

# `Cache-Control` of the top board: the body holds the viewer's own position, so it is private.
const string TOP_BOARD_CACHE = "private, max-age=60";

# Monthly points per employee as of `loadedAt`.
type MonthlyTotals record {|
    # The 1st, 00:00 UTC, of the month the totals are for
    time:Utc monthStart;
    # One total per employee with points that month
    recognition:EmployeeTotal[] totals;
    # When the totals were read
    time:Utc loadedAt;
    # Monotonic time of the read, for the lifetime check
    decimal readAt;
|};

isolated MonthlyTotals? monthlyCache = ();

# Entries in the monthly cache (0 or 1; test seam).
#
# + return - Cached entries
isolated function monthlyCacheSize() returns int {
    lock {
        return monthlyCache is () ? 0 : 1;
    }
}

# Empties the monthly cache (test seam).
isolated function dropMonthlyCache() {
    lock {
        monthlyCache = ();
    }
}

# The monthly totals for the month holding `now`: the cached copy while it is fresh and from the same month,
# else a new read. A failed read falls back to an older copy of the same month rather than failing the
# Celebrate page; with none it returns the error.
#
# + now - Current time
# + return - Totals, or an error when none can be had
isolated function monthlyTotals(time:Utc now) returns MonthlyTotals|error {
    time:Utc monthStart = recognition:monthStartOf(now);
    decimal mono = time:monotonicNow();
    MonthlyTotals? stale = ();
    lock {
        MonthlyTotals? hit = monthlyCache;
        if hit is MonthlyTotals && hit.monthStart == monthStart {
            if mono - hit.readAt < topBoardCacheSeconds {
                return hit.clone();
            }
            stale = hit.clone();
        }
    }
    recognition:EmployeeTotal[]|error totals = monthlyTotalsRead(monthStart);
    if totals is error {
        if stale is MonthlyTotals {
            log:printWarn("Monthly top board read failed, serving the previous totals", reason = resilience:loggable(totals).message());
            return stale;
        }
        return totals;
    }
    MonthlyTotals fresh = {monthStart, totals, loadedAt: now, readAt: mono};
    lock {
        monthlyCache = fresh.clone();
    }
    return fresh;
}

# The people who earned at least `minPoints` in the month: only they are ranked for the top three. Done per
# request from the cached totals, so a new `leaderboard.top_min_points` applies at once.
#
# + totals - Everyone with points this month
# + minPoints - Points needed to qualify
# + return - The qualifying totals
isolated function qualifying(recognition:EmployeeTotal[] totals, int minPoints) returns recognition:EmployeeTotal[] =>
    from recognition:EmployeeTotal t in totals
    where t.totalPoints >= minPoints
    select t;

# One viewer's Celebrate board: the company top N and their own line, for the configured scope.
#
# + p - Caller
# + correlationId - Request correlation id
# + return - The board, or problem details
isolated function topBoard(auth:Principal p, string? correlationId) returns http:Response|ProblemResponse {
    do {
        Settings settings = check loadSettings();
        int topN = settings.topN;
        time:Utc now = time:utcNow();
        recognition:Standing[] top;
        recognition:Standing? mine;
        map<json> scopeInfo;
        int? ownMonthPoints = ();
        if settings.topScope == "MONTH" {
            MonthlyTotals month = check monthlyTotals(now);
            recognition:Standing[] ranked = recognition:rankStandings("MONTH", qualifying(month.totals, settings.topMinPoints), {}, topN);
            top = recognition:topN(ranked, topN);
            recognition:Standing[] own = from recognition:Standing s in ranked
                where s.employeeId == p.employeeId
                select s;
            mine = own.length() > 0 ? own[0] : ();
            // Someone under the minimum is not ranked, but still sees their own points and the gap to qualify.
            recognition:EmployeeTotal[] unranked = from recognition:EmployeeTotal t in month.totals
                where t.employeeId == p.employeeId && t.totalPoints < settings.topMinPoints
                select t;
            ownMonthPoints = unranked.length() > 0 ? unranked[0].totalPoints : ();
            scopeInfo = {
                period: "MONTH",
                minPoints: settings.topMinPoints,
                monthStart: ts(month.monthStart),
                monthEnd: ts(recognition:nextMonthStartOf(month.monthStart)),
                generatedAt: ts(month.loadedAt)
            };
        } else {
            top = check topStandings("ALL", topN);
            mine = check standingOf(p.employeeId, "ALL");
            scopeInfo = {period: "ALL", minPoints: (), monthStart: (), monthEnd: (), generatedAt: ts(now)};
        }
        scopeInfo["topN"] = topN;
        scopeInfo["company"] = from recognition:Standing s in top
            select {employeeId: s.employeeId, displayName: s.displayName, email: s.email,
                points: s.totalPoints, rank: s.rank, previousRank: s.previousRank};
        map<json> me = <map<json>>personal(p.employeeId, mine, topN).toJson();
        if ownMonthPoints is int {
            me["points"] = ownMonthPoints;
        }
        scopeInfo["me"] = me;
        http:Response res = check jsonBody(scopeInfo);
        cacheable(res, TOP_BOARD_CACHE);
        return res;
    } on fail error e {
        return failure(e, correlationId, "Top amplifiers");
    }
}
