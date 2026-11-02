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

// PostgreSQL reads and upkeep for the S4 read models (schema `recognition`). Writes happen inside the
// ledger insert's transaction (scoring `PgLedgerRepository.append`, B12); this file holds the reads and
// the full rebuild (`POST /maintenance/rebuild-recognition`).

import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

type StandingRow record {|
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
|};

# Company top N (B15): everyone whose dense rank is within `topN` (ties may give more than N rows).
#
# + db - Client
# + periodKey - Period, `ALL` in phase 1
# + topN - `leaderboard.top_n`
# + return - Standings, best first, or an error
public isolated function topStandings(postgresql:Client db, string periodKey = PERIOD_ALL, int topN = DEFAULT_TOP_N)
        returns Standing[]|error {
    stream<StandingRow, error?> rows = db->query(`
        SELECT period_key, employee_id, display_name, email::text AS email, total_points, rank, previous_rank,
               points_to_next_rank, points_to_top_n, last_activity_at
        FROM recognition.standing
        WHERE period_key = ${periodKey} AND rank <= ${topN} AND total_points > 0
        ORDER BY rank, display_name, employee_id`);
    return from StandingRow r in rows
        select toStanding(r);
}

# One employee's standing (personal view).
#
# + db - Client
# + employeeId - Employee
# + periodKey - Period
# + return - The standing, `()` if the employee has no points yet, or an error
public isolated function standingOf(postgresql:Client db, string employeeId, string periodKey = PERIOD_ALL)
        returns Standing|error? {
    StandingRow|error row = db->queryRow(`
        SELECT period_key, employee_id, display_name, email::text AS email, total_points, rank, previous_rank,
               points_to_next_rank, points_to_top_n, last_activity_at
        FROM recognition.standing WHERE period_key = ${periodKey} AND employee_id = ${employeeId}`);
    if row is error {
        return store:isNoRows(row) ? () : row;
    }
    return toStanding(row);
}

# Every standing's email and points for a period, the input to the team and business unit boards
# (the people directory maps email to team; Amplify stores no org data, ADR-009). At most one row per
# person with points, so ~830 rows.
#
# + db - Client
# + periodKey - Period
# + return - Points by email, or an error
public isolated function pointsByEmail(postgresql:Client db, string periodKey = PERIOD_ALL)
        returns EmailPoints[]|error {
    stream<record {|string email; int total_points;|}, error?> rows = db->query(`
        SELECT lower(email::text) AS email, total_points
        FROM recognition.standing WHERE period_key = ${periodKey} AND email IS NOT NULL`);
    return from var r in rows
        select {email: r.email, totalPoints: r.total_points};
}

# Version of a period's standings (the ETag source).
#
# + db - Client
# + periodKey - Period
# + return - Version, 0 before the first award, or an error
public isolated function standingVersion(postgresql:Client db, string periodKey = PERIOD_ALL) returns int|error {
    int|error version = db->queryRow(`SELECT version FROM recognition.standing_version WHERE period_key = ${periodKey}`);
    if version is error {
        return store:isNoRows(version) ? 0 : version;
    }
    return version;
}

# Recomputes every read model from the ledger (`recognition.rebuild`, amplify_jobs only).
#
# + db - Client (`amplify_jobs`)
# + topN - `leaderboard.top_n`
# + return - New standing version, or an error
public isolated function rebuild(postgresql:Client db, int topN = DEFAULT_TOP_N) returns int|error =>
    (check store:inTransactionValue(isolated function () returns int|error => rebuildTx(db, topN))).ensureType();

isolated function rebuildTx(postgresql:Client db, int topN) returns int|error {
    int version = 0;
    transaction {
        // Same lock as the ledger append (R-01): a rebuild never interleaves with a re-rank. Lock order:
        // 4242101 here first, then recognition.rebuild takes 1634561133. Inside the gate: 2 s poll cap.
        check store:lockRecognition(db);
        version = check db->queryRow(`SELECT recognition.rebuild(CAST(${topN} AS int))`);
        check commit;
    }
    return version;
}

isolated function toStanding(StandingRow r) returns Standing => {
    periodKey: r.period_key,
    employeeId: r.employee_id,
    displayName: r.display_name,
    email: r.email ?: "",
    totalPoints: r.total_points,
    rank: r.rank ?: 0,
    previousRank: r.previous_rank,
    pointsToNextRank: r.points_to_next_rank,
    pointsToTopN: r.points_to_top_n,
    lastActivityAt: r.last_activity_at
};
