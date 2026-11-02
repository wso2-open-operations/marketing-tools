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


// More S4 reads for the published API (M5): My Team, the Team page, monthly history and the PO dashboard
// tiles 4 (totals), 5 (participation) and 6 (campaign numbers). Reads only the `recognition` schema.
// The roster (team emails) always comes from the server side (leaderboards.md), never from the caller.

import amplify_common.types;
import amplify_domain.store;

import ballerina/lang.regexp;
import ballerina/sql;
import ballerina/time;
import ballerinax/postgresql;

# Team page sort orders.
public enum TeamSort {
    SORT_RANK = "rank",
    SORT_POINTS = "points",
    SORT_NAME = "name"
}

# One My Team / Team page row.
public type TeamEntry record {|
    # Standing row
    Standing standing;
    # Rank within the roster (dense); equals the company rank on the company-wide page
    int teamRank;
|};

# One page of the Team page.
public type TeamPage record {|
    # Rows
    TeamEntry[] items;
    # Matching rows across all pages
    int total;
|};

# Points in one month.
public type MonthPoints record {|
    # `YYYY-MM`
    string month;
    # Signed points
    int points;
    # Ledger rows
    int actions;
|};

# Participation numbers for a campaign (tile 6).
public type CampaignNumbers record {|
    # Campaign
    string campaignId;
    # Distinct reposters
    int reposters;
    # Approved external shares
    int externalSharesApproved;
    # Points earned on it
    int points;
|};

# Company-wide totals for the PO dashboard.
public type RecognitionTotals record {|
    # Points in the month (`employee_points_monthly`)
    int monthTotal;
    # Points all time (`standing`, `ALL`)
    int allTimeTotal;
    # Employees with a standing row
    int employeesWithPoints;
    # Employees active in the last 30 days
    int activeLast30Days;
|};

type TeamRow record {|
    string period_key;
    string employee_id;
    string display_name;
    string? email;
    int total_points;
    int? rank;
    int? previous_rank;
    int points_to_next_rank;
    int points_to_top_n;
    time:Utc? last_activity_at;
    int team_rank;
    int total;
|};

# The roster's standings, ranked within the roster (My Team).
#
# + db - Client
# + periodKey - Period
# + teamEmails - Roster emails (server side)
# + return - Rows, best first, or an error
public isolated function teamStandingsOf(postgresql:Client db, string periodKey, string[] teamEmails)
        returns TeamEntry[]|error {
    TeamPage page = check teamPage(db, periodKey, teamEmails, (), SORT_RANK, 0, 10000);
    return page.items;
}

# The Team page: paged, searchable. `teamEmails = ()` is the company-wide (PO) view.
#
# + db - Client
# + periodKey - Period
# + teamEmails - Roster emails, or `()` for everyone
# + q - Name search (trigram or prefix), or `()`
# + sort - Order
# + page - Zero-based page
# + size - Page size
# + return - The page, or an error
public isolated function teamPage(postgresql:Client db, string periodKey, string[]? teamEmails, string? q,
        TeamSort sort, int page, int size) returns TeamPage|error {
    [int, int] ['limit, offset] = store:pageWindow(page, size);
    // Phase 1 lists only people with points (leaderboards.md): a row reversed back to 0 drops off the board
    // instead of holding a rank slot. `recognitionTotals` counts the same way for `employeesWithPoints`.
    sql:ParameterizedQuery cond = `WHERE s.period_key = ${periodKey} AND s.total_points > 0`;
    if teamEmails is string[] {
        string emails = store:arrayLiteral(teamEmails.map(e => e.toLowerAscii()));
        cond = sql:queryConcat(cond, ` AND s.email = ANY (CAST(${emails} AS citext[]))`);
    }
    if q is string {
        string prefix = re `[%_\\]`.replaceAll(q, isolated function(regexp:Groups g) returns string => "\\" + g[0].substring()) + "%";
        cond = sql:queryConcat(cond, ` AND (s.display_name % ${q} OR s.display_name ILIKE ${prefix})`);
    }
    // Unfiltered (the whole company, PO view): the team rank IS the stored company rank (same
    // dense_rank over the same rows), so skip both window functions and page straight off
    // `standing_rank_idx`. M11 load test: /team p95 ~100 ms -> see docs/testing/load-test-2026-10.md.
    boolean whole = teamEmails is () && q is ();
    sql:ParameterizedQuery orderBy = sort == SORT_NAME ? ` ORDER BY s.display_name, s.employee_id`
        : sort == SORT_POINTS ? ` ORDER BY s.total_points DESC, s.display_name, s.employee_id`
            : whole ? ` ORDER BY s.rank NULLS LAST, s.display_name, s.employee_id`
                : ` ORDER BY team_rank, s.display_name, s.employee_id`;
    sql:ParameterizedQuery ranking = whole
        ? `COALESCE(s.rank, 0) AS team_rank,
               (SELECT count(*) FROM recognition.standing c
                WHERE c.period_key = ${periodKey} AND c.total_points > 0)::int AS total`
        : `(dense_rank() OVER (ORDER BY s.total_points DESC))::int AS team_rank,
               (count(*) OVER ())::int AS total`;
    stream<TeamRow, error?> rows = db->query(sql:queryConcat(`
        SELECT s.period_key, s.employee_id, s.display_name, s.email::text AS email, s.total_points, s.rank,
               s.previous_rank, s.points_to_next_rank, s.points_to_top_n, s.last_activity_at, `, ranking, `
        FROM recognition.standing s `, cond, orderBy, ` LIMIT ${'limit} OFFSET ${offset}`));
    int total = 0;
    TeamEntry[] items = [];
    check from TeamRow r in rows
        do {
            total = r.total;
            items.push({
                standing: toStanding({
                    period_key: r.period_key, employee_id: r.employee_id, display_name: r.display_name,
                    email: r.email, total_points: r.total_points, rank: r.rank, previous_rank: r.previous_rank,
                    points_to_next_rank: r.points_to_next_rank, points_to_top_n: r.points_to_top_n,
                    last_activity_at: r.last_activity_at
                }),
                teamRank: r.team_rank
            });
        };
    if items.length() == 0 && offset > 0 {
        // Past the last page the window count is gone with the rows; the total still holds.
        total = check db->queryRow(sql:queryConcat(`SELECT count(*)::int FROM recognition.standing s `, cond));
    }
    return {items, total};
}

# One person on a roster from the people directory.
public type RosterMember record {|
    # Work email, any case
    string email;
    # Display name from the directory; empty falls back to the standing's name, then the email
    string name = "";
|};

# One row of the roster page: a directory person with or without a standing row.
public type RosterEntry record {|
    # Employee id, `()` when the person has no standing row (nobody has recorded points for them)
    types:EmployeeId? employeeId;
    # Display name: the directory's, else the standing's, else the email
    string displayName;
    # Email, lowercase
    string email;
    # Points in the period; 0 without a standing row
    int totalPoints;
    # Company rank, `()` without a standing row (a zero-point person has no company rank)
    int? rank;
    # Rank before the last re-rank
    int? previousRank;
    # Last ledger row time
    time:Utc? lastActivityAt;
    # Rank within the roster (dense); every zero-point person shares the last rank
    int teamRank;
|};

# One page of the roster list.
public type RosterPage record {|
    # Rows
    RosterEntry[] items;
    # Roster people matching the search, across all pages
    int total;
    # Roster people with points in the period (before the search)
    int activeCount;
|};

type RosterRow record {|
    string? employee_id;
    string display_name;
    string email;
    int total_points;
    int? rank;
    int? previous_rank;
    time:Utc? last_activity_at;
    int team_rank;
    int total;
    int active;
|};

# Splits a roster into two parallel columns for `unnest`: lowercase emails and trimmed names. Blank and
# repeated emails are dropped (the first name wins).
#
# + members - Roster
# + return - `[emails, names]`, same length and order
isolated function rosterColumns(RosterMember[] members) returns [string[], string[]] {
    map<boolean> seen = {};
    string[] emails = [];
    string[] names = [];
    foreach RosterMember m in members {
        string email = m.email.trim().toLowerAscii();
        if email == "" || seen.hasKey(email) {
            continue;
        }
        seen[email] = true;
        emails.push(email);
        names.push(m.name.trim());
    }
    return [emails, names];
}

# The full roster, from the people directory, joined to the standings: members nobody has recorded
# points for appear with 0 points and no employee id, whether or not they ever signed in. Ties order by
# name, then email, so the order is stable. A person has one standing row per period (the lateral picks the
# best one if a legacy duplicate email ever exists, so the roster never lists anyone twice). Used for My Team, the Team page and the company view.
#
# + db - Client
# + periodKey - Period
# + members - Roster from the directory (server side, never from the caller); duplicate emails are dropped
# + q - Name search (trigram or prefix), or `()`
# + sort - Order
# + page - Zero-based page
# + size - Page size
# + return - The page, or an error
public isolated function rosterPage(postgresql:Client db, string periodKey, RosterMember[] members, string? q,
        TeamSort sort, int page, int size) returns RosterPage|error {
    [int, int] ['limit, offset] = store:pageWindow(page, size);
    var [emails, names] = rosterColumns(members);
    string emailArray = store:arrayLiteral(emails);
    string nameArray = store:arrayLiteral(names);
    sql:ParameterizedQuery search = ``;
    if q is string {
        string prefix = re `[%_\\]`.replaceAll(q, isolated function(regexp:Groups g) returns string => "\\" + g[0].substring()) + "%";
        search = ` WHERE (display_name % ${q} OR display_name ILIKE ${prefix})`;
    }
    sql:ParameterizedQuery orderBy = sort == SORT_NAME ? ` ORDER BY display_name, email`
        : sort == SORT_POINTS ? ` ORDER BY total_points DESC, display_name, email`
            : ` ORDER BY team_rank, display_name, email`;
    // Ranks and the active count run over the whole roster, before the search filters it.
    stream<RosterRow, error?> rows = db->query(sql:queryConcat(`
        WITH joined AS (
            SELECT s.employee_id::text AS employee_id,
                   COALESCE(NULLIF(m.name, ''), s.display_name, m.email::text) AS display_name,
                   m.email::text AS email, COALESCE(s.total_points, 0) AS total_points, s.rank AS rank,
                   s.previous_rank AS previous_rank, s.last_activity_at AS last_activity_at
            FROM unnest(CAST(${emailArray} AS citext[]), CAST(${nameArray} AS text[])) AS m(email, name)
            LEFT JOIN LATERAL (SELECT * FROM recognition.standing x WHERE x.email = m.email AND x.period_key = ${periodKey}
                               ORDER BY x.total_points DESC, x.employee_id LIMIT 1) s ON true
        ), ranked AS (
            SELECT j.*, (dense_rank() OVER (ORDER BY j.total_points DESC))::int AS team_rank,
                   (count(*) FILTER (WHERE j.total_points > 0) OVER ())::int AS active
            FROM joined j
        )
        SELECT employee_id, display_name, email, total_points, rank, previous_rank, last_activity_at, team_rank, active,
               (count(*) OVER ())::int AS total
        FROM ranked`, search, orderBy, ` LIMIT ${'limit} OFFSET ${offset}`));
    int total = 0;
    int active = 0;
    RosterEntry[] items = [];
    check from RosterRow r in rows
        do {
            total = r.total;
            active = r.active;
            items.push({
                employeeId: r.employee_id,
                displayName: r.display_name,
                email: r.email,
                totalPoints: r.total_points,
                rank: r.rank,
                previousRank: r.previous_rank,
                lastActivityAt: r.last_activity_at,
                teamRank: r.team_rank
            });
        };
    if items.length() == 0 {
        // Past the last page, or nothing matched: the window counts are gone with the rows.
        sql:ParameterizedQuery matching = search;
        total = check db->queryRow(sql:queryConcat(`
            WITH joined AS (
                SELECT COALESCE(NULLIF(m.name, ''), s.display_name, m.email::text) AS display_name
                FROM unnest(CAST(${emailArray} AS citext[]), CAST(${nameArray} AS text[])) AS m(email, name)
                LEFT JOIN LATERAL (SELECT * FROM recognition.standing x WHERE x.email = m.email AND x.period_key = ${periodKey}
                                   ORDER BY x.total_points DESC, x.employee_id LIMIT 1) s ON true
            )
            SELECT count(*)::int FROM joined`, matching));
        active = check db->queryRow(`
            SELECT count(*)::int
            FROM unnest(CAST(${emailArray} AS citext[])) AS m(email)
            JOIN recognition.standing s ON s.email = m.email AND s.period_key = ${periodKey} AND s.total_points > 0`);
    }
    return {items, total, activeCount: active};
}

# Whether an email belongs to the roster's standings (used for history visibility).
#
# + db - Client
# + employeeId - Employee
# + return - The employee's email in `standing`, `()` if none, or an error
public isolated function emailOf(postgresql:Client db, string employeeId) returns string|error? {
    string?|error email = db->queryRow(`
        SELECT email::text FROM recognition.standing WHERE period_key = ${PERIOD_ALL} AND employee_id = ${employeeId}`);
    if email is error {
        return store:isNoRows(email) ? () : email;
    }
    return email;
}

# An employee's points per month, newest first (at most `months`).
#
# + db - Client
# + employeeId - Employee
# + months - Most months
# + return - Months, or an error
public isolated function monthlyPointsOf(postgresql:Client db, string employeeId, int months = 12)
        returns MonthPoints[]|error {
    stream<record {|string month; int points; int actions_count;|}, error?> rows = db->query(`
        SELECT to_char(month, 'YYYY-MM') AS month, points, actions_count
        FROM recognition.employee_points_monthly WHERE employee_id = ${employeeId}
        ORDER BY month DESC LIMIT ${months}`);
    return from var r in rows
        select {month: r.month, points: r.points, actions: r.actions_count};
}

# Company totals (tiles 4 and 5).
#
# + db - Client
# + month - Month start (`YYYY-MM-01`)
# + now - Current time
# + return - Totals, or an error
public isolated function recognitionTotals(postgresql:Client db, string month, time:Utc now) returns RecognitionTotals|error {
    string since = time:utcToString(time:utcAddSeconds(now, -30d * 86400d));
    int monthTotal = check db->queryRow(`
        SELECT COALESCE(sum(points), 0)::int FROM recognition.employee_points_monthly WHERE month = CAST(${month} AS date)`);
    record {|int all_time; int with_points; int active;|} row = check db->queryRow(`
        SELECT COALESCE(sum(total_points), 0)::int AS all_time,
               count(*) FILTER (WHERE total_points > 0)::int AS with_points,
               count(*) FILTER (WHERE last_activity_at >= CAST(${since} AS timestamptz))::int AS active
        FROM recognition.standing WHERE period_key = ${PERIOD_ALL}`);
    return {monthTotal, allTimeTotal: row.all_time, employeesWithPoints: row.with_points, activeLast30Days: row.active};
}

# Participation numbers for campaigns (tile 6). Campaigns without a row are left out.
#
# + db - Client
# + campaignIds - Campaigns
# + return - Numbers by campaign id, or an error
public isolated function campaignNumbers(postgresql:Client db, string[] campaignIds) returns map<CampaignNumbers>|error {
    string ids = store:arrayLiteral(campaignIds);
    stream<record {|string campaign_id; int reposters; int external_shares_approved; int points;|}, error?> rows =
        db->query(`
            SELECT campaign_id::text AS campaign_id, reposters, external_shares_approved, points
            FROM recognition.campaign_participation WHERE campaign_id = ANY (CAST(${ids} AS uuid[]))`);
    map<CampaignNumbers> result = {};
    check from var r in rows
        do {
            result[r.campaign_id] = {campaignId: r.campaign_id, reposters: r.reposters,
                externalSharesApproved: r.external_shares_approved, points: r.points};
        };
    return result;
}

# Start of the calendar month (the 1st, 00:00 UTC) that holds `t`.
#
# + t - Any instant
# + return - The 1st 00:00:00 UTC of that month
public isolated function monthStartOf(time:Utc t) returns time:Utc {
    time:Civil c = time:utcToCivil(t);
    return checkpanic time:utcFromCivil({year: c.year, month: c.month, day: 1, hour: 0, minute: 0, second: 0,
        utcOffset: {hours: 0, minutes: 0}});
}

# Start of the month after the one holding `t`.
#
# + t - Any instant
# + return - The 1st 00:00:00 UTC of the next month
public isolated function nextMonthStartOf(time:Utc t) returns time:Utc {
    time:Civil c = time:utcToCivil(t);
    return checkpanic time:utcFromCivil({year: c.month == 12 ? c.year + 1 : c.year, month: c.month == 12 ? 1 : c.month + 1,
        day: 1, hour: 0, minute: 0, second: 0, utcOffset: {hours: 0, minutes: 0}});
}

# Points earned per employee in `[monthStart, next month's 1st)`, straight from the ledger (adjustments
# and reversals included, so it matches the all-time board's arithmetic). People whose month nets to zero
# or less are left out. Names and emails come from the identity context, as the full rebuild does.
#
# + db - Client
# + monthStart - The 1st, 00:00 UTC
# + return - One total per employee with points that month, or an error
public isolated function monthlyTotals(postgresql:Client db, time:Utc monthStart) returns EmployeeTotal[]|error {
    string startTs = time:utcToString(monthStart);
    string endTs = time:utcToString(nextMonthStartOf(monthStart));
    stream<record {|
        string employee_id;
        string? display_name;
        string? email;
        int total_points;
        time:Utc? last_activity_at;
    |}, error?> rows = db->query(`
        SELECT l.employee_id, e.display_name, e.email::text AS email, sum(l.points)::int AS total_points,
               max(l.created_at) AS last_activity_at
        FROM scoring.points_ledger l
        LEFT JOIN identity.employee e ON e.employee_id = l.employee_id
        WHERE l.created_at >= CAST(${startTs} AS timestamptz) AND l.created_at < CAST(${endTs} AS timestamptz)
        GROUP BY l.employee_id, e.display_name, e.email
        HAVING sum(l.points) > 0`);
    return from var r in rows
        select {
            employeeId: r.employee_id,
            displayName: r.display_name ?: r.employee_id,
            email: r.email ?: "",
            totalPoints: r.total_points,
            lastActivityAt: r.last_activity_at
        };
}
