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


// Read side of C2 for the published API (M5): an employee's ledger history and the PO dashboard tiles
// 3, 4 (split) and 8. Reads only the `scoring` schema.

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Dashboard groups for tile 4, in display order.
public final string[] & readonly DASHBOARD_ACTIONS = [types:REPOST, types:REPOST_COMMENTARY, types:SHARE,
    types:SHARE_COMMENTARY, types:OWN_POST, types:OWN_POST_AMPLIFIED, types:REACTION, types:COMMENT,
    types:CHALLENGE_ENTRY, types:CHALLENGE_WINNER, types:ADJUSTMENT, types:REVERSAL];

# One page of ledger rows.
public type LedgerPage record {|
    # Rows, newest first
    types:LedgerEntry[] items;
    # Rows across all pages
    int total;
|};

# Points and row count for one dashboard group.
public type ActionPoints record {|
    # Action, `ADJUSTMENT` or `REVERSAL`
    string action;
    # Signed points
    int points;
    # Ledger rows
    int rows;
|};

type PagedLedgerRow record {|
    *LedgerRow;
    int total;
|};

# An employee's ledger rows, newest first.
#
# + db - Client
# + employeeId - Employee
# + page - Zero-based page
# + size - Page size
# + return - The page, or an error
public isolated function historyOf(postgresql:Client db, types:EmployeeId employeeId, int page, int size)
        returns LedgerPage|error {
    [int, int] ['limit, offset] = store:pageWindow(page, size);
    stream<PagedLedgerRow, error?> rows = db->query(`
        SELECT reference, employee_id, campaign_id::text AS campaign_id, source_type, source_id::text AS source_id,
               action, points, rule_id::text AS rule_id, reverses_reference, reason, actor_id, correlation_id,
               created_at, status, status_changed_at, paid_at, coin_reference, (count(*) OVER ())::int AS total
        FROM scoring.points_ledger WHERE employee_id = ${employeeId}
        ORDER BY created_at DESC, reference LIMIT ${'limit} OFFSET ${offset}`);
    int total = 0;
    types:LedgerEntry[] items = [];
    check from PagedLedgerRow r in rows
        do {
            total = r.total;
            types:LedgerEntry? entry = check toEntry({
                reference: r.reference, employee_id: r.employee_id, campaign_id: r.campaign_id,
                source_type: r.source_type, source_id: r.source_id, action: r.action, points: r.points,
                rule_id: r.rule_id, reverses_reference: r.reverses_reference, reason: r.reason, actor_id: r.actor_id,
                correlation_id: r.correlation_id, created_at: r.created_at, status: r.status,
                status_changed_at: r.status_changed_at, paid_at: r.paid_at, coin_reference: r.coin_reference
            });
            if entry is types:LedgerEntry {
                items.push(entry);
            }
        };
    if items.length() == 0 && offset > 0 {
        // Past the last page the window count is gone with the rows; the total still holds.
        total = check db->queryRow(`SELECT count(*)::int FROM scoring.points_ledger WHERE employee_id = ${employeeId}`);
    }
    return {items, total};
}

# Points by dashboard group between `fromTime` (inclusive) and `toTime` (exclusive). Every group is
# present, 0 when none (tile 4).
#
# + db - Client
# + fromTime - Start
# + toTime - End
# + return - Groups in `DASHBOARD_ACTIONS` order, or an error
public isolated function pointsByAction(postgresql:Client db, time:Utc fromTime, time:Utc toTime)
        returns ActionPoints[]|error {
    string f = time:utcToString(fromTime);
    string t = time:utcToString(toTime);
    stream<record {|string grp; int points; int n;|}, error?> rows = db->query(`
        SELECT CASE WHEN source_type IN ('ADJUSTMENT', 'REVERSAL') THEN source_type ELSE action END AS grp,
               COALESCE(sum(points), 0)::int AS points, count(*)::int AS n
        FROM scoring.points_ledger
        WHERE created_at >= CAST(${f} AS timestamptz) AND created_at < CAST(${t} AS timestamptz)
        GROUP BY 1`);
    map<ActionPoints> byGroup = {};
    check from var r in rows
        do {
            byGroup[r.grp] = {action: r.grp, points: r.points, rows: r.n};
        };
    return from string a in DASHBOARD_ACTIONS
        select byGroup[a] ?: {action: a, points: 0, rows: 0};
}

# Ledger rows needing action (`status IS NULL`, tile 3).
#
# + db - Client
# + return - Count, or an error
public isolated function actionRequiredCount(postgresql:Client db) returns int|error {
    int n = check db->queryRow(`SELECT count(*)::int FROM scoring.points_ledger WHERE status IS NULL`);
    return n;
}

# Latest adjustments and reversals (tile 8).
#
# + db - Client
# + 'limit - Most rows
# + return - Rows, newest first, or an error
public isolated function recentCorrections(postgresql:Client db, int 'limit = 10) returns types:LedgerEntry[]|error {
    stream<LedgerRow, error?> rows = db->query(`
        SELECT reference, employee_id, campaign_id::text AS campaign_id, source_type, source_id::text AS source_id,
               action, points, rule_id::text AS rule_id, reverses_reference, reason, actor_id, correlation_id,
               created_at, status, status_changed_at, paid_at, coin_reference
        FROM scoring.points_ledger WHERE source_type IN ('ADJUSTMENT', 'REVERSAL')
        ORDER BY created_at DESC, reference LIMIT ${'limit}`);
    types:LedgerEntry[] entries = [];
    check from LedgerRow r in rows
        do {
            types:LedgerEntry? entry = check toEntry(r);
            if entry is types:LedgerEntry {
                entries.push(entry);
            }
        };
    return entries;
}
