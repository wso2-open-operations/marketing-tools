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


// Read side of S3 for the published API (M5): own claims, the PO review queue and the dashboard tiles
// 1 and 2. Reads only the `external_sharing` schema.

import amplify_common.types;
import amplify_domain.store;

import ballerina/sql;
import ballerina/time;
import ballerinax/postgresql;

# One page of claims.
public type ExternalSharePage record {|
    # Claims, oldest first for review, newest first for the claimant
    ExternalShare[] items;
    # Matching rows across all pages
    int total;
|};

# PO dashboard tile 1.
public type ReviewQueue record {|
    # Pending claims
    int pending;
    # Oldest pending claim
    time:Utc? oldestPendingAt;
    # Pending longer than the SLA
    int overSla;
|};

# PO dashboard tile 2.
public type ReviewThroughput record {|
    # Approved in the window
    int approved;
    # Rejected in the window
    int rejected;
    # Amplified in the window
    int amplified;
    # Median hours from claim to decision; `()` when nothing was decided
    decimal? medianHoursToDecision;
|};

type PagedRow record {|
    *ExternalShareRow;
    int total;
|};

# The employee's claims, newest first.
#
# + db - Client
# + employeeId - Signed-in employee
# + 'limit - Most rows
# + return - Claims, or an error
public isolated function claimsOf(postgresql:Client db, types:EmployeeId employeeId, int 'limit = 100)
        returns ExternalShare[]|error {
    stream<ExternalShareRow, error?> rows = db->query(`
        SELECT id::text AS id, employee_id, campaign_id::text AS campaign_id, action, evidence_url,
               evidence_url_submitted, evidence_host, provider, resource_urn, certified_at, decision, decided_by,
               decided_at, decision_reason, amplified_at, created_at, version
        FROM external_sharing.external_share WHERE employee_id = ${employeeId}
        ORDER BY created_at DESC, id LIMIT ${'limit}`);
    ExternalShare[] claims = [];
    check from ExternalShareRow r in rows
        do {
            ExternalShare? claim = check toClaim(r);
            if claim is ExternalShare {
                claims.push(claim);
            }
        };
    return claims;
}

# Claims for PO review by derived status, oldest first.
#
# + db - Client
# + status - Status filter; `()` = any
# + page - Zero-based page
# + size - Page size
# + return - The page, or an error
public isolated function claimsForReview(postgresql:Client db, ExternalShareStatus? status, int page, int size)
        returns ExternalSharePage|error {
    [int, int] ['limit, offset] = store:pageWindow(page, size);
    sql:ParameterizedQuery cond = status is () ? `WHERE TRUE` : `WHERE status = ${status}`;
    stream<PagedRow, error?> rows = db->query(sql:queryConcat(`
        SELECT id::text AS id, employee_id, campaign_id::text AS campaign_id, action, evidence_url,
               evidence_url_submitted, evidence_host, provider, resource_urn, certified_at, decision, decided_by,
               decided_at, decision_reason, amplified_at, created_at, version, (count(*) OVER ())::int AS total
        FROM external_sharing.external_share_v `, cond, `
        ORDER BY created_at, id LIMIT ${'limit} OFFSET ${offset}`));
    int total = 0;
    ExternalShare[] items = [];
    check from PagedRow r in rows
        do {
            total = r.total;
            ExternalShare? claim = check toClaim({
                id: r.id, employee_id: r.employee_id, campaign_id: r.campaign_id, action: r.action,
                evidence_url: r.evidence_url, evidence_url_submitted: r.evidence_url_submitted,
                evidence_host: r.evidence_host, provider: r.provider, resource_urn: r.resource_urn,
                certified_at: r.certified_at, decision: r.decision, decided_by: r.decided_by,
                decided_at: r.decided_at, decision_reason: r.decision_reason, amplified_at: r.amplified_at,
                created_at: r.created_at, version: r.version
            });
            if claim is ExternalShare {
                items.push(claim);
            }
        };
    if items.length() == 0 && offset > 0 {
        // Past the last page the window count is gone with the rows; the total still holds.
        total = check db->queryRow(sql:queryConcat(`SELECT count(*)::int FROM external_sharing.external_share_v `, cond));
    }
    return {items, total};
}

# Review queue (tile 1).
#
# + db - Client
# + slaHours - `po.review_sla_hours`
# + now - Current time
# + return - Counts, or an error
public isolated function reviewQueue(postgresql:Client db, int slaHours, time:Utc now) returns ReviewQueue|error {
    string cutoff = time:utcToString(time:utcAddSeconds(now, -3600d * <decimal>slaHours));
    record {|int pending; time:Utc? oldest; int over_sla;|} row = check db->queryRow(`
        SELECT count(*)::int AS pending, min(created_at) AS oldest,
               count(*) FILTER (WHERE created_at < CAST(${cutoff} AS timestamptz))::int AS over_sla
        FROM external_sharing.external_share WHERE decision IS NULL`);
    return {pending: row.pending, oldestPendingAt: row.oldest, overSla: row.over_sla};
}

# Review throughput since `since` (tile 2).
#
# + db - Client
# + since - Window start
# + return - Counts and median, or an error
public isolated function reviewThroughput(postgresql:Client db, time:Utc since) returns ReviewThroughput|error {
    string sinceText = time:utcToString(since);
    record {|int approved; int rejected; int amplified; decimal? median;|} row = check db->queryRow(`
        SELECT count(*) FILTER (WHERE decision = 'APPROVED' AND decided_at >= CAST(${sinceText} AS timestamptz))::int AS approved,
               count(*) FILTER (WHERE decision = 'REJECTED' AND decided_at >= CAST(${sinceText} AS timestamptz))::int AS rejected,
               count(*) FILTER (WHERE amplified_at >= CAST(${sinceText} AS timestamptz))::int AS amplified,
               (percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM decided_at - created_at) / 3600)
                   FILTER (WHERE decided_at >= CAST(${sinceText} AS timestamptz)))::numeric(10, 1) AS median
        FROM external_sharing.external_share`);
    return {approved: row.approved, rejected: row.rejected, amplified: row.amplified,
        medianHoursToDecision: row.median};
}
