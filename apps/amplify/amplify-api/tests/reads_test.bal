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

// Read endpoints on the read fakes (read_fakes.bal) and the fake people directory: S4 leaderboard / team /
// history / points visibility and degradation (leaderboards.md, ADR-019), ETag and Cache-Control, the
// `jsonBody` encoding of every large read (M11b), the PO dashboard cache, list validation, `/ready`.

import amplify_common.types;
import amplify_domain.store;

import ballerina/http;
import ballerina/test;

function rvToken(string sub, string email = sub + "@wso2.com", string[] groups = []) returns string|error =>
    mint({sub, email, name: sub, groups});

function setSetting(string key, json value) {
    readonly & store:Setting row = {key, value: value.cloneReadOnly(), version: 1, updatedBy: "test",
        updatedAt: [1760000000, 0]};
    lock {
        fakeSettingRows = [row];
    }
}

function clearSettings() {
    lock {
        fakeSettingRows = [];
    }
}

function header(http:Response res, string name) returns string? {
    string|http:HeaderNotFoundError v = res.getHeader(name);
    return v is string ? v : ();
}

# The body is exactly what the runtime's standard encoder writes for the same value (M11b byte identity).
#
# + res - Response
# + return - An error on mismatch
function assertStandardJson(http:Response res) returns error? {
    test:assertEquals(res.getContentType(), "application/json");
    string text = check res.getTextPayload();
    json parsed = check text.fromJsonString();
    test:assertEquals(text, parsed.toJsonString(), "jsonBody bytes = the standard JSON encoder's bytes");
}

// ---- /leaderboard ------------------------------------------------------------------------------------

@test:Config {groups: ["reads"]}
function testLeaderboardEtagCacheControlAndRevalidation() returns error? {
    clearSettings();
    string token = check rvToken("rv-a");
    http:Response first = check send("GET", "/leaderboard", (), token);
    test:assertEquals(first.statusCode, 200);
    check assertShape(first, "Leaderboard");
    check assertStandardJson(first);
    json body = check first.getJsonPayload();
    test:assertEquals(check body.teamStatus, "OK");
    test:assertEquals(check body.topN, 3);
    test:assertEquals((<json[]>check body.company).length(), 3);
    json[] mine = <json[]>check body.myTeam.entries;
    test:assertEquals(mine.length(), 3, "the whole team, rv+plus has no standing row");
    test:assertEquals(check body.myTeam.activeCount, 2);
    test:assertEquals(check body.myTeam.headcount, 3);
    test:assertEquals(check mine[2].employeeId, (), "no standing, no employee id");
    test:assertEquals(check mine[2].points, 0);
    test:assertEquals(check mine[2].companyRank, (), "no standing, no company rank");
    test:assertEquals(check mine[2].isMe, false);
    test:assertEquals(check mine[0].isMe, true);
    test:assertEquals(check mine[2].displayName, "R rv+p", "the directory's name");
    test:assertEquals(check body.me.rank, 3);
    test:assertTrue(check body.me.inTopN);
    string etag = check first.getHeader("ETag");
    test:assertTrue(etag.startsWith("\"ALL:"), etag);
    test:assertEquals(header(first, "Cache-Control"), "private, max-age=30");
    test:assertEquals(header(first, "Vary"), "Authorization");

    http:Response revalidated = check send("GET", "/leaderboard", (), token, {"If-None-Match": etag});
    test:assertEquals(revalidated.statusCode, 304);
    test:assertEquals(header(revalidated, "ETag"), etag, "a 304 carries the ETag (RFC 9110)");
    test:assertEquals(header(revalidated, "Cache-Control"), "private, max-age=30");

    // The body is per viewer: another user presenting this ETag (a shared browser cache after switching
    // accounts) must get their own 200, never a 304 that would show this user's position.
    http:Response other = check send("GET", "/leaderboard", (), check rvToken("rv-b"), {"If-None-Match": etag});
    test:assertEquals(other.statusCode, 200, "a 304 across viewers would show the wrong 'me'");
    test:assertNotEquals(header(other, "ETag"), etag);
    test:assertEquals(check (check other.getJsonPayload()).me.employeeId, "rv-b");

    bumpStandingVersion();
    http:Response changed = check send("GET", "/leaderboard", (), token, {"If-None-Match": etag});
    test:assertEquals(changed.statusCode, 200, "new standings, new ETag");
    test:assertNotEquals(header(changed, "ETag"), etag);

    http:Response bad = check send("GET", "/leaderboard?period=2026-13", (), token);
    test:assertEquals(bad.statusCode, 400);
    test:assertEquals(check codeIn(bad), "VALIDATION_FAILED");
}

@test:Config {groups: ["reads"]}
function testLeaderboardRosterDegradation() returns error? {
    http:Response noTeam = check send("GET", "/leaderboard", (), check rvToken("rv-noteam"));
    test:assertEquals(noTeam.statusCode, 200);
    json body = check noTeam.getJsonPayload();
    test:assertEquals(check body.teamStatus, "NO_TEAM");
    test:assertEquals(check body.myTeam, ());
    test:assertTrue(header(noTeam, "ETag") is string, "NO_TEAM is a real answer, safe to revalidate");

    setDirectory("down");
    http:Response down = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
    test:assertEquals(down.statusCode, 200, "the roster is non-fatal (ADR-024)");
    check assertShape(down, "Leaderboard");
    test:assertEquals(check (check down.getJsonPayload()).teamStatus, "UNAVAILABLE");
    test:assertEquals(header(down, "ETag"), (), "a degraded body has no ETag, so it is never pinned by a 304");
    test:assertEquals(header(down, "Cache-Control"), "no-store");

    setDirectory("garbled");
    http:Response garbled = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
    test:assertEquals(check (check garbled.getJsonPayload()).teamStatus, "UNAVAILABLE",
            "a malformed directory body degrades like an outage");
    setDirectory("ok");
}

@test:Config {groups: ["reads"]}
function testDirectoryFetchedOnceAndCached() returns error? {
    setDirectory("ok");
    _ = takeDirectoryFetches();
    foreach [string, string] [id, email] in [["rv-a", "rv-a@wso2.com"], ["rv-plus", "rv+plus@wso2.com"],
            ["rv-b", "rv-b@wso2.com"]] {
        http:Response res = check send("GET", "/leaderboard", (), check rvToken(id, email));
        test:assertEquals(check (check res.getJsonPayload()).teamStatus, "OK", email);
    }
    test:assertEquals(takeDirectoryFetches(), 1, "one directory call serves every viewer");

    setDirectory("down");
    http:Response cold = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
    test:assertEquals(check (check cold.getJsonPayload()).teamStatus, "UNAVAILABLE",
            "nothing cached and the directory down: UNAVAILABLE");

    setDirectory("ok");
    _ = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
    expireDirectoryCache();
    lock {
        directoryMode = "down";
    }
    http:Response stale = check send("GET", "/leaderboard", (), check rvToken("rv-b"));
    test:assertEquals(check (check stale.getJsonPayload()).teamStatus, "OK",
            "an expired index is still served while a refresh fails (teams change rarely)");
    setDirectory("ok");
}

@test:Config {groups: ["reads"]}
function testFailedDirectoryRefreshIsNotCached() returns error? {
    setDirectory("ok");
    _ = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
    expireDirectoryCache();
    lock {
        directoryMode = "down";
    }
    _ = takeDirectoryFetches();
    foreach int i in 0 ..< 3 {
        http:Response res = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
        test:assertEquals(check (check res.getJsonPayload()).teamStatus, "OK", "the old teams keep being served");
    }
    test:assertEquals(takeDirectoryFetches(), 3,
            "the outage is not cached for the TTL: every call asks the directory again");
    lock {
        directoryMode = "ok";
    }
    _ = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
    test:assertEquals(takeDirectoryFetches(), 1, "recovered: one fetch");
    _ = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
    test:assertEquals(takeDirectoryFetches(), 0, "and the fresh result is cached again");
}

// ---- /team ------------------------------------------------------------------------------------------

@test:Config {groups: ["reads"]}
function testTeamPageVisibility() returns error? {
    clearSettings();
    http:Response team = check send("GET", "/team", (), check rvToken("rv-b"));
    test:assertEquals(team.statusCode, 200);
    check assertShape(team, "TeamPage");
    check assertStandardJson(team);
    json body = check team.getJsonPayload();
    test:assertEquals(check body.scope, "TEAM");
    test:assertEquals(check body.teamStatus, "OK");
    test:assertEquals(check body.summary.headcount, 3);
    json[] entries = <json[]>check body.entries;
    test:assertEquals(entries.map(e => e.email), ["rv-a@wso2.com", "rv-b@wso2.com", "rv+plus@wso2.com"],
            "the whole team, zero points included, never the company");
    test:assertEquals(check entries[2].employeeId, (), "a member with no standing row has no employee id");
    test:assertEquals(check entries[2].points, 0);
    test:assertEquals(check entries[2].rank, ());
    test:assertEquals(check body.summary.activeCount, 2, "headcount 3, two with points");
    test:assertEquals(check (<json[]>check body.entries)[0].actions.canAdjust, false);

    http:Response alone = check send("GET", "/team", (), check rvToken("lb-1"));
    json aloneBody = check alone.getJsonPayload();
    test:assertEquals(check aloneBody.teamStatus, "NO_TEAM");
    test:assertEquals((from json e in <json[]>check aloneBody.entries select (check e.employeeId).toString()), ["lb-1"],
            "no roster: the caller sees themselves");

    http:Response po = check send("GET", "/team", (), check rvToken("po-team", groups = [PO_GROUP]));
    json poBody = check po.getJsonPayload();
    test:assertEquals(check poBody.scope, "COMPANY");
    test:assertEquals(check poBody.total, 4, "everyone the directory lists, points or not");
    test:assertEquals(check poBody.summary.headcount, 4);
    test:assertEquals(check poBody.summary.activeCount, 2, "rv-a and rv-b are the listed people with points");

    // Directory down (nothing cached): the company view falls back to the people with points, flagged.
    setDirectory("down");
    json degraded = check (check send("GET", "/team", (), check rvToken("po-team", groups = [PO_GROUP]))).getJsonPayload();
    test:assertEquals(check degraded.teamStatus, "UNAVAILABLE");
    test:assertEquals(check degraded.total, 6, "standings only");
    test:assertEquals(check degraded.summary.headcount, ());
    setDirectory("ok");
    test:assertEquals(check (<json[]>check poBody.entries)[0].actions.canReverse, true);

    setSetting("team.visibility", "COMPANY");
    json wide = check (check send("GET", "/team", (), check rvToken("rv-b"))).getJsonPayload();
    test:assertEquals(check wide.scope, "COMPANY", "team.visibility = COMPANY widens it for everyone");
    clearSettings();

    string token = check rvToken("rv-b");
    foreach string query in ["sort=bogus", "size=101", "size=0", "page=-1", "page=10001", "period=ALLX",
            "q=" + "x".padEnd(101, "x")] {
        http:Response bad = check send("GET", "/team?" + query, (), token);
        test:assertEquals(bad.statusCode, 400, query);
        test:assertEquals(check codeIn(bad), "VALIDATION_FAILED", query);
    }
}

// ---- /team/{employeeId}/history -----------------------------------------------------------------------

@test:Config {groups: ["reads"]}
function testHistoryScope() returns error? {
    clearSettings();
    string me = check rvToken("rv-a");
    http:Response own = check send("GET", "/team/rv-a/history", (), me);
    test:assertEquals(own.statusCode, 200);
    check assertShape(own, "PointsHistory");
    check assertStandardJson(own);

    http:Response mate = check send("GET", "/team/rv-b/history", (), me);
    test:assertEquals(mate.statusCode, 200, "a member of the caller's team");

    http:Response stranger = check send("GET", "/team/lb-1/history", (), me);
    test:assertEquals(stranger.statusCode, 403);
    test:assertEquals(check codeIn(stranger), "TEAM_SCOPE");

    setDirectory("down");
    http:Response rosterDown = check send("GET", "/team/rv-b/history", (), check rvToken("rv-a"));
    test:assertEquals(rosterDown.statusCode, 403, "no roster never widens: only the caller's own history");
    setDirectory("ok");

    http:Response po = check send("GET", "/team/lb-1/history", (), check rvToken("po-hist", groups = [PO_GROUP]));
    test:assertEquals(po.statusCode, 200, "PO reads any row");

    // Widening the Team page to the company does not open anyone's ledger history (ADR-035 section 3).
    setSetting("team.visibility", "COMPANY");
    http:Response widened = check send("GET", "/team/lb-1/history", (), me);
    test:assertEquals(widened.statusCode, 403);
    test:assertEquals(check codeIn(widened), "TEAM_SCOPE");
    clearSettings();

    http:Response badId = check send("GET", "/team/bad!id/history", (), me);
    test:assertEquals(badId.statusCode, 400, "a malformed path id is 400, as openapi says (was 422)");
    test:assertEquals(check codeIn(badId), "VALIDATION_FAILED");
    http:Response badSize = check send("GET", "/team/rv-a/history?size=0", (), me);
    test:assertEquals(badSize.statusCode, 400);
}

// ---- /me, /me/points, /ready ----------------------------------------------------------------------------

@test:Config {groups: ["reads"]}
function testMeAndPointsShapesAndNoStore() returns error? {
    string token = check rvToken("rv-a", groups = [ADMIN_GROUP, PO_GROUP, MARKETING_GROUP]);
    http:Response me = check send("GET", "/me", (), token);
    test:assertEquals(me.statusCode, 200);
    check assertShape(me, "Me");
    check assertStandardJson(me);
    test:assertEquals(header(me, "Cache-Control"), "no-store", "personal data is never cached by default");

    http:Response points = check send("GET", "/me/points", (), token);
    test:assertEquals(points.statusCode, 200);
    check assertShape(points, "MyPoints");
    check assertStandardJson(points);
    test:assertEquals((check send("GET", "/me/points?period=2026-Q5", (), token)).statusCode, 400);

    http:Response anon = check api->get("/me");
    test:assertEquals(anon.statusCode, 401);
    test:assertEquals(header(anon, "Cache-Control"), "no-store");
}

@test:Config {groups: ["reads"]}
function testReadyReportsEveryBreakerPerContract() returns error? {
    setDbUp(true);
    http:Response ready = check testClient->get("/ready");
    test:assertEquals(ready.statusCode, 200);
    check assertShape(ready, "ReadyStatus");
    json breakers = check (check ready.getJsonPayload()).breakers;
    test:assertEquals(check breakers.jobs, "NOT_CONFIGURED", "no jobsUrl: not a closed breaker");
    test:assertEquals(check breakers.roster, "CLOSED");
    test:assertEquals(check breakers.linkedinOAuth, "NOT_CONFIGURED");
    test:assertEquals(check breakers.database, "CLOSED");
}

// ---- /po/dashboard -------------------------------------------------------------------------------------

@test:Config {groups: ["reads"]}
function testDashboardCacheIsBoundedAndCacheable() returns error? {
    string po = check rvToken("po-dash", groups = [PO_GROUP]);
    http:Response bad = check send("GET", "/po/dashboard?month=2026-1", (), po);
    test:assertEquals(bad.statusCode, 400);

    http:Response first = check send("GET", "/po/dashboard?month=2001-01", (), po);
    test:assertEquals(first.statusCode, 200);
    check assertStandardJson(first);
    test:assertEquals(header(first, "Cache-Control"), "private, max-age=60");
    test:assertEquals(header(first, "Vary"), "Authorization");
    int builds = dashboardBuildCount();
    http:Response cached = check send("GET", "/po/dashboard?month=2001-01", (), po);
    test:assertEquals(check cached.getJsonPayload(), check first.getJsonPayload());
    test:assertEquals(dashboardBuildCount(), builds, "served from the 60 s cache");
    test:assertEquals(header(cached, "Cache-Control"), "private, max-age=60");

    foreach int i in 1 ... 30 {
        string month = string `20${i < 13 ? "02" : "03"}-${(i - 1) % 12 + 1 < 10 ? "0" : ""}${(i - 1) % 12 + 1}`;
        http:Response res = check send("GET", "/po/dashboard?month=" + month, (), po);
        test:assertEquals(res.statusCode, 200, month);
    }
    test:assertTrue(dashboardCacheSize() <= 24, string `cache holds ${dashboardCacheSize()} months`);
}

// ---- Lists ---------------------------------------------------------------------------------------------

@test:Config {groups: ["reads"], dependsOn: [testRegisterCampaignIsIdempotentAndShaped]}
function testListValidationAndShapes() returns error? {
    string po = check rvToken("po-list", groups = [PO_GROUP]);
    string emp = check rvToken("rv-list");
    foreach string query in ["status=bogus", "window=abc", "window=0d", "window=366d", "size=51", "size=0",
            "page=-1", "tag=" + "t".padEnd(51, "t")] {
        http:Response bad = check send("GET", "/campaigns?" + query, (), po);
        test:assertEquals(bad.statusCode, 400, query);
    }
    http:Response archived = check send("GET", "/campaigns?status=archived", (), po);
    test:assertEquals(archived.statusCode, 200);
    check assertShape(archived, "CampaignPage");
    http:Response list = check send("GET", "/campaigns?window=30d&tag=Kubernetes", (), emp);
    test:assertEquals(list.statusCode, 200);
    check assertStandardJson(list);

    http:Response review = check send("GET", "/po/external-shares?status=ALL", (), po);
    test:assertEquals(review.statusCode, 200);
    check assertShape(review, "ExternalSharePage");
    test:assertEquals((check send("GET", "/po/external-shares?status=bogus", (), po)).statusCode, 400);
    test:assertEquals((check send("GET", "/po/external-shares?size=101", (), po)).statusCode, 400);

    http:Response mine = check send("GET", "/me/external-shares", (), emp);
    check assertShape(mine, "ExternalShareList");
    http:Response shares = check send("GET", "/me/shares", (), emp);
    check assertShape(shares, "ShareList");

    string admin = check rvToken("adm-list", groups = [ADMIN_GROUP]);
    http:Response settings = check send("GET", "/admin/settings", (), admin);
    test:assertEquals(settings.statusCode, 200);
    check assertShape(settings, "SettingList");
    test:assertEquals((check send("GET", "/admin/announcements?status=bogus", (), admin)).statusCode, 400);
    http:Response rules = check send("GET", "/po/point-rules", (), po);
    check assertShape(rules, "PointRuleList");
    check assertStandardJson(rules);
}

@test:Config {groups: ["reads"]}
function testLeaderboardWithoutRosterConfiguredKeepsItsEtag() returns error? {
    setRosterOff(true);
    http:Response res = check send("GET", "/leaderboard", (), check rvToken("rv-a"));
    setRosterOff(false);
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(check (check res.getJsonPayload()).teamStatus, "UNAVAILABLE");
    test:assertTrue(header(res, "ETag") is string, "no roster configured is a stable answer: still revalidated");
    test:assertEquals(header(res, "Cache-Control"), "private, max-age=30");
}

// ---- /headcount, /leaderboard/groups, /leaderboard/people (ADR-035) -----------------------------------

@test:Config {groups: ["reads"]}
function testHeadcountIsCountedOnceAndKeptForAWeek() returns error? {
    setDirectory("ok");
    _ = takeDirectoryFetches();
    string token = check rvToken("lb-1");
    http:Response first = check send("GET", "/headcount", (), token);
    test:assertEquals(first.statusCode, 200);
    check assertShape(first, "Headcount");
    json body = check first.getJsonPayload();
    test:assertEquals(check body.total, 4);
    test:assertEquals(check body.businessUnits, [{name: "Water", headcount: 3}, {name: "Land", headcount: 1}]);
    test:assertEquals(check body.teams, [{key: "Water/Rivers/", name: "Rivers", businessUnit: "Water", headcount: 3}]);

    _ = check send("GET", "/headcount", (), check rvToken("rv-b"));
    test:assertEquals(takeDirectoryFetches(), 1, "one directory call serves every caller for the week");

    // A week later the directory is read again; if it is down the last count keeps serving.
    expireHeadcountCache();
    lock {
        directoryMode = "down";
    }
    http:Response stale = check send("GET", "/headcount", (), token);
    test:assertEquals(stale.statusCode, 200);
    test:assertEquals(check (check stale.getJsonPayload()).total, 4, "a failed refresh keeps the last count");

    setDirectory("down");
    http:Response none = check send("GET", "/headcount", (), token);
    test:assertEquals(none.statusCode, 503, "never counted and the directory is down");
    test:assertEquals(check codeIn(none), "DEPENDENCY_UNAVAILABLE");
    setDirectory("ok");
}

@test:Config {groups: ["reads"]}
function testGroupBoardsRankTeamsAndBusinessUnits() returns error? {
    setDirectory("ok");
    string token = check rvToken("lb-1");
    http:Response teams = check send("GET", "/leaderboard/groups", (), token);
    test:assertEquals(teams.statusCode, 200);
    check assertShape(teams, "LeaderboardGroups");
    check assertStandardJson(teams);
    json body = check teams.getJsonPayload();
    test:assertEquals(check body.'by, "TEAM");
    test:assertEquals(check body.totals, {headcount: 3, participants: 2, points: 450});
    json[] entries = <json[]>check body.entries;
    test:assertEquals(entries.length(), 1);
    test:assertEquals(check entries[0].points, 450, "rv-a 300 + rv-b 150");
    test:assertEquals(check entries[0].participants, 2);
    test:assertEquals(check entries[0].headcount, 3);
    test:assertEquals(check body.unassigned, {participants: 4, points: 1200}, "lb-1, lb-2, lb-3 and rv-c aren't in the directory");

    json bus = check (check send("GET", "/leaderboard/groups?by=BU", (), token)).getJsonPayload();
    json[] buEntries = <json[]>check bus.entries;
    test:assertEquals(buEntries.map(e => checkpanic e.name), ["Water", "Land"], "ranked by points, BUs with none listed");
    test:assertEquals(buEntries.map(e => checkpanic e.rank), [1, 2]);

    json water = check (check send("GET", "/leaderboard/groups?by=TEAM&bu=Water", (), token)).getJsonPayload();
    test:assertEquals((<json[]>check water.entries).length(), 1);
    json land = check (check send("GET", "/leaderboard/groups?by=TEAM&bu=Land", (), token)).getJsonPayload();
    test:assertEquals((<json[]>check land.entries).length(), 0, "a BU with no teams");

    json houses = check (check send("GET", "/leaderboard/groups?by=HOUSE", (), token)).getJsonPayload();
    json[] houseEntries = <json[]>check houses.entries;
    test:assertEquals(houseEntries.length(), 1, "only houses the directory names");
    test:assertEquals(check houseEntries[0].name, "Oak");
    test:assertEquals(check houseEntries[0].points, 450);
    test:assertEquals(check houseEntries[0].participants, 2);
    test:assertEquals(check houseEntries[0].headcount, 3);

    foreach string query in ["sort=bogus", "dir=sideways", "by=bogus", "period=ALLX", "by=BU&bu=Water", "by=HOUSE&bu=Water", "bu=" + "x".padEnd(101, "x")] {
        http:Response bad = check send("GET", "/leaderboard/groups?" + query, (), token);
        test:assertEquals(bad.statusCode, 400, query);
    }
    test:assertEquals((check send("GET", "/leaderboard/groups?bu=Nope", (), token)).statusCode, 404);

    setDirectory("down");
    http:Response down = check send("GET", "/leaderboard/groups", (), token);
    test:assertEquals(down.statusCode, 503);
    setDirectory("ok");
}

@test:Config {groups: ["reads"]}
function testPeopleBoardsAreOpenToEveryEmployee() returns error? {
    clearSettings();
    setDirectory("ok");
    // Company: any employee, even one the directory doesn't know, sees everyone (team.visibility doesn't gate it).
    http:Response company = check send("GET", "/leaderboard/people", (), check rvToken("lb-3"));
    test:assertEquals(company.statusCode, 200);
    check assertShape(company, "LeaderboardPeople");
    check assertStandardJson(company);
    json body = check company.getJsonPayload();
    test:assertEquals(check body.scope, "COMPANY");
    test:assertEquals(check body.total, 6);
    test:assertEquals(check body.summary.headcount, 4, "the cached employee count");
    json[] everyone = <json[]>check body.entries;
    test:assertEquals(everyone.map(e => checkpanic e.employeeId), ["lb-1", "lb-2", "rv-a", "lb-3", "rv-b", "rv-c"]);

    // Own team by default, another team by key, own BU by default.
    string token = check rvToken("rv-b");
    json team = check (check send("GET", "/leaderboard/people?scope=TEAM", (), token)).getJsonPayload();
    test:assertEquals(check team.team, "Water/Rivers/");
    test:assertEquals(check team.teamName, "Rivers");
    test:assertEquals(check team.businessUnit, "Water");
    test:assertEquals((<json[]>check team.entries).map(e => checkpanic e.employeeId), ["rv-a", "rv-b"]);
    test:assertEquals(check team.summary, {headcount: 3, participants: 2});
    json byKey = check (check send("GET", "/leaderboard/people?scope=TEAM&team=Water%2FRivers%2F", (), check rvToken("lb-1"))).getJsonPayload();
    test:assertEquals((<json[]>check byKey.entries).length(), 2, "a team by key, for someone outside it");
    json bu = check (check send("GET", "/leaderboard/people?scope=BU", (), token)).getJsonPayload();
    test:assertEquals(check bu.businessUnit, "Water");
    test:assertEquals((<json[]>check bu.entries).length(), 2);
    test:assertEquals(check bu.summary, {headcount: 3, participants: 2});

    // Not in the directory: needs bu / team.
    http:Response noBu = check send("GET", "/leaderboard/people?scope=BU", (), check rvToken("lb-1"));
    test:assertEquals(noBu.statusCode, 404);
    test:assertEquals((check send("GET", "/leaderboard/people?scope=TEAM&team=Nope", (), token)).statusCode, 404);
    test:assertEquals((check send("GET", "/leaderboard/people?scope=BU&bu=Nope", (), token)).statusCode, 404);

    foreach string query in ["scope=ALL", "sort=rank", "size=101", "size=0", "page=-1", "period=ALLX",
            "q=" + "x".padEnd(101, "x")] {
        http:Response bad = check send("GET", "/leaderboard/people?" + query, (), token);
        if query == "sort=rank" {
            test:assertEquals(bad.statusCode, 200, "unknown query names are ignored");
        } else {
            test:assertEquals(bad.statusCode, 400, query);
        }
    }

    setDirectory("down");
    test:assertEquals((check send("GET", "/leaderboard/people?scope=TEAM", (), token)).statusCode, 503);
    test:assertEquals((check send("GET", "/leaderboard/people", (), token)).statusCode, 200,
            "the company board needs no directory");
    setDirectory("ok");
}

// ---- history rows for someone who is not a PO (threat model 6.4) ------------------------------------------------

@test:Config {groups: ["reads"]}
function testHistoryHidesPoReasonAndIdFromTeammates() returns error? {
    types:LedgerEntry adjustment = {
        reference: "ADJ-1", employeeId: "rv-b", campaignId: (), sourceType: types:ADJUSTMENT, sourceId: (),
        action: (), points: -5, ruleId: (), reversesReference: (), reason: "Duplicate claim, HR looking at conduct",
        actorId: "po-0001", correlationId: (), createdAt: [1760000000, 0], status: (), statusChangedAt: (),
        paidAt: (), coinReference: ()
    };
    json row = ledgerDtoForTeammate(adjustment);
    map<json> shown = <map<json>>row;
    test:assertFalse(shown.hasKey("actorId"), "the PO's employee id stays internal");
    test:assertEquals(shown["reason"], PO_ADJUSTMENT_LABEL, "a fixed label, never the PO's free text");
    test:assertEquals(shown["points"], -5);

    types:LedgerEntry reversal = adjustment.clone();
    reversal.sourceType = types:REVERSAL;
    reversal.reversesReference = "AMP-1";
    test:assertEquals((<map<json>>ledgerDtoForTeammate(reversal))["reason"], PO_ADJUSTMENT_LABEL);

    types:LedgerEntry award = adjustment.clone();
    award.sourceType = types:ENGAGEMENT;
    award.reason = ();
    award.actorId = types:SYSTEM_ACTOR;
    test:assertEquals((<map<json>>ledgerDtoForTeammate(award))["reason"], ());

    // A PO still sees everything.
    map<json> forPo = <map<json>>ledgerDto(adjustment).toJson();
    test:assertEquals(forPo["actorId"], "po-0001");
    test:assertEquals(forPo["reason"], "Duplicate claim, HR looking at conduct");
}
