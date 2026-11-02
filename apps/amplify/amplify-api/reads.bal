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


// Read use cases behind the resources (S1 lists, S4 leaderboards.md views, the PO dashboard of
// po-dashboard.md, S5 settings). Visibility is decided here from the caller's grants and the server-side
// roster, never from request data.

import amplify_api.auth;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.recognition;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/crypto;
import ballerina/http;
import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

// ---- S1 ---------------------------------------------------------------------------------------------

isolated function listCampaigns(auth:Principal p, string? correlationId, string status, string? window, string? tag,
        int page, int size) returns json|ProblemResponse {
    do {
        if page < 0 || page > 10000 || size < 1 || size > campaign:MAX_PAGE_SIZE {
            return badRequest("page must be 0-10000 and size 1-50", correlationId);
        }
        check maxLen(tag, 50, "tag");
        string wanted = status.toLowerAscii();
        if !can(p, auth:CAN_CAMPAIGN) && wanted != "open" {
            return badRequest("Only open campaigns can be listed", correlationId);
        }
        campaign:CampaignStatus[] statuses = [];
        match wanted {
            "open" => {
                statuses = [campaign:OPEN];
            }
            "scheduled" => {
                statuses = [campaign:SCHEDULED];
            }
            "closed" => {
                statuses = [campaign:CLOSED];
            }
            "archived" => {
                statuses = [campaign:ARCHIVED];
            }
            "all" => {
                statuses = [];
            }
            _ => {
                return badRequest("status must be open, scheduled, closed, archived or all", correlationId);
            }
        }
        int? windowDays = ();
        if window is string {
            if !re `[0-9]{1,3}d`.isFullMatch(window) {
                return badRequest("window must look like 14d", correlationId);
            }
            int days = check int:fromString(window.substring(0, window.length() - 1));
            if days < 1 || days > 365 {
                return badRequest("window must be 1d-365d", correlationId);
            }
            windowDays = days;
        } else if wanted == "open" {
            windowDays = (check loadSettings()).postsWindowDays;
        }
        time:Utc now = time:utcNow();
        string? tagFilter = tag is string && tag.trim().length() > 0 ? tag.trim().toLowerAscii() : ();
        campaign:CampaignPage result = check campaignPage({statuses, windowDays, tag: tagFilter, page, size}, now);
        return {
            items: from campaign:Campaign c in result.items select campaignDto(c, now).toJson(),
            page,
            size,
            total: result.total
        };
    } on fail error e {
        return failure(e, correlationId, "List campaigns");
    }
}

isolated function getCampaign(auth:Principal p, string? correlationId, string id) returns CampaignDto|ProblemResponse {
    do {
        campaign:Campaign? c = check (check campaignRepository(actorOf(p, correlationId))).findById(check uuidOf(id, "id"));
        time:Utc now = time:utcNow();
        if c is () || (!can(p, auth:CAN_CAMPAIGN) && !campaign:isOpen(c, now)) {
            return notFound("Campaign not found", correlationId);
        }
        return campaignDto(c, now);
    } on fail error e {
        return failure(e, correlationId, "Get campaign");
    }
}

// ---- S4 -----------------------------------------------------------------------------------------------

isolated function checkPeriod(string period) returns types:DomainError? {
    if !re `ALL|[0-9]{4}-(0[1-9]|1[0-2])|[0-9]{4}-Q[1-4]`.isFullMatch(period) {
        return types:domainError(VALIDATION_FAILED, "period must be ALL, YYYY-MM or YYYY-Qn");
    }
    return ();
}

type PersonalDto record {|
    string employeeId;
    int? points;
    int? rank;
    int? previousRank;
    int? pointsToNextRank;
    int? pointsToTopN;
    boolean inTopN;
    string? lastActivityAt;
|};

isolated function personal(types:EmployeeId employeeId, recognition:Standing? s, int topN) returns PersonalDto => s is ()
    ? {employeeId, points: (), rank: (), previousRank: (), pointsToNextRank: (), pointsToTopN: (), inTopN: false,
        lastActivityAt: ()}
    : {employeeId, points: s.totalPoints, rank: s.rank, previousRank: s.previousRank,
        pointsToNextRank: s.pointsToNextRank, pointsToTopN: s.pointsToTopN, inTopN: s.rank > 0 && s.rank <= topN,
        lastActivityAt: tsOpt(s.lastActivityAt)};

# My Team availability (openapi `Leaderboard.teamStatus`, `TeamPage.teamStatus`).
type TeamStatus "OK"|"NO_TEAM"|"UNAVAILABLE";

# Team page scope (openapi `TeamPage.scope`).
type TeamScope "TEAM"|"COMPANY";

# Roster lookup that never fails the response: `[roster, teamStatus]`.
#
# + p - Caller
# + correlationId - Correlation id
# + return - Roster and `OK` / `NO_TEAM` / `UNAVAILABLE`
isolated function rosterStatus(auth:Principal p, string? correlationId) returns [Roster?, TeamStatus] {
    if !rosterConfigured() {
        // Not configured (D13 pending): a known state, logged once at startup, not on every read.
        return [(), "UNAVAILABLE"];
    }
    Roster|error? roster = rosterOf(p.email, correlationId);
    if roster is error {
        log:printWarn("Team roster unavailable", reason = roster.message(), correlationId = correlationId);
        return [(), "UNAVAILABLE"];
    }
    if roster is () {
        return [(), "NO_TEAM"];
    }
    return [roster, "OK"];
}

# The part of the leaderboard ETag that names the viewer and their team. The body is per viewer (`me`,
# `myTeam`), so an ETag of only the standings let a browser revalidate one user's cached copy for another
# (a 304 then shows the first user's position to the second). Hashed so the header carries no ids.
#
# + employeeId - Viewer
# + roster - Viewer's roster, if any
# + return - 16 hex characters
isolated function viewerTag(string employeeId, Roster? roster) returns string {
    string team = roster is Roster ? string `${roster.teamName}:${roster.emails.length()}:${roster.houses.toString()}` : "";
    byte[] digest = crypto:hashSha256(string `${employeeId}|${team}`.toBytes());
    return digest.toBase16().substring(0, 16);
}

# `Cache-Control` of a leaderboard that can be revalidated with its ETag.
const string LEADERBOARD_CACHE = "private, max-age=30";

isolated function leaderboard(auth:Principal p, string? correlationId, string period, string? ifNoneMatch)
        returns http:Response|ProblemResponse {
    do {
        check checkPeriod(period);
        int version = check standingVersion(period);
        // Looked up before the 304 check (memory-cached, so cheap): the team is part of what the body shows.
        var [roster, teamStatus] = rosterStatus(p, correlationId);
        string etag = string `"${period}:${version}:${viewerTag(p.employeeId, roster)}"`;
        if ifNoneMatch == etag {
            // RFC 9110 §15.4.5: a 304 carries the ETag and Cache-Control the 200 would have sent.
            http:Response notModified = new;
            notModified.statusCode = http:STATUS_NOT_MODIFIED;
            notModified.setHeader("ETag", etag);
            cacheable(notModified, LEADERBOARD_CACHE);
            return notModified;
        }
        Settings settings = check loadSettings();
        recognition:Standing[] top = check topStandings(period, settings.topN);
        recognition:Standing? mine = check standingOf(p.employeeId, period);
        json myTeam = ();
        if roster is Roster {
            // The whole team from the directory, joined to the standings: a member with no points, or who
            // never signed in, is a row with 0 points, no employeeId and no companyRank.
            recognition:RosterPage team = check rosterPageOf(period, membersOf(roster), (), recognition:SORT_RANK, 0, 1000);
            myTeam = {
                teamName: roster.teamName,
                headcount: roster.emails.length(),
                activeCount: team.activeCount,
                entries: from recognition:RosterEntry e in team.items
                    select {
                        employeeId: e.employeeId,
                        displayName: e.displayName,
                        email: e.email,
                        points: e.totalPoints,
                        houseName: roster.houses[e.email.toLowerAscii()],
                        teamRank: e.teamRank,
                        companyRank: e.rank,
                        isMe: e.email.toLowerAscii() == p.email.trim().toLowerAscii()
                    }
            };
        }
        // ~700 bytes: past the JDK 21 writer's 512-char window, so it goes through `jsonBody` (M11b).
        http:Response res = check jsonBody({
            period,
            topN: settings.topN,
            generatedAt: ts(time:utcNow()),
            company: from recognition:Standing s in top
                select {employeeId: s.employeeId, displayName: s.displayName, email: s.email,
                    points: s.totalPoints, rank: s.rank, previousRank: s.previousRank},
            me: personal(p.employeeId, mine, settings.topN).toJson(),
            myTeam,
            teamStatus
        });
        if teamStatus == "UNAVAILABLE" && rosterConfigured() {
            // A body degraded by a roster outage must not be revalidated: its ETag only tracks the standings,
            // so a 304 would pin the missing My Team until the next points change. The next call asks the
            // roster again. (No roster configured is a stable state: that body keeps its ETag.)
            res.setHeader("Cache-Control", "no-store");
        } else {
            res.setHeader("ETag", etag);
            cacheable(res, LEADERBOARD_CACHE);
        }
        return res;
    } on fail error e {
        return failure(e, correlationId, "Leaderboard");
    }
}

isolated function myPoints(auth:Principal p, string? correlationId, string period) returns json|ProblemResponse {
    do {
        check checkPeriod(period);
        Settings settings = check loadSettings();
        recognition:Standing? mine = check standingOf(p.employeeId, period);
        recognition:MonthPoints[] monthly = check monthlyPoints(p.employeeId);
        return {period, standing: personal(p.employeeId, mine, settings.topN).toJson(), monthly: monthly.toJson()};
    } on fail error e {
        return failure(e, correlationId, "My points");
    }
}

# A standings-only page (the people with points) in the roster page's shape, for when the directory
# cannot supply the roster.
#
# + t - Standings page
# + return - The same rows; every one has an employee id and a rank, all of them are active
isolated function rosterPageFrom(recognition:TeamPage t) returns recognition:RosterPage => {
    items: from recognition:TeamEntry e in t.items
        select {
            employeeId: e.standing.employeeId,
            displayName: e.standing.displayName,
            email: e.standing.email,
            totalPoints: e.standing.totalPoints,
            rank: e.standing.rank,
            previousRank: e.standing.previousRank,
            lastActivityAt: e.standing.lastActivityAt,
            teamRank: e.teamRank
        },
    total: t.total,
    activeCount: t.total
};

isolated function teamView(auth:Principal p, string? correlationId, string period, string? q, string sort, int page,
        int size) returns json|ProblemResponse {
    do {
        check checkPeriod(period);
        check maxLen(q, 100, "q");
        if page < 0 || page > 10000 || size < 1 || size > 100 {
            return badRequest("page must be 0-10000 and size 1-100", correlationId);
        }
        recognition:TeamSort orderBy;
        if sort == "rank" {
            orderBy = recognition:SORT_RANK;
        } else if sort == "points" {
            orderBy = recognition:SORT_POINTS;
        } else if sort == "name" {
            orderBy = recognition:SORT_NAME;
        } else {
            return badRequest("sort must be rank, points or name", correlationId);
        }
        Settings settings = check loadSettings();
        boolean company = can(p, auth:CAN_ADJUST_POINTS) || settings.teamVisibility == "COMPANY";
        TeamStatus teamStatus = "OK";
        int? headcount = ();
        string? search = q is string && q.trim().length() > 0 ? q.trim() : ();
        recognition:RosterPage result;
        if company {
            // Everyone the directory lists, points or not. Directory down: the people with points, flagged
            // `UNAVAILABLE`. No directory configured: the people with points, as before.
            DirectoryIndex|error index = rosterConfigured() ? directoryIndex(correlationId) : error("not configured");
            if index is DirectoryIndex {
                recognition:RosterMember[] everyone = everyoneIn(index);
                headcount = everyone.length();
                result = check rosterPageOf(period, everyone, search, orderBy, page, size);
            } else {
                if rosterConfigured() {
                    log:printWarn("Company list falls back to people with points: directory unavailable",
                            reason = index.message(), correlationId = correlationId);
                    teamStatus = "UNAVAILABLE";
                }
                result = rosterPageFrom(check teamPageOf(period, (), search, orderBy, page, size));
            }
        } else {
            var [roster, status] = rosterStatus(p, correlationId);
            teamStatus = status;
            if roster is Roster {
                headcount = roster.emails.length();
                result = check rosterPageOf(period, membersOf(roster), search, orderBy, page, size);
            } else {
                // No roster: the caller still sees themselves, never the company.
                result = rosterPageFrom(check teamPageOf(period, [p.email], search, orderBy, page, size));
            }
        }
        boolean adjuster = can(p, auth:CAN_ADJUST_POINTS);
        return {
            period,
            scope: <TeamScope>(company ? "COMPANY" : "TEAM"),
            page,
            size,
            total: result.total,
            teamStatus,
            summary: {headcount, activeCount: result.activeCount},
            entries: from recognition:RosterEntry e in result.items
                select {
                    employeeId: e.employeeId,
                    displayName: e.displayName,
                    email: e.email,
                    points: e.totalPoints,
                    rank: e.rank,
                    teamRank: e.teamRank,
                    previousRank: e.previousRank,
                    lastActivityAt: tsOpt(e.lastActivityAt),
                    actions: {canAdjust: adjuster, canReverse: adjuster}
                }
        };
    } on fail error e {
        return failure(e, correlationId, "Team page");
    }
}

isolated function history(auth:Principal p, string? correlationId, string employeeId, int page, int size)
        returns json|ProblemResponse {
    do {
        types:EmployeeId|types:DomainError target = types:parseEmployeeId(employeeId);
        if target is types:DomainError {
            // A path parameter: 400 like every other malformed path, not the 422 of a body field.
            return badRequest("employeeId is not a valid employee id", correlationId);
        }
        if page < 0 || page > 10000 || size < 1 || size > 100 {
            return badRequest("page must be 0-10000 and size 1-100", correlationId);
        }
        if target != p.employeeId && !can(p, auth:CAN_ADJUST_POINTS) {
            // Own, own team or `CAN_ADJUST_POINTS` only (ADR-035 section 3). `team.visibility = COMPANY` widens the
            // Team page, never this: another person's dated ledger carries adjustment and reversal reasons.
            var [roster, _] = rosterStatus(p, correlationId);
            string? email = check standingEmailOf(target);
            boolean allowed = roster is Roster && email is string && roster.emails.indexOf(email.toLowerAscii()) !is ();
            if !allowed {
                return forbidden(TEAM_SCOPE, correlationId, "You can only see your team's history");
            }
        }
        scoring:LedgerPage result = check ledgerHistory(target, page, size);
        boolean adjuster = can(p, auth:CAN_ADJUST_POINTS);
        return {employeeId: target, page, size, total: result.total,
            items: from types:LedgerEntry e in result.items select adjuster ? ledgerDto(e).toJson() : ledgerDtoForTeammate(e)};
    } on fail error e {
        return failure(e, correlationId, "Points history");
    }
}

// ---- PO dashboard (po-dashboard.md) ----------------------------------------------------------------

isolated map<[json, decimal]> dashboardCache = {};

# `Cache-Control` of the PO dashboard (it is cached 60 s server side too).
const string DASHBOARD_CACHE_CONTROL = "private, max-age=60";

# Most months the PO dashboard cache holds.
const int DASHBOARD_CACHE_MAX = 24;

# Entries in the PO dashboard cache (test seam).
#
# + return - Count
isolated function dashboardCacheSize() returns int {
    lock {
        return dashboardCache.length();
    }
}

isolated function poDashboard(string? correlationId, string? month) returns http:Response|ProblemResponse {
    do {
        time:Utc now = time:utcNow();
        string m = month ?: time:utcToString(now).substring(0, 7);
        if !re `[0-9]{4}-(0[1-9]|1[0-2])`.isFullMatch(m) {
            return badRequest("month must be YYYY-MM", correlationId);
        }
        decimal mono = time:monotonicNow();
        lock {
            [json, decimal]? hit = dashboardCache[m];
            if hit is [json, decimal] && mono - hit[1] < 60d {
                return check jsonBody(hit[0].clone(), DASHBOARD_CACHE_CONTROL);
            }
        }
        Settings settings = check loadSettings();
        json body = check dashboardData(m, settings.reviewSlaHours, now);
        lock {
            // Any YYYY-MM is a key: drop expired entries before adding, and cap the map, so a PO paging
            // through months can't grow it without bound.
            foreach [string, [json, decimal]] [k, v] in dashboardCache.entries() {
                if mono - v[1] >= 60d {
                    _ = dashboardCache.remove(k);
                }
            }
            if dashboardCache.length() >= DASHBOARD_CACHE_MAX {
                dashboardCache.removeAll();
            }
            dashboardCache[m] = [body.clone(), mono];
        }
        return check jsonBody(body, DASHBOARD_CACHE_CONTROL);
    } on fail error e {
        return failure(e, correlationId, "PO dashboard");
    }
}

# Computes the eight tiles in one database transaction (test seam).
#
# + month - `YYYY-MM`
# + slaHours - `po.review_sla_hours`
# + now - Current time
# + return - The dashboard body, or an error
isolated function dashboardData(string month, int slaHours, time:Utc now) returns json|error {
    final postgresql:Client pg = check db();
    final readonly & time:Utc at = now.cloneReadOnly();
    // One gated transaction (R-13), so the tiles read together.
    return (check store:inTransactionValue(() => dashboardTx(pg, month, slaHours, at))).ensureType();
}

isolated function dashboardTx(postgresql:Client pg, string month, int slaHours, time:Utc now) returns json|error {
    json body = ();
    time:Utc monthStart = check time:utcFromString(month + "-01T00:00:00Z");
    int y = check int:fromString(month.substring(0, 4));
    int mo = check int:fromString(month.substring(5, 7));
    string next = mo == 12 ? string `${y + 1}-01` : string `${y}-${mo + 1 < 10 ? "0" : ""}${mo + 1}`;
    time:Utc monthEnd = check time:utcFromString(next + "-01T00:00:00Z");
    // Review throughput and share health are about now: this calendar month, whatever month the page shows.
    time:Utc windowStart = recognition:monthStartOf(now);
    transaction {
        external_sharing:ReviewQueue queue = check external_sharing:reviewQueue(pg, slaHours, now);
        external_sharing:ReviewThroughput throughput = check external_sharing:reviewThroughput(pg, windowStart);
        int actionRequired = check scoring:actionRequiredCount(pg);
        scoring:ActionPoints[] byAction = check scoring:pointsByAction(pg, monthStart, monthEnd);
        recognition:RecognitionTotals totals = check recognition:recognitionTotals(pg, month + "-01", now);
        connection:ConnectionCounts connections = check connection:connectionCounts(pg);
        campaign:Campaign[] recent = check campaign:dashboardCampaigns(pg, 30, 20, now);
        string[] ids = from campaign:Campaign c in recent select c.id;
        map<recognition:CampaignNumbers> numbers = check recognition:campaignNumbers(pg, ids);
        map<announcements:AnnouncementStatus> cards = check announcements:statusesOf(pg, ids);
        sharing:ShareHealth health = check sharing:shareHealth(pg, windowStart);
        types:LedgerEntry[] corrections = check scoring:recentCorrections(pg, 10);
        check commit;
        body = {
            asOf: ts(now),
            month,
            reviewQueue: {pending: queue.pending, oldestPendingAt: tsOpt(queue.oldestPendingAt), overSla: queue.overSla,
                slaHours},
            reviewThroughput: {windowStart: ts(windowStart), approved: throughput.approved, rejected: throughput.rejected,
                amplified: throughput.amplified, medianHoursToDecision: throughput.medianHoursToDecision},
            actionRequired: {count: actionRequired},
            points: {monthTotal: totals.monthTotal, allTimeTotal: totals.allTimeTotal, byAction: byAction.toJson()},
            participation: {
                connections: connections.toJson(),
                employeesWithPoints: totals.employeesWithPoints,
                activeLast30Days: totals.activeLast30Days
            },
            campaigns: from campaign:Campaign c in recent
                let recognition:CampaignNumbers? n = numbers[c.id]
                select {
                    campaignId: c.id,
                    title: c.title,
                    isPriority: c.isPriority,
                    status: campaign:campaignStatus(c, now),
                    opensAt: ts(c.opensAt),
                    closesAt: ts(c.closesAt),
                    reposters: n is () ? 0 : n.reposters,
                    externalSharesApproved: n is () ? 0 : n.externalSharesApproved,
                    points: n is () ? 0 : n.points,
                    announcement: cards[c.id]
                },
            shareHealth: {windowStart: ts(windowStart), queued: health.queued, published: health.published, failed: health.failed,
                failedByReason: health.failedByReason.toJson()},
            recentCorrections: from types:LedgerEntry e in corrections
                select {
                    reference: e.reference,
                    'type: e.sourceType,
                    employeeId: e.employeeId,
                    email: (),
                    points: e.points,
                    reason: e.reason,
                    actorId: e.actorId,
                    createdAt: ts(e.createdAt)
                }
        };
    }
    return body;
}

// ---- S5 Admin ------------------------------------------------------------------------------------------

isolated function settingsBody() returns json|error {
    store:Setting[] rows = check settingRows();
    return {
        settings: from store:Setting s in rows
            where isVisibleSetting(s.key)
            select {key: s.key, value: s.value, version: s.version, updatedBy: s.updatedBy, updatedAt: ts(s.updatedAt)}
    };
}

isolated function changeSettings(auth:Principal p, string? correlationId, SettingChangesBody body) returns json|ProblemResponse {
    do {
        if body.changes.length() == 0 || body.changes.length() > 20 {
            return badRequest("Send 1-20 changes", correlationId);
        }
        store:SettingChange[] changes = [];
        boolean topNChanged = false;
        foreach SettingChangeBody c in body.changes {
            [string, string]? problemOf = checkSettingChange(c.key, c.value);
            if problemOf is [string, string] {
                return unprocessable(problemOf[0], problemOf[1], correlationId);
            }
            topNChanged = topNChanged || c.key == SETTING_TOP_N;
            changes.push({key: c.key, value: c.value, expectedVersion: c.version});
        }
        check saveSettings(actorOf(p, correlationId), changes);
        if topNChanged {
            // points_to_top_n is precomputed: a new top N needs a rebuild (leaderboards.md).
            _ = triggerJobs("/maintenance/rebuild-recognition", correlationId);
        }
        json saved = check settingsBody();
        if touchesSchedule(from store:SettingChange c in changes select c.key) {
            // After the commit: the database is the source of truth; a scheduler outage leaves PENDING (ADR-026).
            SchedulerSyncResult synced = syncScheduler((), correlationId);
            auditSync(actorOf(p, correlationId), synced);
            if saved is map<json> {
                saved["schedulerSync"] = synced.status;
            }
        }
        return saved;
    } on fail error e {
        return failure(e, correlationId, "Change settings");
    }
}

isolated function listAnnouncements(auth:Principal p, string? correlationId, string status) returns json|ProblemResponse {
    do {
        announcements:AnnouncementStatus? filter = ();
        match status {
            "QUEUED" => {
                filter = announcements:QUEUED;
            }
            "SENT" => {
                filter = announcements:SENT;
            }
            "FAILED" => {
                filter = announcements:FAILED;
            }
            "ALL" => {
                filter = ();
            }
            _ => {
                return badRequest("status must be QUEUED, SENT, FAILED or ALL", correlationId);
            }
        }
        announcements:Announcement[] rows = check (check announcementRepository(actorOf(p, correlationId))).list(filter, 200);
        return {items: from announcements:Announcement a in rows select announcementDto(a).toJson()};
    } on fail error e {
        return failure(e, correlationId, "List announcements");
    }
}

isolated function reviewList(string? correlationId, string status, int page, int size) returns json|ProblemResponse {
    do {
        if page < 0 || page > 10000 || size < 1 || size > 100 {
            return badRequest("page must be 0-10000 and size 1-100", correlationId);
        }
        external_sharing:ExternalShareStatus? filter = ();
        if status != "ALL" {
            external_sharing:ExternalShareStatus|error s = status.ensureType();
            if s is error {
                return badRequest("status must be PENDING, APPROVED, REJECTED, AMPLIFIED or ALL", correlationId);
            }
            filter = s;
        }
        external_sharing:ExternalSharePage result = check claimsForReview(filter, page, size);
        return {items: from var c in result.items select externalShareDto(c).toJson(), page, size, total: result.total};
    } on fail error e {
        return failure(e, correlationId, "Review list");
    }
}
