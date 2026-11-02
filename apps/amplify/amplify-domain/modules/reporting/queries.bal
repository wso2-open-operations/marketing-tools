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


// The dashboard queries. Pure SQL over views and tables the API role can already read; each one is a small
// indexed aggregate at pilot volume (~830 employees, tens of campaigns).

import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Campaigns live now.
public type LiveCounts record {|
    # Open now
    int live;
    # Open now and flagged priority
    int livePriority;
    # Open now and closing within seven days
    int closingWithin7Days;
|};

# One campaign and what was recorded against it.
public type CampaignRow record {|
    # Campaign id
    string campaignId;
    # Title
    string title;
    # Category code
    string categoryCode;
    # Category label (the code when the category is gone)
    string categoryLabel;
    # Priority flag
    boolean isPriority;
    # SCHEDULED, OPEN, CLOSED or ARCHIVED
    string status;
    # Opens
    time:Utc opensAt;
    # Closes
    time:Utc closesAt;
    # Active engagements recorded against the campaign
    int reposts;
    # Of those, reposts with the employee's own commentary (`REPOST_COMMENTARY`, `SHARE_COMMENTARY`)
    int repostsWithCommentary;
|};

# Connections by derived state.
public type ConnectionBreakdown record {|
    # Working
    int active;
    # Inside the reminder window
    int expiring;
    # Token past its expiry
    int expired;
    # Needs reconnect for another reason (revoked, token missing)
    int revoked;
|};

# A campaign's announcement as the outbox sees it.
public type Delivery record {|
    # `QUEUED`, `SENT` or `FAILED` (a campaign without an announcement row is left out)
    string status;
    # Outbox attempts so far while queued
    int? attempts;
    # When the card went out
    time:Utc? sentAt;
|};

# Reposts in one calendar month.
public type MonthCount record {|
    # First day of the month, `YYYY-MM-DD` (UTC)
    string monthStart;
    # Active engagements
    int reposts;
|};

# Reposts per category.
public type CategoryCount record {|
    # Code
    string code;
    # Label
    string label;
    # Active engagements (reposts plus reposts with comments)
    int reposts;
    # Of those, with the employee's own commentary
    int repostsWithCommentary;
|};

# People at each step of the participation funnel.
public type ParticipationCounts record {|
    # Not removed, any state
    int connected;
    # Token past its expiry
    int expired;
    # At least one active engagement
    int reposted;
    # An engagement in the last 30 days
    int active30Days;
|};

# Announcements of campaigns that opened in a window.
public type CardCounts record {|
    # Campaigns that opened in the window
    int total;
    # Card sent
    int sent;
    # Not sent yet, still retrying or waiting
    int queued;
    # Gave up after the retries (admin retry needed)
    int failed;
    # Queued with at least one failed attempt
    int retrying;
|};

# Open campaigns, counted.
#
# + db - Client
# + return - Counts, or an error
public isolated function liveCounts(postgresql:Client db) returns LiveCounts|error {
    return db->queryRow(`
        SELECT count(*)::int AS live,
               count(*) FILTER (WHERE is_priority)::int AS "livePriority",
               count(*) FILTER (WHERE closes_at <= now() + interval '7 days')::int AS "closingWithin7Days"
        FROM campaign.campaign_v WHERE status = 'OPEN'`);
}

# Active engagements in a time range.
#
# + db - Client
# + from - Start, inclusive
# + to - End, exclusive
# + return - Count, or an error
public isolated function repostsBetween(postgresql:Client db, time:Utc 'from, time:Utc to) returns int|error {
    string a = time:utcToString('from);
    string b = time:utcToString(to);
    return db->queryRow(`
        SELECT count(*)::int FROM sharing.engagement_v
        WHERE status = 'ACTIVE' AND occurred_at >= CAST(${a} AS timestamptz) AND occurred_at < CAST(${b} AS timestamptz)`);
}

# Campaigns that are open or opened in the last `days`, with their repost counts (not archived).
#
# + db - Client
# + days - Look-back
# + limit - Most rows
# + now - Current time
# + return - Campaigns, priority first then newest, or an error
public isolated function campaignRows(postgresql:Client db, int days, int 'limit, time:Utc now) returns CampaignRow[]|error {
    string since = time:utcToString(time:utcAddSeconds(now, -86400d * <decimal>days));
    stream<record {|
        string id;
        string title;
        string category_code;
        string category_label;
        boolean is_priority;
        string status;
        time:Utc opens_at;
        time:Utc closes_at;
        int reposts;
        int with_commentary;
    |}, error?> rows = db->query(`
        SELECT c.id::text AS id, c.title, c.category_code, COALESCE(cat.label, c.category_code) AS category_label,
               c.is_priority, c.status, c.opens_at, c.closes_at, COALESCE(e.n, 0)::int AS reposts, COALESCE(e.c, 0)::int AS with_commentary
        FROM campaign.campaign_v c
        LEFT JOIN campaign.category cat ON cat.code = c.category_code
        LEFT JOIN (SELECT campaign_id, count(*) AS n,
                          count(*) FILTER (WHERE action IN ('REPOST_COMMENTARY', 'SHARE_COMMENTARY')) AS c
                   FROM sharing.engagement_v WHERE status = 'ACTIVE'
                   GROUP BY campaign_id) e ON e.campaign_id = c.id
        WHERE c.archived_at IS NULL AND c.status IN ('OPEN', 'CLOSED')
          AND (c.status = 'OPEN' OR c.opens_at >= CAST(${since} AS timestamptz))
        ORDER BY c.is_priority DESC, c.opens_at DESC, c.id
        LIMIT ${'limit}`);
    return from var r in rows
        select {
            campaignId: r.id,
            title: r.title,
            categoryCode: r.category_code,
            categoryLabel: r.category_label,
            isPriority: r.is_priority,
            status: r.status,
            opensAt: r.opens_at,
            closesAt: r.closes_at,
            reposts: r.reposts,
            repostsWithCommentary: r.with_commentary
        };
}

# Connections by state. `expired` is the token being past its expiry; `revoked` is every other reason the
# derived state says reconnect.
#
# + db - Client
# + return - Counts, or an error
public isolated function connectionBreakdown(postgresql:Client db) returns ConnectionBreakdown|error {
    return db->queryRow(`
        SELECT count(*) FILTER (WHERE status = 'ACTIVE')::int AS active,
               count(*) FILTER (WHERE status = 'EXPIRING')::int AS expiring,
               count(*) FILTER (WHERE status = 'NEEDS_RECONNECT' AND access_expires_at <= now())::int AS expired,
               count(*) FILTER (WHERE status = 'NEEDS_RECONNECT' AND access_expires_at > now())::int AS revoked
        FROM connection.member_connection_v WHERE status <> 'REMOVED'`);
}

# Announcement delivery by campaign: the card's state and how many times the outbox has tried.
#
# + db - Client
# + campaignIds - Campaigns
# + return - Delivery by campaign id (campaigns without an announcement row are left out), or an error
public isolated function deliveryOf(postgresql:Client db, string[] campaignIds) returns map<Delivery>|error {
    string ids = store:arrayLiteral(campaignIds);
    stream<record {|string campaign_id; string status; int? attempts; time:Utc? sent_at;|}, error?> rows = db->query(`
        SELECT a.campaign_id::text AS campaign_id, a.status, o.attempts, a.sent_at
        FROM announcement.announcement_v a
        LEFT JOIN messaging.outbox o ON o.id = a.outbox_id
        WHERE a.campaign_id = ANY (CAST(${ids} AS uuid[]))`);
    map<Delivery> result = {};
    check from var r in rows
        do {
            result[r.campaign_id] = {status: r.status, attempts: r.status == "QUEUED" ? r.attempts : (), sentAt: r.sent_at};
        };
    return result;
}

# Cards for campaigns that opened in a window: sent, still queued (and retrying), or failed for good.
#
# + db - Client
# + since - Window start
# + return - Counts, or an error
public isolated function cardCounts(postgresql:Client db, time:Utc since) returns CardCounts|error {
    string s = time:utcToString(since);
    return db->queryRow(`
        SELECT count(*)::int AS total,
               count(*) FILTER (WHERE a.status = 'SENT')::int AS sent,
               count(*) FILTER (WHERE a.status = 'FAILED')::int AS failed,
               count(*) FILTER (WHERE a.status IS DISTINCT FROM 'SENT' AND a.status IS DISTINCT FROM 'FAILED')::int AS queued,
               count(*) FILTER (WHERE a.status = 'QUEUED' AND COALESCE(o.attempts, 0) > 0)::int AS retrying
        FROM campaign.campaign_v c
        LEFT JOIN announcement.announcement_v a ON a.campaign_id = c.id
        LEFT JOIN messaging.outbox o ON o.id = a.outbox_id
        WHERE c.archived_at IS NULL AND c.opens_at <= now() AND c.opens_at >= CAST(${s} AS timestamptz)`);
}

# A campaign's reposts by day since it opened (day 1 = the first 24 hours), days 1 to `days`.
#
# + db - Client
# + campaignId - Campaign
# + days - Number of days
# + return - One count per day, zero-filled, or an error
public isolated function repostsByDay(postgresql:Client db, string campaignId, int days) returns int[]|error {
    stream<record {|int day; int n;|}, error?> rows = db->query(`
        SELECT (floor(extract(epoch FROM (e.occurred_at - c.opens_at)) / 86400)::int + 1) AS day, count(*)::int AS n
        FROM sharing.engagement_v e
        JOIN campaign.campaign c ON c.id = e.campaign_id
        WHERE e.status = 'ACTIVE' AND e.campaign_id = CAST(${campaignId} AS uuid)
        GROUP BY 1`);
    int[] counts = [];
    foreach int _ in 0 ..< days {
        counts.push(0);
    }
    check from var r in rows
        do {
            if r.day >= 1 && r.day <= days {
                counts[r.day - 1] = r.n;
            }
        };
    return counts;
}

# Reposts by category since a time.
#
# + db - Client
# + since - Start
# + return - Categories with reposts, most first, or an error
public isolated function repostsByCategory(postgresql:Client db, time:Utc since) returns CategoryCount[]|error {
    string s = time:utcToString(since);
    stream<record {|string code; string label; int n; int commented;|}, error?> rows = db->query(`
        SELECT c.category_code AS code, COALESCE(cat.label, c.category_code) AS label, count(*)::int AS n,
               count(*) FILTER (WHERE e.action IN ('REPOST_COMMENTARY', 'SHARE_COMMENTARY'))::int AS commented
        FROM sharing.engagement_v e
        JOIN campaign.campaign c ON c.id = e.campaign_id
        LEFT JOIN campaign.category cat ON cat.code = c.category_code
        WHERE e.status = 'ACTIVE' AND e.occurred_at >= CAST(${s} AS timestamptz)
        GROUP BY c.category_code, cat.label
        ORDER BY n DESC, label`);
    return from var r in rows
        select {code: r.code, label: r.label, reposts: r.n, repostsWithCommentary: r.commented};
}

# People at each step of the participation funnel.
#
# + db - Client
# + return - Counts, or an error
public isolated function participationCounts(postgresql:Client db) returns ParticipationCounts|error {
    return db->queryRow(`
        SELECT (SELECT count(*) FROM connection.member_connection_v WHERE status <> 'REMOVED')::int AS connected,
               (SELECT count(*) FROM connection.member_connection_v
                WHERE status = 'NEEDS_RECONNECT' AND access_expires_at <= now())::int AS expired,
               (SELECT count(DISTINCT employee_id) FROM sharing.engagement_v WHERE status = 'ACTIVE')::int AS reposted,
               (SELECT count(DISTINCT employee_id) FROM sharing.engagement_v
                WHERE status = 'ACTIVE' AND occurred_at >= now() - interval '30 days')::int AS "active30Days"`);
}

# Reposts per calendar month (UTC) for the last `months` months, zero-filled, oldest first.
#
# + db - Client
# + months - Number of months
# + return - One row per month, or an error
public isolated function monthlyReposts(postgresql:Client db, int months) returns MonthCount[]|error {
    stream<record {|string month_start; int n;|}, error?> rows = db->query(`
        SELECT to_char(m.month_start, 'YYYY-MM-DD') AS month_start, count(e.id)::int AS n
        FROM generate_series(date_trunc('month', now() AT TIME ZONE 'UTC') - make_interval(months => CAST(${months - 1} AS int)),
                             date_trunc('month', now() AT TIME ZONE 'UTC'), interval '1 month') AS m(month_start)
        LEFT JOIN sharing.engagement_v e
               ON e.status = 'ACTIVE'
              AND date_trunc('month', e.occurred_at AT TIME ZONE 'UTC') = m.month_start
        GROUP BY m.month_start ORDER BY m.month_start`);
    return from var r in rows
        select {monthStart: r.month_start, reposts: r.n};
}

# People with at least one active engagement.
#
# + db - Client
# + return - Count, or an error
public isolated function repostingPeople(postgresql:Client db) returns int|error {
    return db->queryRow(`SELECT count(DISTINCT employee_id)::int FROM sharing.engagement_v WHERE status = 'ACTIVE'`);
}

# Points awarded in a month (employee_points_monthly).
#
# + db - Client
# + month - `YYYY-MM-01`
# + return - Points this month, or an error
public isolated function pointsInMonth(postgresql:Client db, string month) returns int|error {
    return db->queryRow(`
        SELECT COALESCE(sum(points), 0)::int FROM recognition.employee_points_monthly
        WHERE month = CAST(${month} AS date)`);
}

# Points awarded this calendar month and year (UTC), summed from the ledger (reversals and
# adjustments included, so it matches the standings).
public type PointsAwarded record {|
    # Since the 1st, UTC
    int month;
    # Since 1 January, UTC
    int year;
|};

# Points awarded this month and year.
#
# + db - Client
# + return - Sums, or an error
public isolated function pointsAwarded(postgresql:Client db) returns PointsAwarded|error {
    return db->queryRow(`
        SELECT COALESCE(sum(points) FILTER (WHERE created_at >= date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'), 0)::int AS month,
               COALESCE(sum(points) FILTER (WHERE created_at >= date_trunc('year', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'), 0)::int AS year
        FROM scoring.points_ledger
        WHERE created_at >= date_trunc('year', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`);
}

# Active reposts with the employee's own commentary in a time range.
#
# + db - Client
# + from - Start, inclusive
# + to - End, exclusive
# + return - Count, or an error
public isolated function commentaryRepostsBetween(postgresql:Client db, time:Utc 'from, time:Utc to) returns int|error {
    string a = time:utcToString('from);
    string b = time:utcToString(to);
    return db->queryRow(`
        SELECT count(*)::int FROM sharing.engagement_v
        WHERE status = 'ACTIVE' AND action IN ('REPOST_COMMENTARY', 'SHARE_COMMENTARY')
          AND occurred_at >= CAST(${a} AS timestamptz) AND occurred_at < CAST(${b} AS timestamptz)`);
}

# A campaign's card as Marketing posted it: the text and picture the popup shows.
public type CampaignCard record {|
    # Short text under the title
    string? summary;
    # Picture
    string? imageUrl;
    # Link to the post on LinkedIn
    string? resourceUrl;
    # LinkedIn resource URN (the link is built from it when there is no URL)
    string resourceUrn;
|};

# One person who reposted a campaign.
public type Reposter record {|
    # Employee id
    string employeeId;
    # Name as Amplify recorded it (the id when it never did; the UI looks the person up in the directory)
    string displayName;
    # Work email, the key to the people directory
    string? email;
    # Whether the repost carries the employee's own comment
    boolean withCommentary;
|};

# A campaign's card.
#
# + db - Client
# + campaignId - Campaign
# + return - The card, `()` when the campaign is gone, or an error
public isolated function campaignCard(postgresql:Client db, string campaignId) returns CampaignCard?|error {
    stream<CampaignCard, error?> rows = db->query(`
        SELECT summary, image_url AS "imageUrl", resource_url AS "resourceUrl", resource_urn AS "resourceUrn"
        FROM campaign.campaign WHERE id = CAST(${campaignId} AS uuid)`);
    CampaignCard[] found = check from CampaignCard r in rows
        select r;
    return found.length() > 0 ? found[0] : ();
}

# Everyone with an active repost of a campaign, plain reposts and reposts with comments, by name.
#
# + db - Client
# + campaignId - Campaign
# + return - One row per person and action, or an error
public isolated function campaignReposters(postgresql:Client db, string campaignId) returns Reposter[]|error {
    stream<record {|string employee_id; string display_name; string? email; boolean commented;|}, error?> rows = db->query(`
        SELECT e.employee_id, COALESCE(p.display_name, st.display_name, e.employee_id) AS display_name,
               COALESCE(p.email::text, st.email::text) AS email,
               e.action IN ('REPOST_COMMENTARY', 'SHARE_COMMENTARY') AS commented
        FROM sharing.engagement_v e
        LEFT JOIN identity.employee p ON p.employee_id = e.employee_id
        LEFT JOIN recognition.standing st ON st.employee_id = e.employee_id AND st.period_key = 'ALL'
        WHERE e.status = 'ACTIVE' AND e.campaign_id = CAST(${campaignId} AS uuid)
        ORDER BY lower(COALESCE(p.display_name, st.display_name, e.employee_id)), e.employee_id
        LIMIT 2000`);
    return from var r in rows
        select {employeeId: r.employee_id, displayName: r.display_name, email: r.email, withCommentary: r.commented};
}

# One line of the raw-data export: a fact the dashboards count, in a fixed set of columns.
public type ExportRow record {|
    # `ENGAGEMENT`, `SHARE_REQUEST`, `POINTS`, `CAMPAIGN` or `CONNECTION`
    string recordType;
    # When it happened (UTC, ISO 8601)
    string occurredAt;
    # Campaign id, when the fact belongs to one
    string? campaignId;
    # Campaign title
    string? campaignTitle;
    # Campaign category label
    string? category;
    # Campaign priority flag
    boolean? isPriority;
    # Employee id
    string? employeeId;
    # Employee name
    string? employeeName;
    # Employee email
    string? employeeEmail;
    # Repost kind or points action
    string? action;
    # State of the row (ACTIVE, DELETED, PUBLISHED, FAILED, QUEUED, HELD, OPEN, SENT, ACTIVE and so on)
    string? status;
    # Points, for ledger rows
    int? points;
    # Anything else worth a column: failure reason, source type, closing time, token expiry
    string? detail;
|};

# The raw rows behind every board for a date range, oldest first: engagements, share attempts, points ledger
# rows, campaigns opened and connections made. `from` is inclusive, `to` exclusive, both UTC.
#
# + db - Client
# + from - First moment
# + to - First moment not included
# + return - Rows, or an error
public isolated function exportRows(postgresql:Client db, time:Utc 'from, time:Utc to) returns ExportRow[]|error {
    string a = time:utcToString('from);
    string b = time:utcToString(to);
    stream<ExportRow, error?> rows = db->query(`
        SELECT x."recordType", x."occurredAt", x."campaignId", x."campaignTitle", x.category, x."isPriority", x."employeeId",
               x."employeeName", x."employeeEmail", x.action, x.status, x.points, x.detail
        FROM (
            SELECT 'ENGAGEMENT' AS "recordType", to_char(e.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS "occurredAt",
                   e.campaign_id::text AS "campaignId", c.title AS "campaignTitle", COALESCE(cat.label, c.category_code) AS category,
                   c.is_priority AS "isPriority", e.employee_id AS "employeeId", p.display_name AS "employeeName",
                   p.email::text AS "employeeEmail", e.action, e.status, NULL::int AS points, NULL::text AS detail,
                   e.occurred_at AS sort_at
            FROM sharing.engagement_v e
            LEFT JOIN campaign.campaign c ON c.id = e.campaign_id
            LEFT JOIN campaign.category cat ON cat.code = c.category_code
            LEFT JOIN identity.employee p ON p.employee_id = e.employee_id
            WHERE e.occurred_at >= CAST(${a} AS timestamptz) AND e.occurred_at < CAST(${b} AS timestamptz)
          UNION ALL
            SELECT 'SHARE_REQUEST', to_char(s.requested_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   s.campaign_id::text, c.title, COALESCE(cat.label, c.category_code), c.is_priority,
                   s.employee_id, p.display_name, p.email::text, s.kind, s.status, NULL, s.failure_reason, s.requested_at
            FROM sharing.share_request_v s
            LEFT JOIN campaign.campaign c ON c.id = s.campaign_id
            LEFT JOIN campaign.category cat ON cat.code = c.category_code
            LEFT JOIN identity.employee p ON p.employee_id = s.employee_id
            WHERE s.requested_at >= CAST(${a} AS timestamptz) AND s.requested_at < CAST(${b} AS timestamptz)
          UNION ALL
            SELECT 'POINTS', to_char(l.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   l.campaign_id::text, c.title, COALESCE(cat.label, c.category_code), c.is_priority,
                   l.employee_id, p.display_name, p.email::text, l.action, l.status, l.points, l.source_type, l.created_at
            FROM scoring.points_ledger l
            LEFT JOIN campaign.campaign c ON c.id = l.campaign_id
            LEFT JOIN campaign.category cat ON cat.code = c.category_code
            LEFT JOIN identity.employee p ON p.employee_id = l.employee_id
            WHERE l.created_at >= CAST(${a} AS timestamptz) AND l.created_at < CAST(${b} AS timestamptz)
          UNION ALL
            SELECT 'CAMPAIGN', to_char(c.opens_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   c.id::text, c.title, COALESCE(cat.label, c.category_code), c.is_priority,
                   NULL, NULL, NULL, NULL, c.status, NULL,
                   'closes ' || to_char(c.closes_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || '; card ' || COALESCE(a.status, 'NONE'),
                   c.opens_at
            FROM campaign.campaign_v c
            LEFT JOIN campaign.category cat ON cat.code = c.category_code
            LEFT JOIN announcement.announcement_v a ON a.campaign_id = c.id
            WHERE c.opens_at >= CAST(${a} AS timestamptz) AND c.opens_at < CAST(${b} AS timestamptz)
          UNION ALL
            SELECT 'CONNECTION', to_char(m.connected_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   NULL, NULL, NULL, NULL, m.employee_id, p.display_name, p.email::text, NULL, m.status, NULL,
                   'token expires ' || to_char(m.access_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                   m.connected_at
            FROM connection.member_connection_v m
            LEFT JOIN identity.employee p ON p.employee_id = m.employee_id
            WHERE m.connected_at >= CAST(${a} AS timestamptz) AND m.connected_at < CAST(${b} AS timestamptz)
        ) x
        ORDER BY x.sort_at, x."recordType", x."employeeId"
        LIMIT 200000`);
    return from ExportRow r in rows
        select r;
}

# One person's name and what they reposted, for the person popup on the dashboards.
public type PersonPost record {|
    # Campaign id
    string campaignId;
    # Title
    string title;
    # Category code
    string categoryCode;
    # Category label
    string categoryLabel;
    # Priority flag
    boolean isPriority;
    # Opens
    time:Utc opensAt;
    # Closes
    time:Utc closesAt;
    # 1 when the person reposted it plainly
    int reposts;
    # 1 when the person reposted it with their own comment
    int repostsWithCommentary;
    # Points the person earned on it, from the ledger (reversals and adjustments on the post included)
    int points;
|};

# A person as Amplify knows them.
public type PersonIdentity record {|
    # Employee id
    string employeeId;
    # Name (the id when Amplify never recorded one)
    string displayName;
    # Work email
    string? email;
|};

# A person's name and email, `()` when Amplify has never seen the id.
#
# + db - Client
# + employeeId - Employee id
# + return - The person, `()`, or an error
public isolated function personIdentity(postgresql:Client db, string employeeId) returns PersonIdentity?|error {
    stream<PersonIdentity, error?> rows = db->query(`
        SELECT x.employee_id AS "employeeId", COALESCE(p.display_name, st.display_name, x.employee_id) AS "displayName",
               COALESCE(p.email::text, st.email::text) AS email
        FROM (SELECT ${employeeId}::text AS employee_id) x
        LEFT JOIN identity.employee p ON p.employee_id = x.employee_id
        LEFT JOIN recognition.standing st ON st.employee_id = x.employee_id AND st.period_key = 'ALL'
        WHERE p.employee_id IS NOT NULL OR st.employee_id IS NOT NULL
           OR EXISTS (SELECT 1 FROM sharing.engagement_v e WHERE e.employee_id = x.employee_id)`);
    PersonIdentity[] found = check from PersonIdentity r in rows
        select r;
    return found.length() > 0 ? found[0] : ();
}

# The posts a person has an active repost of, newest first.
#
# + db - Client
# + employeeId - Employee id
# + return - One row per campaign, or an error
public isolated function personPosts(postgresql:Client db, string employeeId) returns PersonPost[]|error {
    stream<record {|string id; string title; string category_code; string category_label; boolean is_priority;
            time:Utc opens_at; time:Utc closes_at; int plain; int commented; int points;|}, error?> rows = db->query(`
        SELECT c.id::text AS id, c.title, c.category_code, COALESCE(cat.label, c.category_code) AS category_label,
               c.is_priority, c.opens_at, c.closes_at,
               count(*) FILTER (WHERE e.action NOT IN ('REPOST_COMMENTARY', 'SHARE_COMMENTARY'))::int AS plain,
               count(*) FILTER (WHERE e.action IN ('REPOST_COMMENTARY', 'SHARE_COMMENTARY'))::int AS commented,
               COALESCE(max(pts.points), 0)::int AS points
        FROM sharing.engagement_v e
        JOIN campaign.campaign c ON c.id = e.campaign_id
        LEFT JOIN campaign.category cat ON cat.code = c.category_code
        LEFT JOIN (SELECT campaign_id, sum(points) AS points FROM scoring.points_ledger
                   WHERE employee_id = ${employeeId} AND campaign_id IS NOT NULL GROUP BY campaign_id) pts
               ON pts.campaign_id = c.id
        WHERE e.status = 'ACTIVE' AND e.employee_id = ${employeeId}
        GROUP BY c.id, c.title, c.category_code, cat.label, c.is_priority, c.opens_at, c.closes_at
        ORDER BY c.opens_at DESC, c.id
        LIMIT 200`);
    return from var r in rows
        select {
            campaignId: r.id, title: r.title, categoryCode: r.category_code, categoryLabel: r.category_label,
            isPriority: r.is_priority, opensAt: r.opens_at, closesAt: r.closes_at, reposts: r.plain,
            repostsWithCommentary: r.commented, points: r.points
        };
}

# Points a person earned since the 1st of this month (UTC), from the ledger. Adjustments and reversals count, so it
# matches their standing.
#
# + db - Client
# + employeeId - Employee id
# + return - Points, or an error
public isolated function personPointsThisMonth(postgresql:Client db, string employeeId) returns int|error {
    return db->queryRow(`
        SELECT COALESCE(sum(points), 0)::int FROM scoring.points_ledger
        WHERE employee_id = ${employeeId}
          AND created_at >= date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'`);
}
