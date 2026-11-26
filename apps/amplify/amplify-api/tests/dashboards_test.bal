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


// The five boards (ADR-036): who may read them, what each returns for a known snapshot, the scorecard against
// its targets, validation, the 60 s snapshot cache and degradation without the employee count.


import amplify_domain.reporting;

import ballerina/http;
import ballerina/test;

const string[] BOARDS = ["operations", "campaigns", "participation", "glance", "scorecard"];
const string[] BOARD_SCHEMAS = ["DashboardOperations", "DashboardCampaigns", "DashboardParticipation", "DashboardGlance",
    "DashboardScorecard"];

function boardToken(string role) returns string|error => rvToken("dash-" + role, groups = [role]);

function measureOf(json body, string key) returns json|error {
    foreach json m in <json[]>check body.measures {
        if check m.key == key {
            return m;
        }
    }
    return error("no measure " + key);
}

@test:Config {groups: ["dashboards"]}
function testPlainEmployeesNeverSeeTheBoards() returns error? {
    setSnapshot();
    string employee = check rvToken("dash-plain");
    foreach string board in BOARDS {
        http:Response res = check send("GET", "/dashboards/" + board, (), employee);
        test:assertEquals(res.statusCode, 403, board);
        test:assertEquals(check codeIn(res), "ROLE_NOT_PERMITTED", board);
    }
    http:Response none = check send("GET", "/dashboards/glance", (), "not-a-token");
    test:assertEquals(none.statusCode, 401, "not a valid token");
    // An unrelated group isn't an amplify role.
    http:Response other = check send("GET", "/dashboards/glance", (), check rvToken("dash-other", groups = ["engineering"]));
    test:assertEquals(other.statusCode, 403);
}

@test:Config {groups: ["dashboards"]}
function testEveryAmplifyRoleReadsEveryBoard() returns error? {
    setSnapshot();
    setDirectory("ok");
    foreach string role in [PO_GROUP, MARKETING_GROUP, SLT_GROUP, ADMIN_GROUP] {
        string token = check boardToken(role);
        foreach int i in 0 ..< BOARDS.length() {
            http:Response res = check send("GET", "/dashboards/" + BOARDS[i], (), token);
            test:assertEquals(res.statusCode, 200, role + " " + BOARDS[i]);
            check assertShape(res, BOARD_SCHEMAS[i]);
            test:assertEquals(header(res, "Cache-Control"), "private, max-age=60");
        }
    }
}

@test:Config {groups: ["dashboards"]}
function testOperationsBoardNumbers() returns error? {
    setSnapshot();
    setDirectory("ok");
    json body = check (check send("GET", "/dashboards/operations", (), check boardToken(PO_GROUP))).getJsonPayload();
    test:assertEquals(check body.headcount, 4);
    test:assertEquals(check body.kpis.campaignsLive, 2);
    test:assertEquals(check body.kpis.campaignsLivePriority, 1);
    test:assertEquals(check body.kpis.repostsThisMonth, 90);
    test:assertEquals(check body.kpis.repostsThisMonthWithCommentary, 15);
    test:assertEquals(check body.kpis.pointsThisYear, 4000);
    test:assertEquals(check body.kpis.repostsPrevMonth, 50);
    test:assertEquals(check body.kpis.peopleConnected, 2);
    test:assertEquals(check body.kpis.connectionsExpired, 1);
    test:assertEquals(check body.kpis.pointsThisMonth, 500);
    test:assertEquals(check body.connections, {active: 1, expiring: 0, expired: 1, revoked: 0, neverConnected: 2});
    test:assertEquals(check body.shareHealth.published, 57);
    json[] campaigns = <json[]>check body.campaigns;
    test:assertEquals(campaigns.length(), 4);
    test:assertEquals(check campaigns[0].repostsWithCommentary, 12, "reposts with the employee's own commentary");
    test:assertEquals(check campaigns[1].repostsWithCommentary, 0);
    test:assertEquals(check campaigns[0].announcement, {status: "SENT", attempts: (), sentAt: "2025-10-20T22:40:00Z"});
    test:assertEquals(check campaigns[1].announcement.attempts, 3, "the retry the worker is on");
    test:assertEquals(check campaigns[2].announcement.status, "NONE", "no announcement row yet");

    // Without the directory the board still renders, with no headcount and no never-connected figure.
    setDirectory("down");
    json bare = check (check send("GET", "/dashboards/operations", (), check boardToken(PO_GROUP))).getJsonPayload();
    test:assertEquals(check bare.headcount, ());
    test:assertEquals(check bare.connections.neverConnected, ());
    setDirectory("ok");
}

@test:Config {groups: ["dashboards"]}
function testPostPerformanceBoardSelectsAndFilters() returns error? {
    setSnapshot();
    string token = check boardToken(MARKETING_GROUP);
    json body = check (check send("GET", "/dashboards/campaigns", (), token)).getJsonPayload();
    test:assertEquals(check body.windowDays, 30);
    json[] campaigns = <json[]>check body.campaigns;
    test:assertEquals(campaigns.map(p => checkpanic p.campaignId), ["p-launch", "p-event", "p-old"],
            "most reposts first; the campaign opened 80 days ago is outside 30 days");
    test:assertEquals(check body.selected.campaignId, "p-launch", "defaults to the top campaign");
    test:assertEquals(check body.selected.first24Hours, 30);
    test:assertEquals((check body.selected.shareOfConnected).toString(), "20", "40 reposts / 2 connected");
    json[] byDay = <json[]>check body.selected.byDay;
    test:assertEquals(byDay.length(), 7);
    test:assertEquals(check byDay[0], {day: 1, reposts: 30});
    test:assertEquals(check body.selected.imageUrl, "https://example.com/launch.png");
    test:assertEquals(check body.selected.summary, "Launch day");
    test:assertEquals(check body.selected.people.reposts, [{employeeId: "e1", displayName: "Ada Lovelace", email: "ada@example.com"}, {employeeId: "e3", displayName: "Alan Turing", email: "alan@example.com"}]);
    test:assertEquals(check body.selected.people.withComments, [{employeeId: "e2", displayName: "Grace Hopper", email: ()}]);
    test:assertEquals(check body.selected.resourceUrn, "urn:li:share:1");
    test:assertEquals(check body.byCategory, [{code: "PRODUCT", label: "Product", reposts: 45, repostsWithCommentary: 12},
        {code: "EVENT", label: "Event", reposts: 10, repostsWithCommentary: 0}]);

    json wide = check (check send("GET", "/dashboards/campaigns?days=90", (), token)).getJsonPayload();
    test:assertEquals((<json[]>check wide.campaigns).length(), 4, "90 days reaches the old campaign");
    json pick = check (check send("GET", "/dashboards/campaigns?campaignId=p-event", (), token)).getJsonPayload();
    test:assertEquals(check pick.selected.campaignId, "p-event");
    test:assertEquals(check pick.selected.first24Hours, 1);

    test:assertEquals((check send("GET", "/dashboards/campaigns?campaignId=nope", (), token)).statusCode, 404);
    foreach string q in ["days=0", "days=91", "campaignId=" + "x".padEnd(65, "x")] {
        test:assertEquals((check send("GET", "/dashboards/campaigns?" + q, (), token)).statusCode, 400, q);
    }
    // No campaigns at all: selected is null.
    Snapshot empty = fixedSnapshot();
    empty.campaigns = [];
    setSnapshot(empty);
    json none = check (check send("GET", "/dashboards/campaigns", (), token)).getJsonPayload();
    test:assertEquals(check none.selected, ());
    test:assertEquals((<json[]>check none.campaigns).length(), 0);
    setSnapshot();
}

@test:Config {groups: ["dashboards"]}
function testParticipationAndGlanceBoards() returns error? {
    setSnapshot();
    setDirectory("ok");
    string token = check boardToken(SLT_GROUP);
    json funnel = check (check send("GET", "/dashboards/participation", (), token)).getJsonPayload();
    test:assertEquals(check funnel.funnel, {employees: 4, connected: 2, reposted: 30, active30Days: 25, expired: 1});
    // Four people in the directory: Colombo (3) is under the smallest group (5), so everyone is in Other.
    test:assertEquals(check funnel.minGroupSize, 5);
    test:assertEquals(check funnel.reachConsenting, 12);
    json[] locations = check (check funnel.byLocation).ensureType();
    test:assertEquals(locations.length(), 1);
    test:assertEquals(check locations[0].location, "Other");
    test:assertEquals(check locations[0].size, 4);
    test:assertEquals(check locations[0].connected, 2, "a person the directory doesn't know lands in Other too");

    json glance = check (check send("GET", "/dashboards/glance", (), token)).getJsonPayload();
    test:assertEquals(check glance.month, "2025-10");
    test:assertEquals(check glance.reposts, {thisMonth: 90, previousMonth: 50});
    test:assertEquals((<json[]>check glance.monthly).length(), 6);
    test:assertEquals(check glance.participants, 30);
    test:assertEquals(check glance.campaignsReachingTarget, {reached: 2, live: 2, thresholdPercent: 25});
    test:assertEquals(check glance.shareSuccess, {published: 57, attempts: 60});
    test:assertEquals(check glance.bestCampaign.title, "Ancient", "the most reposts in the snapshot's campaigns");
}

@test:Config {groups: ["dashboards"]}
function testScorecardStatusesAgainstTargets() returns error? {
    clearSettings();
    setSnapshot();
    setDirectory("ok");
    json body = check (check send("GET", "/dashboards/scorecard", (), check boardToken(SLT_GROUP))).getJsonPayload();
    json[] measures = <json[]>check body.measures;
    test:assertEquals(measures.map(m => checkpanic m.key), ["connected", "expired", "shareSuccess", "announcements",
        "priorityReach", "active30Days", "repostsPerMonth"]);
    json connected = check measureOf(body, "connected");
    test:assertEquals((check connected.value).toString(), "50");
    test:assertEquals(check connected.status, "ON_TRACK", "50% of 4 employees against 25%");
    test:assertEquals(check (check measureOf(body, "expired")).status, "WATCH", "50% expired against a 5% ceiling");
    json share = check measureOf(body, "shareSuccess");
    test:assertEquals((check share.value).toString(), "95");
    test:assertEquals(check share.status, "WATCH", "95% against 98%");
    json cards = check measureOf(body, "announcements");
    test:assertEquals((check cards.value).toString(), "66.7");
    test:assertEquals(check cards.note, "1 retrying, 0 failed after retries");
    test:assertEquals(check (check measureOf(body, "priorityReach")).status, "ON_TRACK");
    test:assertEquals(check (check measureOf(body, "active30Days")).status, "WATCH");
    test:assertEquals((check (check measureOf(body, "repostsPerMonth")).target).toString(), "600.0");

    // The targets are configuration: lower the lines and the same numbers pass.
    Targets lowered = {targetConnectedPct: 25, maxExpiredPct: 5, targetShareSuccessPct: 98, targetPriorityReachPct: 25,
        targetActive30d: 20, targetRepostsPerMonth: 600};
    json low = scorecard(fixedSnapshot(), 4, lowered);
    json active = check measureOf(low, "active30Days");
    test:assertEquals((check active.target).toString(), "20.0");
    test:assertEquals(check active.status, "ON_TRACK");
    test:assertEquals(scorecardTargets(), {targetConnectedPct: 25, maxExpiredPct: 5, targetShareSuccessPct: 98,
        targetPriorityReachPct: 25, targetActive30d: 100, targetRepostsPerMonth: 600}, "unset configuration = the defaults");
    test:assertEquals(orDefault(0, 25), 25, "a zero or negative value falls back");
    test:assertEquals(orDefault(-3, 25), 25);
    test:assertEquals(orDefault(40, 25), 40);

    // Nothing to measure is On track with a note; a missing employee count is Watch.
    Snapshot quiet = fixedSnapshot();
    quiet.shares = {queued: 0, published: 0, failed: 0, failedByReason: {}};
    quiet.cards = {total: 0, sent: 0, queued: 0, failed: 0, retrying: 0};
    setSnapshot(quiet);
    setDirectory("down");
    json empty = check (check send("GET", "/dashboards/scorecard", (), check boardToken(SLT_GROUP))).getJsonPayload();
    json noShares = check measureOf(empty, "shareSuccess");
    test:assertEquals(check noShares.status, "ON_TRACK");
    test:assertEquals(check noShares.note, "No shares this month");
    test:assertEquals(check (check measureOf(empty, "announcements")).note, "No campaigns opened in the last 30 days");
    json noCount = check measureOf(empty, "connected");
    test:assertEquals(check noCount.status, "WATCH");
    test:assertEquals(check noCount.note, "Employee count unavailable");
    setDirectory("ok");
    setSnapshot();
}

@test:Config {groups: ["dashboards"]}
function testSnapshotIsReusedForSixtySeconds() returns error? {
    setSnapshot();
    setDirectory("ok");
    string token = check boardToken(PO_GROUP);
    _ = takeSnapshotLoads();
    foreach string board in BOARDS {
        _ = check send("GET", "/dashboards/" + board, (), token);
    }
    test:assertEquals(takeSnapshotLoads(), 1, "five boards, one snapshot");
    test:assertEquals(snapshotCacheSize(), 1);
}

@test:Config {groups: ["dashboards"]}
function testExportIsAnEscapedCsvForDashboardReadersOnly() returns error? {
    string token = check boardToken(MARKETING_GROUP);
    http:Response res = check send("GET", "/dashboards/export?from=2025-10-01&to=2025-10-31", (), token);
    test:assertEquals(res.statusCode, 200);
    test:assertTrue((header(res, "Content-Type") ?: "").startsWith("text/csv"));
    test:assertEquals(header(res, "Content-Disposition"), "attachment; filename=\"amplify-2025-10-01-to-2025-10-31.csv\"");
    string csv = check res.getTextPayload();
    string[] lines = re `\r\n`.split(csv.trim());
    test:assertEquals(lines[0], "record_type,occurred_at,campaign_id,campaign_title,category,is_priority,employee_id,employee_name,employee_email,action,status,points,detail,location,reactions,comments,reach");
    test:assertEquals(lines[1], "ENGAGEMENT,2025-10-20T10:00:00Z,p-launch,\"Launch, big\",Product,true,e1,\"'=Ada \"\"AL\"\" Lovelace\",ada@example.com,REPOST,ACTIVE,,,,,,420",
            "quoted, quote doubled, formula neutralised; the share's reach");
    test:assertEquals(lines[2], "POINTS,2025-10-20T10:00:01Z,,,,,e1,,,REPOST,HELD,5,ENGAGEMENT,,,,");

    http:Response plain = check send("GET", "/dashboards/export?from=2025-10-01&to=2025-10-31", (), check rvToken("dash-plain"));
    test:assertEquals(plain.statusCode, 403);
    foreach string q in ["from=2025-10-01", "from=nope&to=2025-10-31", "from=2025-10-31&to=2025-10-01", "from=2023-01-01&to=2025-10-31",
        "from=2025-02-30&to=2025-03-01"] {
        test:assertEquals((check send("GET", "/dashboards/export?" + q, (), token)).statusCode, 400, q);
    }
}

@test:Config {groups: ["dashboards"]}
function testCsvKeepsNegativePointsNumericAndStillGuardsText() {
    reporting:ExportRow row = {recordType: "POINTS", occurredAt: "2025-10-20T10:00:02Z", campaignId: (), campaignTitle: (),
        category: (), isPriority: (), employeeId: "e1", employeeName: "=Ada", employeeEmail: (), action: "REPOST",
        status: "PAID", points: -10, detail: "REVERSAL"};
    string[] lines = re `\r\n`.split(exportCsv([row]).trim());
    // A reversal's -10 stays a number a spreadsheet can sum; the name starting with `=` is still neutralised.
    test:assertEquals(lines[1], "POINTS,2025-10-20T10:00:02Z,,,,,e1,'=Ada,,REPOST,PAID,-10,REVERSAL,,,,");
}

@test:Config {groups: ["dashboards"]}
function testPersonBoardCountsOnePersonsPosts() returns error? {
    string token = check boardToken(SLT_GROUP);
    json body = check (check send("GET", "/dashboards/people/e1", (), token)).getJsonPayload();
    test:assertEquals(check body.displayName, "Ada Lovelace");
    test:assertEquals(check body.email, "ada@example.com");
    test:assertEquals(check body.reposts, 1);
    test:assertEquals(check body.repostsWithCommentary, 2);
    test:assertEquals((<json[]>check body.campaigns).length(), 2);
    test:assertEquals(check (<json[]>check body.campaigns)[0].closesAt, "2025-11-18T00:00:00Z");
    test:assertEquals(check body.pointsThisMonth, 20);
    test:assertEquals(check (<json[]>check body.campaigns)[0].points, 15);
    test:assertEquals(check body.byCategory, [{code: "PRODUCT", label: "Product", reposts: 1, repostsWithCommentary: 1, points: 15},
        {code: "EVENT", label: "Event", reposts: 0, repostsWithCommentary: 1, points: 10}]);
    test:assertEquals((check send("GET", "/dashboards/people/nobody", (), token)).statusCode, 404);
    test:assertEquals((check send("GET", "/dashboards/people/e1", (), check rvToken("dash-plain"))).statusCode, 403);
}

@test:Config {groups: ["dashboards"]}
function testLocationBreakdownMergesSmallGroups() returns error? {
    string[] everyone = [];
    map<string> locationOf = {};
    foreach int i in 0 ..< 6 {
        everyone.push(string `lk${i}@wso2.com`);
        locationOf[string `lk${i}@wso2.com`] = "Colombo";
    }
    foreach int i in 0 ..< 2 {
        everyone.push(string `us${i}@wso2.com`);
        locationOf[string `us${i}@wso2.com`] = "Mountain View";
    }
    everyone.push("nowhere@wso2.com");
    reporting:PersonParticipation[] people = [
        {email: "lk0@wso2.com", connected: true, reposted: true, active30Days: true, pointsThisMonth: 40, membersReached: 300},
        {email: "lk1@wso2.com", connected: true, reposted: false, active30Days: false, pointsThisMonth: 0, membersReached: 0},
        {email: "us0@wso2.com", connected: true, reposted: true, active30Days: false, pointsThisMonth: 10, membersReached: 50},
        {email: "nowhere@wso2.com", connected: false, reposted: false, active30Days: false, pointsThisMonth: 5, membersReached: 0}
    ];
    json[] groups = locationBreakdown(people, locationOf, everyone, 5);
    test:assertEquals(groups.length(), 2);
    test:assertEquals(groups[0], {location: "Colombo", size: 6, employees: 6, connected: 2, reposted: 1, active30Days: 1,
        pointsThisMonth: 40, reach: {membersReached: 300, approximate: true}});
    test:assertEquals(groups[1], {location: "Other", size: 3, employees: 3, connected: 1, reposted: 1, active30Days: 0,
        pointsThisMonth: 15, reach: {membersReached: 50, approximate: true}}, "Mountain View (2) merged with no location");
    json[] noDirectory = locationBreakdown(people, (), [], 5);
    test:assertEquals(noDirectory.length(), 1);
    test:assertEquals(check noDirectory[0].size, 4, "without the directory the people counted are the size");
    test:assertEquals(check noDirectory[0].employees, ());
    test:assertEquals(locationBreakdown(people, locationOf, everyone, 1).length(), 3,
            "min 1 keeps every group: Colombo, Mountain View and Other (no location)");
}

@test:Config {groups: ["dashboards"]}
function testPostPerformanceCarriesReactionsCommentsAndReach() returns error? {
    setSnapshot();
    string token = check boardToken(SLT_GROUP);
    json body = check (check send("GET", "/dashboards/campaigns?days=30&campaignId=p-launch", (), token)).getJsonPayload();
    test:assertEquals(check body.monthTotals, {month: "2025-10", reposts: 90, reactions: 11, comments: 3,
        reach: {impressions: 9000, membersReached: 3100, measuredReposts: 6, approximate: true}, reachConsenting: 12});
    test:assertEquals(check body.selected.reactions, 7);
    test:assertEquals(check body.selected.comments, 2);
    test:assertEquals(check body.selected.reach, {impressions: 5000, membersReached: 1800, measuredReposts: 4,
        approximate: true});
    json[] rows = check (check body.campaigns).ensureType();
    foreach json r in rows {
        if (check r.campaignId) == "p-event" {
            test:assertEquals(check r.reach.membersReached, 0);
            test:assertEquals(check r.reactions, 0);
        }
    }
}
