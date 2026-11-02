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


// The five boards for PO, Marketing, SLT and Admin (ADR-036): operations, campaign performance, participation,
// at a glance and the scorecard. Each is a pure function of the snapshot (dashboard_data.bal), the employee
// count (outbound.bal) and the targets (settings.bal), so every number can be checked without a database.
// Only facts Amplify recorded; nothing from LinkedIn analytics.

import amplify_domain.recognition;
import amplify_domain.reporting;

import ballerina/http;
import ballerina/log;
import ballerina/time;

// ---- Scorecard targets: configuration, never the database -------------------------------------------
// Set per environment (local/.env, Choreo configs); a missing or non-positive value uses the default.

# Employees connected, % of headcount (default 25).
configurable int scorecardTargetConnectedPct = 25;
# Expired connections, % of connected: a ceiling (default 5).
configurable int scorecardMaxExpiredPct = 5;
# Shares published / (published + failed) over the calendar month, % (default 98).
configurable int scorecardTargetShareSuccessPct = 98;
# A campaign counts as reaching people at this % of connected (default 25).
configurable int scorecardTargetPriorityReachPct = 25;
# People with an engagement in the last 30 days (default 100).
configurable int scorecardTargetActive30d = 100;
# Reposts this calendar month (default 600).
configurable int scorecardTargetRepostsPerMonth = 600;

# The scorecard lines in force.
type Targets record {|
    # Employees connected, % of headcount
    int targetConnectedPct;
    # Expired connections, % of connected (ceiling)
    int maxExpiredPct;
    # Share success, %
    int targetShareSuccessPct;
    # Reach threshold, % of connected
    int targetPriorityReachPct;
    # Active people, 30 days
    int targetActive30d;
    # Reposts, this month
    int targetRepostsPerMonth;
|};

# A configured value, or its default when it is zero or negative.
#
# + v - Configured value
# + dflt - Default
# + return - The value to use
isolated function orDefault(int v, int dflt) returns int => v > 0 ? v : dflt;

# The targets from configuration (zero and negative values fall back to the defaults; the expired ceiling may be 0).
#
# + return - The targets
isolated function scorecardTargets() returns Targets => {
    targetConnectedPct: orDefault(scorecardTargetConnectedPct, 25),
    maxExpiredPct: scorecardMaxExpiredPct >= 0 ? scorecardMaxExpiredPct : 5,
    targetShareSuccessPct: orDefault(scorecardTargetShareSuccessPct, 98),
    targetPriorityReachPct: orDefault(scorecardTargetPriorityReachPct, 25),
    targetActive30d: orDefault(scorecardTargetActive30d, 100),
    targetRepostsPerMonth: orDefault(scorecardTargetRepostsPerMonth, 600)
};

# Employee count for the boards, `()` when the people directory has never loaded (a board still renders).
#
# + correlationId - Correlation id
# + return - Headcount or `()`
isolated function headcountOrNil(string? correlationId) returns int? {
    HeadcountSnapshot|error h = headcountSnapshot(correlationId);
    if h is error {
        log:printWarn("Dashboard headcount unavailable", reason = h.message(), correlationId = correlationId);
        return ();
    }
    return h.total;
}

# `n` as a percent of `d` to one decimal; 0 when `d` is 0.
#
# + n - Numerator
# + d - Denominator
# + return - Percent, 0 to 100 and over
isolated function pct(int n, int d) returns decimal => d <= 0 ? 0d : (<decimal>n * 100d / <decimal>d).round(1);

# `n` over `d` to three decimals, or `()` when `d` is 0.
#
# + n - Numerator
# + d - Denominator
# + return - Ratio or `()`
isolated function ratio(int n, int d) returns decimal? => d <= 0 ? () : (<decimal>n / <decimal>d).round(3);

isolated function announcementOf(map<reporting:Delivery> delivery, string campaignId) returns json {
    reporting:Delivery? d = delivery[campaignId];
    return d is () ? {status: "NONE", attempts: (), sentAt: ()} : {status: d.status, attempts: d.attempts, sentAt: tsOpt(d.sentAt)};
}

isolated function dashboardCampaignJson(reporting:CampaignRow p, map<reporting:Delivery> delivery) returns json => {
    campaignId: p.campaignId,
    title: p.title,
    categoryCode: p.categoryCode,
    categoryLabel: p.categoryLabel,
    isPriority: p.isPriority,
    status: p.status,
    opensAt: ts(p.opensAt),
    closesAt: ts(p.closesAt),
    reposts: p.reposts,
    repostsWithCommentary: p.repostsWithCommentary,
    announcement: announcementOf(delivery, p.campaignId)
};

# Operations board.
#
# + s - Snapshot
# + headcount - Employee count or `()`
# + return - Body
isolated function operationsBoard(Snapshot s, int? headcount) returns json {
    reporting:ConnectionBreakdown c = s.connections;
    int connected = c.active + c.expiring + c.expired + c.revoked;
    reporting:CampaignRow[] campaigns = s.campaigns.length() > 20 ? s.campaigns.slice(0, 20) : s.campaigns;
    return {
        asOf: ts(s.asOf),
        headcount,
        kpis: {
            campaignsLive: s.live.live,
            campaignsLivePriority: s.live.livePriority,
            campaignsClosingWithin7Days: s.live.closingWithin7Days,
            repostsThisMonth: s.repostsThisMonth,
            repostsThisMonthWithCommentary: s.repostsThisMonthWithCommentary,
            repostsPrevMonth: s.repostsPrevMonth,
            peopleConnected: connected,
            connectionsExpired: c.expired,
            pointsThisMonth: s.points.month,
            pointsThisYear: s.points.year,
            peopleWithPoints: s.peopleWithPoints
        },
        campaigns: from reporting:CampaignRow p in campaigns
            select dashboardCampaignJson(p, s.delivery),
        shareHealth: {
            windowStart: ts(recognition:monthStartOf(s.asOf)),
            published: s.shares.published,
            queued: s.shares.queued,
            failed: s.shares.failed,
            failedByReason: s.shares.failedByReason.toJson()
        },
        connections: {
            active: c.active,
            expiring: c.expiring,
            expired: c.expired,
            revoked: c.revoked,
            neverConnected: headcount is int ? int:max(0, headcount - connected) : ()
        }
    };
}

# Campaigns that count for a look-back: open now, or opened within `days`.
#
# + s - Snapshot
# + days - Look-back
# + return - Campaigns, most reposts first
isolated function campaignsWithin(Snapshot s, int days) returns reporting:CampaignRow[] {
    time:Utc since = time:utcAddSeconds(s.asOf, -86400d * <decimal>days);
    return from reporting:CampaignRow p in s.campaigns
        where p.status == "OPEN" || time:utcDiffSeconds(p.opensAt, since) >= 0d
        order by p.reposts descending, p.title ascending
        limit 50
        select p;
}

# Campaign performance board.
#
# + s - Snapshot
# + days - Look-back, 1 to 90
# + categories - Reposts by category in the look-back
# + selected - The selected campaign, its first seven days, its card and the people who reposted it, `()` when there are no campaigns
# + return - Body
isolated function campaignsBoard(Snapshot s, int days, reporting:CategoryCount[] categories,
        [reporting:CampaignRow, int[], reporting:CampaignCard, reporting:Reposter[]]? selected) returns json {
    reporting:CampaignRow[] campaigns = campaignsWithin(s, days);
    int connected = s.connections.active + s.connections.expiring + s.connections.expired + s.connections.revoked;
    json detail = ();
    if selected is [reporting:CampaignRow, int[], reporting:CampaignCard, reporting:Reposter[]] {
        reporting:CampaignRow p = selected[0];
        int[] byDay = selected[1];
        reporting:CampaignCard card = selected[2];
        reporting:Reposter[] people = selected[3];
        detail = {
            campaignId: p.campaignId,
            title: p.title,
            categoryCode: p.categoryCode,
            categoryLabel: p.categoryLabel,
            isPriority: p.isPriority,
            opensAt: ts(p.opensAt),
            closesAt: ts(p.closesAt),
            reposts: p.reposts,
            repostsWithCommentary: p.repostsWithCommentary,
            shareOfConnected: ratio(p.reposts, connected),
            first24Hours: byDay[0],
            announcement: announcementOf(s.delivery, p.campaignId),
            summary: card.summary,
            imageUrl: card.imageUrl,
            resourceUrl: card.resourceUrl,
            resourceUrn: card.resourceUrn,
            byDay: from int i in 0 ..< byDay.length()
                select {day: i + 1, reposts: byDay[i]},
            people: {
                reposts: from reporting:Reposter r in people
                    where !r.withCommentary
                    select {employeeId: r.employeeId, displayName: r.displayName, email: r.email},
                withComments: from reporting:Reposter r in people
                    where r.withCommentary
                    select {employeeId: r.employeeId, displayName: r.displayName, email: r.email}
            }
        };
    }
    return {
        asOf: ts(s.asOf),
        windowDays: days,
        peopleConnected: connected,
        campaigns: from reporting:CampaignRow p in campaigns
            select dashboardCampaignJson(p, s.delivery),
        selected: detail,
        byCategory: from reporting:CategoryCount k in categories
            select {code: k.code, label: k.label, reposts: k.reposts, repostsWithCommentary: k.repostsWithCommentary}
    };
}

# Participation funnel numbers.
#
# + s - Snapshot
# + headcount - Employee count or `()`
# + return - Body
isolated function participationBoard(Snapshot s, int? headcount) returns json => {
    asOf: ts(s.asOf),
    funnel: {
        employees: headcount,
        connected: s.participation.connected,
        reposted: s.participation.reposted,
        active30Days: s.participation.active30Days,
        expired: s.participation.expired
    }
};

# Live campaigns reposted by at least `thresholdPct` of connected people.
#
# + s - Snapshot
# + thresholdPct - Percent of connected
# + priorityOnly - Count only priority campaigns
# + return - `[reached, live]`
isolated function reach(Snapshot s, int thresholdPct, boolean priorityOnly) returns [int, int] {
    int connected = s.connections.active + s.connections.expiring + s.connections.expired + s.connections.revoked;
    int live = 0;
    int reached = 0;
    foreach reporting:CampaignRow p in s.campaigns {
        if p.status != "OPEN" || (priorityOnly && !p.isPriority) {
            continue;
        }
        live += 1;
        if connected > 0 && p.reposts * 100 >= thresholdPct * connected {
            reached += 1;
        }
    }
    return [reached, live];
}

# At a glance board.
#
# + s - Snapshot
# + headcount - Employee count or `()`
# + targets - Targets (the reach threshold)
# + return - Body
isolated function glanceBoard(Snapshot s, int? headcount, Targets targets) returns json {
    var [reached, live] = reach(s, targets.targetPriorityReachPct, false);
    reporting:CampaignRow? best = ();
    foreach reporting:CampaignRow p in s.campaigns {
        if p.reposts > 0 && (best is () || p.reposts > best.reposts) {
            best = p;
        }
    }
    string month = time:utcToString(s.asOf).substring(0, 7);
    return {
        asOf: ts(s.asOf),
        month,
        reposts: {thisMonth: s.repostsThisMonth, previousMonth: s.repostsPrevMonth},
        monthly: from reporting:MonthCount m in s.monthly
            select {monthStart: m.monthStart, reposts: m.reposts},
        participants: s.participation.reposted,
        headcount,
        campaignsLive: s.live.live,
        campaignsReachingTarget: {reached, live, thresholdPercent: targets.targetPriorityReachPct},
        shareSuccess: {published: s.shares.published, attempts: s.shares.published + s.shares.failed},
        bestCampaign: best is () ? () : {
            campaignId: best.campaignId,
            title: best.title,
            categoryLabel: best.categoryLabel,
            isPriority: best.isPriority,
            reposts: best.reposts
        }
    };
}

isolated function measure(string key, string label, string unit, decimal value, int? numerator, int? denominator,
        decimal target, string comparison, string? note = (), boolean? onTrack = ()) returns json {
    boolean ok = onTrack ?: (comparison == "AT_LEAST" ? value >= target : value <= target);
    return {key, label, unit, value, numerator, denominator, target, comparison, status: ok ? "ON_TRACK" : "WATCH", note};
}

# Scorecard: seven measures against their targets. A measure with nothing to measure (no shares, no campaigns)
# is On track with a note saying so; a missing employee count is Watch.
#
# + s - Snapshot
# + headcount - Employee count or `()`
# + t - Targets
# + return - Body
isolated function scorecard(Snapshot s, int? headcount, Targets t) returns json {
    reporting:ConnectionBreakdown c = s.connections;
    int connected = c.active + c.expiring + c.expired + c.revoked;
    int attempts = s.shares.published + s.shares.failed;
    var [reachedPriority, livePriority] = reach(s, t.targetPriorityReachPct, true);
    reporting:CardCounts cards = s.cards;
    string cardNote = cards.total == 0 ? "No campaigns opened in the last 30 days"
        : string `${cards.retrying} retrying, ${cards.failed} failed after retries`;
    return {
        asOf: ts(s.asOf),
        measures: [
            headcount is int
                ? measure("connected", "Employees connected", "PERCENT", pct(connected, headcount), connected, headcount,
                        <decimal>t.targetConnectedPct, "AT_LEAST")
                : measure("connected", "Employees connected", "PERCENT", 0d, connected, (), <decimal>t.targetConnectedPct,
                        "AT_LEAST", "Employee count unavailable", false),
            measure("expired", "Connections expired", "PERCENT", pct(c.expired, connected), c.expired, connected,
                    <decimal>t.maxExpiredPct, "AT_MOST", connected == 0 ? "No connections yet" : ()),
            measure("shareSuccess", "Share success rate", "PERCENT", attempts == 0 ? 0d : pct(s.shares.published, attempts),
                    s.shares.published, attempts, <decimal>t.targetShareSuccessPct, "AT_LEAST",
                    attempts == 0 ? "No shares this month" : (), attempts == 0 ? true : ()),
            measure("chatCards", "Chat cards delivered", "PERCENT", cards.total == 0 ? 0d : pct(cards.sent, cards.total),
                    cards.sent, cards.total, 100d, "AT_LEAST", cardNote, cards.total == 0 ? true : ()),
            measure("priorityReach", "Priority campaigns reaching " + t.targetPriorityReachPct.toString() + "% of connected",
                    "PERCENT", livePriority == 0 ? 0d : pct(reachedPriority, livePriority), reachedPriority, livePriority,
                    100d, "AT_LEAST", livePriority == 0 ? "No priority campaigns live" : (), livePriority == 0 ? true : ()),
            measure("active30Days", "Active employees, last 30 days", "COUNT", <decimal>s.participation.active30Days, (), (),
                    <decimal>t.targetActive30d, "AT_LEAST"),
            measure("repostsPerMonth", "Reposts, this month", "COUNT", <decimal>s.repostsThisMonth, (), (),
                    <decimal>t.targetRepostsPerMonth, "AT_LEAST")
        ]
    };
}

// ---- Handlers ------------------------------------------------------------------------------------------

const string BOARD_CACHE = "private, max-age=60";

isolated function boardResponse(json body) returns http:Response|error {
    http:Response res = check jsonBody(body);
    cacheable(res, BOARD_CACHE);
    return res;
}

isolated function dashboardOperations(string? correlationId) returns http:Response|ProblemResponse|error {
    Snapshot|error s = snapshot();
    if s is error {
        return failure(s, correlationId, "Operations board");
    }
    return boardResponse(operationsBoard(s, headcountOrNil(correlationId)));
}

isolated function dashboardCampaigns(string? correlationId, int days, string? campaignId)
        returns http:Response|ProblemResponse|error {
    if days < 1 || days > 90 {
        return badRequest("days must be 1-90", correlationId);
    }
    do {
        check maxLen(campaignId, 64, "campaignId");
        Snapshot s = check snapshot();
        reporting:CampaignRow[] campaigns = campaignsWithin(s, days);
        reporting:CampaignRow? pick = ();
        if campaignId is string && campaignId.trim().length() > 0 {
            foreach reporting:CampaignRow p in s.campaigns {
                if p.campaignId == campaignId.trim() {
                    pick = p;
                }
            }
            if pick is () {
                return notFound("Campaign not found in the last 90 days", correlationId);
            }
        } else if campaigns.length() > 0 {
            pick = campaigns[0];
        }
        [reporting:CampaignRow, int[], reporting:CampaignCard, reporting:Reposter[]]? selected = ();
        if pick is reporting:CampaignRow {
            var [card, people] = check campaignPeople(pick.campaignId);
            selected = [pick, check campaignByDay(pick.campaignId), card, people];
        }
        reporting:CategoryCount[] categories = check categoryCounts(time:utcAddSeconds(s.asOf, -86400d * <decimal>days));
        return boardResponse(campaignsBoard(s, days, categories, selected));
    } on fail error e {
        return failure(e, correlationId, "Campaign performance board");
    }
}

isolated function dashboardParticipation(string? correlationId) returns http:Response|ProblemResponse|error {
    Snapshot|error s = snapshot();
    if s is error {
        return failure(s, correlationId, "Participation board");
    }
    return boardResponse(participationBoard(s, headcountOrNil(correlationId)));
}

isolated function dashboardGlance(string? correlationId) returns http:Response|ProblemResponse|error {
    do {
        Snapshot s = check snapshot();
        return boardResponse(glanceBoard(s, headcountOrNil(correlationId), scorecardTargets()));
    } on fail error e {
        return failure(e, correlationId, "At a glance board");
    }
}

isolated function dashboardScorecard(string? correlationId) returns http:Response|ProblemResponse|error {
    do {
        Snapshot s = check snapshot();
        return boardResponse(scorecard(s, headcountOrNil(correlationId), scorecardTargets()));
    } on fail error e {
        return failure(e, correlationId, "Scorecard");
    }
}

// ---- Raw-data export -------------------------------------------------------------------------------

const int EXPORT_MAX_DAYS = 366;

const string[] EXPORT_COLUMNS = ["record_type", "occurred_at", "campaign_id", "campaign_title", "category", "is_priority",
    "employee_id", "employee_name", "employee_email", "action", "status", "points", "detail"];

# One CSV cell: quoted when it holds a comma, quote or line break, and a leading `=`, `+`, `-`, `@`, tab or
# return gets a single quote in front so a spreadsheet never runs a name or title as a formula.
#
# + value - Cell text, `()` for empty
# + return - The cell
isolated function csvCell(string? value) returns string {
    if value is () || value.length() == 0 {
        return "";
    }
    string v = value;
    string first = v.substring(0, 1);
    if first == "=" || first == "+" || first == "-" || first == "@" || first == "\t" || first == "\r" {
        v = "'" + v;
    }
    if v.includes(",") || v.includes("\"") || v.includes("\n") || v.includes("\r") {
        return "\"" + re `"`.replaceAll(v, "\"\"") + "\"";
    }
    return v;
}

# The export rows as CSV text, header first, CRLF line ends.
#
# + rows - Rows
# + return - CSV
isolated function exportCsv(reporting:ExportRow[] rows) returns string {
    string[] lines = [string:'join(",", ...EXPORT_COLUMNS)];
    foreach reporting:ExportRow r in rows {
        boolean? priority = r.isPriority;
        int? points = r.points;
        // Text columns go through `csvCell` (quoting, formula guard). Points are a number: a negative one
        // (a reversal) must stay a number, or a spreadsheet reads `'-10` as text and drops it from a sum.
        string[] cells = [csvCell(r.recordType), csvCell(r.occurredAt), csvCell(r.campaignId), csvCell(r.campaignTitle),
            csvCell(r.category), priority is boolean ? priority.toString() : "", csvCell(r.employeeId),
            csvCell(r.employeeName), csvCell(r.employeeEmail), csvCell(r.action), csvCell(r.status),
            points is int ? points.toString() : "", csvCell(r.detail)];
        lines.push(string:'join(",", ...cells));
    }
    return string:'join("\r\n", ...lines) + "\r\n";
}

# A `YYYY-MM-DD` date as midnight UTC, `()` when it isn't a real date.
#
# + date - Text
# + return - The moment, or `()`
isolated function dayStart(string date) returns time:Utc? {
    if !re `\d{4}-\d{2}-\d{2}`.isFullMatch(date) {
        return ();
    }
    time:Utc|error t = time:utcFromString(date + "T00:00:00Z");
    return t is time:Utc ? t : ();
}

isolated function dashboardExport(string? correlationId, string 'from, string to) returns http:Response|ProblemResponse|error {
    time:Utc? firstDay = dayStart('from);
    time:Utc? last = dayStart(to);
    if firstDay is () || last is () {
        return badRequest("from and to must be dates, YYYY-MM-DD", correlationId);
    }
    time:Utc endExclusive = time:utcAddSeconds(last, 86400d);
    if time:utcDiffSeconds(endExclusive, firstDay) <= 0d {
        return badRequest("to must not be before from", correlationId);
    }
    if time:utcDiffSeconds(endExclusive, firstDay) > 86400d * <decimal>EXPORT_MAX_DAYS {
        return badRequest("The range is at most " + EXPORT_MAX_DAYS.toString() + " days", correlationId);
    }
    reporting:ExportRow[]|error rows = exportRows(firstDay, endExclusive);
    if rows is error {
        return failure(rows, correlationId, "Export");
    }
    http:Response res = new;
    res.setTextPayload(exportCsv(rows), "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", string `attachment; filename="amplify-${'from}-to-${to}.csv"`);
    return res;
}

// ---- One person's Post Performance -----------------------------------------------------------------

# The person popup: who they are and every post they reposted, with the category split.
#
# + who - The person
# + posts - Their posts, newest first
# + pointsThisMonth - Points earned since the 1st (UTC)
# + return - Body
isolated function personBoard(reporting:PersonIdentity who, reporting:PersonPost[] posts, int pointsThisMonth = 0)
        returns json {
    map<[int, int]> byCode = {};
    map<int> pointsByCode = {};
    map<string> labels = {};
    int plain = 0;
    int commented = 0;
    foreach reporting:PersonPost p in posts {
        plain += p.reposts;
        commented += p.repostsWithCommentary;
        [int, int] cur = byCode[p.categoryCode] ?: [0, 0];
        byCode[p.categoryCode] = [cur[0] + p.reposts, cur[1] + p.repostsWithCommentary];
        labels[p.categoryCode] = p.categoryLabel;
        pointsByCode[p.categoryCode] = (pointsByCode[p.categoryCode] ?: 0) + p.points;
    }
    json[] categories = from string code in byCode.keys()
        let [int, int] n = byCode.get(code)
        order by n[0] + n[1] descending, labels.get(code) ascending
        select {code, label: labels.get(code), reposts: n[0], repostsWithCommentary: n[1],
            points: pointsByCode[code] ?: 0};
    return {
        employeeId: who.employeeId,
        displayName: who.displayName,
        email: who.email,
        reposts: plain,
        repostsWithCommentary: commented,
        pointsThisMonth,
        campaigns: from reporting:PersonPost p in posts
            select {
                campaignId: p.campaignId,
                title: p.title,
                categoryCode: p.categoryCode,
                categoryLabel: p.categoryLabel,
                isPriority: p.isPriority,
                opensAt: ts(p.opensAt),
                closesAt: ts(p.closesAt),
                reposts: p.reposts,
                repostsWithCommentary: p.repostsWithCommentary,
                points: p.points
            },
        byCategory: categories
    };
}

isolated function dashboardPerson(string? correlationId, string employeeId) returns http:Response|ProblemResponse|error {
    do {
        check maxLen(employeeId, 255, "employeeId");
        [reporting:PersonIdentity, reporting:PersonPost[], int]? found = check personPosts(employeeId);
        if found is () {
            return notFound("Person not found", correlationId);
        }
        return boardResponse(personBoard(found[0], found[1], found[2]));
    } on fail error e {
        return failure(e, correlationId, "Person board");
    }
}
