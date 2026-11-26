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

import ballerina/sql;
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
               created_at, status, status_changed_at, paid_at, coin_reference, removal_reason,
               (count(*) OVER ())::int AS total
        FROM scoring_points_ledger WHERE employee_id = ${employeeId}
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
                status_changed_at: r.status_changed_at, paid_at: r.paid_at, coin_reference: r.coin_reference,
                removal_reason: r.removal_reason
            });
            if entry is types:LedgerEntry {
                items.push(entry);
            }
        };
    if items.length() == 0 && offset > 0 {
        // Past the last page the window count is gone with the rows; the total still holds.
        total = check db->queryRow(`SELECT count(*)::int FROM scoring_points_ledger WHERE employee_id = ${employeeId}`);
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
        FROM scoring_points_ledger
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
    int n = check db->queryRow(`SELECT count(*)::int FROM scoring_points_ledger WHERE status IS NULL`);
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
               created_at, status, status_changed_at, paid_at, coin_reference, removal_reason
        FROM scoring_points_ledger WHERE source_type IN ('ADJUSTMENT', 'REVERSAL')
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

# One employee's points: all time, and by settlement status.
public type PointsSummary record {|
    # Sum of every row (awards, adjustments, reversals)
    int total;
    # Sum of the rows not yet paid out (`HELD`): what the next Coin conversion counts
    int held;
    # Sum of the rows paid out as Coins (`PAID`)
    int paid;
    # Rows waiting for a PO decision (status `NULL`, "action required")
    int actionRequired;
|};

# The points summary of one employee.
#
# + db - Client
# + employeeId - Employee
# + return - The summary (zeros for someone with no rows), or an error
public isolated function pointsSummaryOf(postgresql:Client db, types:EmployeeId employeeId) returns PointsSummary|error {
    PointsSummary summary = check db->queryRow(`
        SELECT coalesce(sum(points), 0)::int AS total,
               coalesce(sum(points) FILTER (WHERE status = 'HELD'), 0)::int AS held,
               coalesce(sum(points) FILTER (WHERE status = 'PAID'), 0)::int AS paid,
               (count(*) FILTER (WHERE status IS NULL))::int AS "actionRequired"
        FROM scoring_points_ledger WHERE employee_id = ${employeeId}`);
    return summary;
}

# Which of these rows a reversal row cancels.
#
# + db - Client
# + references - Ledger references (a page of history)
# + return - Cancelled reference -> the reversal row's reference, or an error
public isolated function reversalsOf(postgresql:Client db, types:LedgerReference[] references) returns map<string>|error {
    map<string> reversals = {};
    if references.length() == 0 {
        return reversals;
    }
    stream<record {|string reverses; string reference;|}, error?> rows = db->query(sql:queryConcat(`
        SELECT reverses_reference AS reverses, reference FROM scoring_points_ledger
        WHERE reverses_reference IN (`, sql:arrayFlattenQuery(references), `)`));
    check from var r in rows
        do {
            reversals[r.reverses] = r.reference;
        };
    return reversals;
}

# One employee's Coins: what they received, the carry toward the next block and the captured wallet.
public type CoinSummary record {|
    # Coins in their SENT issues
    int coinsReceived;
    # carry_out of their last SENT issue (points that count toward the next block on top of the HELD ones)
    int carryPoints;
    # Captured wallet address (unmasked; the API masks it), `()` when none
    string? walletAddress;
    # When that wallet was captured
    time:Utc? walletCapturedAt;
|};

# The Coins summary of one employee.
#
# + db - Client
# + employeeId - Employee
# + return - The summary (zeros and no wallet for someone with no conversion), or an error
public isolated function coinSummaryOf(postgresql:Client db, types:EmployeeId employeeId) returns CoinSummary|error {
    CoinSummary summary = check db->queryRow(`
        SELECT coalesce((SELECT sum(coins) FROM scoring_coin_issue
                          WHERE employee_id = ${employeeId} AND status = 'SENT'), 0)::int AS "coinsReceived",
               coalesce((SELECT carry_out FROM scoring_coin_issue WHERE employee_id = ${employeeId} AND status = 'SENT'
                          ORDER BY sent_at DESC, created_at DESC LIMIT 1), 0)::int AS "carryPoints",
               (SELECT wallet_address FROM scoring_coin_wallet WHERE employee_id = ${employeeId}) AS "walletAddress",
               (SELECT captured_at FROM scoring_coin_wallet WHERE employee_id = ${employeeId}) AS "walletCapturedAt"`);
    return summary;
}

# One Coins conversion as a history row (`scoring_coin_issue`, SENT or still in progress).
public type CoinConversion record {|
    # Our `CNV-` reference (the ledger rows it paid carry it as `coin_reference`)
    string reference;
    # Employee
    types:EmployeeId employeeId;
    # Points converted: whole blocks × block points (carry in + points in − carry out)
    int points;
    # Coins
    int coins;
    # `SENT`, or `PENDING` / `UNKNOWN` while the transfer is not confirmed
    CoinIssueStatus status;
    # The Coins service's transfer reference (SENT only)
    string? transferReference;
    # When it was sent, else when the transfer was attempted
    time:Utc at;
|};

# A history row: a ledger row or a Coins conversion.
public type TimelineEntry types:LedgerEntry|CoinConversion;

# One page of an employee's history.
public type TimelinePage record {|
    # Rows, newest first
    TimelineEntry[] items;
    # Rows across all pages
    int total;
|};

type ConversionRow record {|
    string id;
    string reference;
    string employee_id;
    int points;
    int coins;
    string status;
    string? transfer_reference;
    time:Utc at;
|};

# An employee's ledger rows and Coins conversions (SENT, PENDING, UNKNOWN; not FAILED or skipped, which moved
# nothing), newest first in one paged list. A conversion is dated when it was sent (else attempted).
#
# + db - Client
# + employeeId - Employee
# + page - Zero-based page
# + size - Page size
# + return - The page, or an error
public isolated function timelineOf(postgresql:Client db, types:EmployeeId employeeId, int page, int size)
        returns TimelinePage|error {
    [int, int] ['limit, offset] = store:pageWindow(page, size);
    stream<record {|string kind; string ref; int total;|}, error?> keys = db->query(`
        WITH t AS (
            SELECT 'L' AS kind, reference AS ref, created_at AS at FROM scoring_points_ledger
             WHERE employee_id = ${employeeId}
            UNION ALL
            SELECT 'C', id::text, coalesce(sent_at, attempted_at, created_at) FROM scoring_coin_issue
             WHERE employee_id = ${employeeId} AND status IN ('SENT', 'PENDING', 'UNKNOWN'))
        SELECT kind, ref, (count(*) OVER ())::int AS total FROM t
        ORDER BY at DESC, ref LIMIT ${'limit} OFFSET ${offset}`);
    string[] keyOrder = [];
    string[] ledgerRefs = [];
    string[] issueIds = [];
    int total = 0;
    check from var k in keys
        do {
            total = k.total;
            keyOrder.push(k.kind + k.ref);
            if k.kind == "L" {
                ledgerRefs.push(k.ref);
            } else {
                issueIds.push(k.ref);
            }
        };
    if keyOrder.length() == 0 && offset > 0 {
        total = check db->queryRow(`
            SELECT ((SELECT count(*) FROM scoring_points_ledger WHERE employee_id = ${employeeId})
                  + (SELECT count(*) FROM scoring_coin_issue WHERE employee_id = ${employeeId}
                      AND status IN ('SENT', 'PENDING', 'UNKNOWN')))::int`);
    }
    map<TimelineEntry> byKey = {};
    if ledgerRefs.length() > 0 {
        stream<LedgerRow, error?> rows = db->query(sql:queryConcat(`
            SELECT reference, employee_id, campaign_id::text AS campaign_id, source_type, source_id::text AS source_id,
                   action, points, rule_id::text AS rule_id, reverses_reference, reason, actor_id, correlation_id,
                   created_at, status, status_changed_at, paid_at, coin_reference, removal_reason
            FROM scoring_points_ledger WHERE reference IN (`, sql:arrayFlattenQuery(ledgerRefs), `)`));
        check from LedgerRow r in rows
            do {
                types:LedgerEntry? e = check toEntry(r);
                if e is types:LedgerEntry {
                    byKey["L" + e.reference] = e;
                }
            };
    }
    if issueIds.length() > 0 {
        stream<ConversionRow, error?> rows = db->query(sql:queryConcat(`
            SELECT id::text AS id, reference, employee_id, ((coins / block_coins) * block_points)::int AS points, coins,
                   status, transfer_reference, coalesce(sent_at, attempted_at, created_at) AS at
            FROM scoring_coin_issue WHERE id::text IN (`, sql:arrayFlattenQuery(issueIds), `)`));
        check from ConversionRow r in rows
            do {
                byKey["C" + r.id] = {reference: r.reference, employeeId: r.employee_id, points: r.points, coins: r.coins,
                    status: check r.status.ensureType(), transferReference: r.transfer_reference, at: r.at};
            };
    }
    TimelineEntry[] items = [];
    foreach string key in keyOrder {
        TimelineEntry? e = byKey[key];
        if e !is () {
            items.push(e);
        }
    }
    return {items, total};
}
