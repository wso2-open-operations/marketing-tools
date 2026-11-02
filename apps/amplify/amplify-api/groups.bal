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


// Leaderboards by group and the employee count (ADR-035). The company board is open to every employee: people
// ranked within the company, a business unit (BU) or a team, and the teams or BUs ranked against each
// other. Amplify stores no org data (ADR-009), so membership comes from the people directory index
// (outbound.bal) and points from `recognition.standing`.

import amplify_api.auth;
import amplify_domain.recognition;

import ballerina/lang.array;
import ballerina/log;

# What a people board covers (openapi `LeaderboardPeople.scope`).
type PeopleScope "COMPANY"|"BU"|"TEAM";

# What a group board ranks (openapi `LeaderboardGroups.by`).
type GroupBy "TEAM"|"BU"|"HOUSE";

# One ranked team or business unit.
type GroupRow record {|
    # Opaque key: the team key, or the BU or house name
    string key;
    # Display name
    string name;
    # BU a team sits in, `()` for a BU or house row or when unknown
    string? businessUnit;
    # Sum of its members' points
    int points;
    # Members with points
    int participants;
    # Employees in the group
    int headcount;
|};

# `GET /headcount`: the employee count, cached for `headcountCacheSeconds`.
#
# + correlationId - Correlation id
# + return - The count, or problem details
isolated function headcountView(string? correlationId) returns json|ProblemResponse {
    HeadcountSnapshot|error snapshot = headcountSnapshot(correlationId);
    if snapshot is error {
        log:printWarn("Employee count unavailable", reason = snapshot.message(), correlationId = correlationId);
        return unavailable(DEPENDENCY_UNAVAILABLE, correlationId, "The people directory is unavailable");
    }
    return {
        asOf: snapshot.asOf,
        cacheSeconds: <int>headcountCacheSeconds,
        total: snapshot.total,
        businessUnits: from BusinessUnitCount b in snapshot.businessUnits select {name: b.name, headcount: b.headcount},
        teams: from TeamCount t in snapshot.teams
            select {key: t.key, name: t.name, businessUnit: t.businessUnit, headcount: t.headcount}
    };
}

# Columns the group boards sort by (openapi `sort`).
final readonly & string[] GROUP_SORTS = ["rank", "name", "points", "participants", "headcount", "participation"];

# A group with its points-based rank.
type RankedGroup record {|
    # The group
    GroupRow row;
    # Dense rank by points, ties share a rank
    int rank;
|};

isolated function participationOf(GroupRow r) returns decimal =>
    r.headcount > 0 ? <decimal>r.participants / <decimal>r.headcount : 0d;

# Ranks groups by points (dense rank, ties by name), then orders them by the asked column. The rank
# stays the points rank, so sorting only reorders rows; ties in the sort column keep the points order.
#
# + rows - Unranked groups
# + sortBy - One of `GROUP_SORTS`
# + dir - `asc` or `desc`
# + return - The rows as ranked JSON entries, in the asked order
isolated function rankGroups(GroupRow[] rows, string sortBy = "rank", string dir = "asc") returns json[] {
    GroupRow[] byPoints = from GroupRow r in rows
        order by r.points descending, r.name ascending, r.key ascending
        select r;
    RankedGroup[] ranked = [];
    int rank = 0;
    int? previous = ();
    foreach GroupRow r in byPoints {
        if previous is () || r.points != previous {
            rank += 1;
            previous = r.points;
        }
        ranked.push({row: r, rank});
    }
    array:SortDirection direction = dir == "desc" ? array:DESCENDING : array:ASCENDING;
    RankedGroup[] ordered = ranked;
    match sortBy {
        "name" => {
            ordered = ranked.sort(direction, g => g.row.name.toLowerAscii());
        }
        "points" => {
            ordered = ranked.sort(direction, g => g.row.points);
        }
        "participants" => {
            ordered = ranked.sort(direction, g => g.row.participants);
        }
        "headcount" => {
            ordered = ranked.sort(direction, g => g.row.headcount);
        }
        "participation" => {
            ordered = ranked.sort(direction, g => participationOf(g.row));
        }
        _ => {
            ordered = ranked.sort(direction, g => g.rank);
        }
    }
    return from RankedGroup g in ordered
        select {
            rank: g.rank,
            key: g.row.key,
            name: g.row.name,
            businessUnit: g.row.businessUnit,
            points: g.row.points,
            participants: g.row.participants,
            headcount: g.row.headcount,
            participationRate: (participationOf(g.row)).round(3)
        };
}

# Teams (or BUs) with their points, from the directory index and the standings. Pure, so it is testable
# without a database.
#
# + index - Directory index
# + snapshot - Employee count (the denominators)
# + points - Everyone's points
# + groupBy - `TEAM`, `BU` or `HOUSE`
# + bu - Only the teams in this BU (`TEAM` only), or `()`
# + return - The unranked rows and the points of people the directory doesn't place
isolated function groupRows(DirectoryIndex index, HeadcountSnapshot snapshot, recognition:EmailPoints[] points,
        GroupBy groupBy, string? bu) returns [GroupRow[], int, int] {
    map<GroupRow> rows = {};
    if groupBy == "BU" {
        foreach BusinessUnitCount b in snapshot.businessUnits {
            rows[b.name] = {key: b.name, name: b.name, businessUnit: (), points: 0, participants: 0,
                headcount: b.headcount};
        }
    } else if groupBy == "HOUSE" {
        foreach HouseCount h in snapshot.houses {
            rows[h.name] = {key: h.name, name: h.name, businessUnit: (), points: 0, participants: 0,
                headcount: h.headcount};
        }
    } else {
        foreach TeamCount t in snapshot.teams {
            if bu is string && t.businessUnit != bu {
                continue;
            }
            rows[t.key] = {key: t.key, name: t.name, businessUnit: t.businessUnit, points: 0, participants: 0,
                headcount: t.headcount};
        }
    }
    int unassignedPeople = 0;
    int unassignedPoints = 0;
    foreach recognition:EmailPoints e in points {
        string? key = groupBy == "BU" ? index.buOf[e.email]
            : groupBy == "HOUSE" ? index.houseOf[e.email] : index.teamOf[e.email];
        if key is () {
            unassignedPeople += 1;
            unassignedPoints += e.totalPoints;
            continue;
        }
        GroupRow? row = rows[key];
        if row is () {
            // A team outside the `bu` filter: not part of this board, not "unassigned" either.
            continue;
        }
        row.points += e.totalPoints;
        row.participants += 1;
    }
    return [rows.toArray(), unassignedPeople, unassignedPoints];
}

# `GET /leaderboard/groups`: all teams (optionally one BU's), all BUs, or all houses, ranked against each other.
#
# + correlationId - Correlation id
# + period - `ALL`, `YYYY-MM` or `YYYY-Qn`
# + groupBy - `TEAM`, `BU` or `HOUSE`
# + bu - Limit `TEAM` to one business unit
# + sortBy - Column to order by
# + dir - `asc` or `desc`
# + return - The board, or problem details
isolated function groupBoard(string? correlationId, string period, string groupBy, string? bu, string sortBy = "rank",
        string dir = "asc") returns json|ProblemResponse {
    do {
        check checkPeriod(period);
        check maxLen(bu, 100, "bu");
        if groupBy != "TEAM" && groupBy != "BU" && groupBy != "HOUSE" {
            return badRequest("by must be TEAM, BU or HOUSE", correlationId);
        }
        if GROUP_SORTS.indexOf(sortBy) is () {
            return badRequest("sort must be rank, name, points, participants, headcount or participation", correlationId);
        }
        if dir != "asc" && dir != "desc" {
            return badRequest("dir must be asc or desc", correlationId);
        }
        if groupBy != "TEAM" && bu is string {
            return badRequest("bu only narrows by=TEAM", correlationId);
        }
        DirectoryIndex|error index = directoryIndex(correlationId);
        HeadcountSnapshot|error snapshot = headcountSnapshot(correlationId);
        if index is error || snapshot is error {
            log:printWarn("Group board unavailable: people directory", correlationId = correlationId);
            return unavailable(DEPENDENCY_UNAVAILABLE, correlationId, "The people directory is unavailable");
        }
        string? buFilter = bu is string && bu.trim().length() > 0 ? bu.trim() : ();
        if buFilter is string && index.buMembers[buFilter] is () {
            return notFound("Unknown business unit", correlationId);
        }
        recognition:EmailPoints[] points = check pointsByEmailOf(period);
        var [rows, unassignedPeople, unassignedPoints] = groupRows(index, snapshot, points, <GroupBy>groupBy, buFilter);
        int headcount = 0;
        int participants = 0;
        int total = 0;
        foreach GroupRow r in rows {
            headcount += r.headcount;
            participants += r.participants;
            total += r.points;
        }
        return {
            period,
            "by": groupBy,
            businessUnit: buFilter,
            asOf: snapshot.asOf,
            totals: {headcount, participants, points: total},
            entries: rankGroups(rows, sortBy, dir),
            unassigned: {participants: unassignedPeople, points: unassignedPoints}
        };
    } on fail error e {
        return failure(e, correlationId, "Group leaderboard");
    }
}

# `GET /leaderboard/people`: people ranked within the company, a BU or a team.
#
# + p - Caller (the default BU and team come from their directory row)
# + correlationId - Correlation id
# + period - Period
# + scope - `COMPANY`, `BU` or `TEAM`
# + bu - BU name (`BU` scope), default the caller's own
# + team - Team key (`TEAM` scope), default the caller's own
# + q - Name search
# + page - Zero-based page
# + size - Page size
# + return - The page, or problem details
isolated function peopleBoard(auth:Principal p, string? correlationId, string period, string scope, string? bu,
        string? team, string? q, int page, int size) returns json|ProblemResponse {
    do {
        check checkPeriod(period);
        check maxLen(q, 100, "q");
        check maxLen(bu, 100, "bu");
        check maxLen(team, 200, "team");
        if scope != "COMPANY" && scope != "BU" && scope != "TEAM" {
            return badRequest("scope must be COMPANY, BU or TEAM", correlationId);
        }
        if page < 0 || page > 10000 || size < 1 || size > 100 {
            return badRequest("page must be 0-10000 and size 1-100", correlationId);
        }
        string[]? emails = ();
        string? buName = ();
        string? teamKey = ();
        string? teamName = ();
        int? headcount = ();
        if scope != "COMPANY" {
            DirectoryIndex|error index = directoryIndex(correlationId);
            HeadcountSnapshot|error snapshot = headcountSnapshot(correlationId);
            if index is error || snapshot is error {
                log:printWarn("People board unavailable: people directory", correlationId = correlationId);
                return unavailable(DEPENDENCY_UNAVAILABLE, correlationId, "The people directory is unavailable");
            }
            string me = p.email.trim().toLowerAscii();
            if scope == "BU" {
                buName = bu is string && bu.trim().length() > 0 ? bu.trim() : index.buOf[me];
                if buName is () {
                    return notFound("You are not in a business unit; pass bu", correlationId);
                }
                string[]? members = index.buMembers[buName];
                if members is () {
                    return notFound("Unknown business unit", correlationId);
                }
                emails = [...members];
                foreach BusinessUnitCount b in snapshot.businessUnits {
                    if b.name == buName {
                        headcount = b.headcount;
                    }
                }
            } else {
                teamKey = team is string && team.trim().length() > 0 ? team.trim() : index.teamOf[me];
                if teamKey is () {
                    return notFound("You are not in a team; pass team", correlationId);
                }
                string[]? members = index.members[teamKey];
                if members is () {
                    return notFound("Unknown team", correlationId);
                }
                emails = [...members];
                teamName = index.teamNames[teamKey];
                buName = index.teamBu[teamKey];
                foreach TeamCount t in snapshot.teams {
                    if t.key == teamKey {
                        headcount = t.headcount;
                    }
                }
            }
        } else {
            HeadcountSnapshot|error snapshot = headcountSnapshot(correlationId);
            headcount = snapshot is HeadcountSnapshot ? snapshot.total : ();
        }
        string? search = q is string && q.trim().length() > 0 ? q.trim() : ();
        recognition:TeamPage result = check teamPageOf(period, emails, search, recognition:SORT_RANK, page, size);
        return {
            period,
            scope,
            businessUnit: buName,
            team: teamKey,
            teamName,
            page,
            size,
            total: result.total,
            summary: {headcount, participants: result.total},
            entries: from recognition:TeamEntry e in result.items
                select {
                    employeeId: e.standing.employeeId,
                    displayName: e.standing.displayName,
                    email: e.standing.email,
                    points: e.standing.totalPoints,
                    rank: e.standing.rank,
                    scopeRank: e.teamRank,
                    previousRank: e.standing.previousRank,
                    lastActivityAt: tsOpt(e.standing.lastActivityAt)
                }
        };
    } on fail error e {
        return failure(e, correlationId, "People leaderboard");
    }
}
