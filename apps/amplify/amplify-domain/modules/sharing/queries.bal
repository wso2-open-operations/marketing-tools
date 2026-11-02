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


// Read side of C1 for the published API (M5): the employee's own shares and the PO share-health tile.
// Reads the `sharing` views, and `messaging.outbox` for when the current request was actually queued.
// Commentary is never read here.

import amplify_common.types;

import ballerina/time;
import ballerinax/postgresql;

# One share as the employee sees it (`GET /me/shares`).
public type ShareView record {|
    # Share request id
    string id;
    # Campaign
    string campaignId;
    # Share kind
    types:ShareKind kind;
    # Derived status
    ShareStatus status;
    # Why it failed, if it did
    types:FailureReason? failureReason;
    # Request rounds
    int attempts;
    # First request
    time:Utc requestedAt;
    # Published fact
    time:Utc? publishedAt;
    # Failed fact
    time:Utc? failedAt;
|};

# PO dashboard tile 7.
public type ShareHealth record {|
    # Still queued, with its current request made in the window (a retry counts at the retry time)
    int queued;
    # Published in the window
    int published;
    # Failed in the window
    int failed;
    # Failed in the window, by reason
    map<int> failedByReason;
|};

type ShareViewRow record {|
    string id;
    string campaign_id;
    string kind;
    string status;
    string? failure_reason;
    int attempts;
    time:Utc requested_at;
    time:Utc? published_at;
    time:Utc? failed_at;
|};

# The employee's shares, newest first (at most `limit`).
#
# + db - Client
# + employeeId - Signed-in employee
# + 'limit - Most rows
# + return - Shares, or an error
public isolated function sharesOf(postgresql:Client db, types:EmployeeId employeeId, int 'limit = 100)
        returns ShareView[]|error {
    stream<ShareViewRow, error?> rows = db->query(`
        SELECT id::text AS id, campaign_id::text AS campaign_id, kind, status, failure_reason, attempts, requested_at,
               published_at, failed_at
        FROM sharing.share_request_v WHERE employee_id = ${employeeId}
        ORDER BY requested_at DESC LIMIT ${'limit}`);
    return from ShareViewRow r in rows
        select {
            id: r.id,
            campaignId: r.campaign_id,
            kind: check r.kind.ensureType(),
            status: check r.status.ensureType(),
            failureReason: check r.failure_reason.ensureType(),
            attempts: r.attempts,
            requestedAt: r.requested_at,
            publishedAt: r.published_at,
            failedAt: r.failed_at
        };
}

# Share health since `since` (tile 7): every failure reason is present, 0 when none.
#
# `requested_at` is the first request and a retry (ADR-015) reuses the row without moving it, so "queued in
# the window" counts the current attempt instead: its `RepostRequested:<id>:<attempts>` outbox row, which a
# retry writes again with the retry time.
#
# + db - Client
# + since - Window start
# + return - Counts, or an error
public isolated function shareHealth(postgresql:Client db, time:Utc since) returns ShareHealth|error {
    string sinceText = time:utcToString(since);
    record {|int queued; int published; int failed;|} totals = check db->queryRow(`
        SELECT count(*) FILTER (WHERE sr.status = 'QUEUED' AND EXISTS (
                   SELECT 1 FROM messaging.outbox o
                   WHERE o.idempotency_key = 'RepostRequested:' || sr.id::text || ':' || sr.attempts::text
                     AND o.created_at >= CAST(${sinceText} AS timestamptz)))::int AS queued,
               count(*) FILTER (WHERE sr.published_at >= CAST(${sinceText} AS timestamptz))::int AS published,
               count(*) FILTER (WHERE sr.failed_at >= CAST(${sinceText} AS timestamptz))::int AS failed
        FROM sharing.share_request_v sr`);
    map<int> failedByReason = {NEEDS_RECONNECT: 0, PROVIDER_REJECTED: 0, RETRIES_EXHAUSTED: 0};
    stream<record {|string reason; int n;|}, error?> rows = db->query(`
        SELECT failure_reason AS reason, count(*)::int AS n FROM sharing.share_request_v
        WHERE failed_at >= CAST(${sinceText} AS timestamptz) GROUP BY failure_reason`);
    check from var r in rows
        do {
            failedByReason[r.reason] = r.n;
        };
    return {queued: totals.queued, published: totals.published, failed: totals.failed, failedByReason};
}
