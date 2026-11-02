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

// Write endpoints the endpoint tests don't reach: PATCH optimistic locking (incl. the read-then-update
// race), archive, share kill switch and archived campaigns, point-rule / adjustment / reversal validation,
// announcement retry, settings version conflict, and SchedulerSync reading committed settings.

import amplify_api.scheduler;
import amplify_domain.announcements;
import amplify_domain.store;

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

function registered(string urn, string token) returns string|error {
    http:Response res = check send("POST", "/campaigns", registerBody(urn), token);
    test:assertEquals(res.statusCode, 201, urn);
    return (check (check res.getJsonPayload()).campaign.id).toString();
}

// ---- PATCH / DELETE /campaigns/{id} ---------------------------------------------------------------------

@test:Config {groups: ["writes"]}
function testPatchLosesNoConcurrentEdit() returns error? {
    string token = check po();
    string id = check registered("urn:li:share:9101", token);
    // Another editor commits between the version check and the update.
    fakeCampaigns.bumpAfterNextRead(id);
    http:Response raced = check send("PATCH", "/campaigns/" + id, {version: 1, title: "Mine"}, token);
    test:assertEquals(raced.statusCode, 409, "the edit committed in between must not be overwritten");
    test:assertEquals(check codeIn(raced), "VERSION_CONFLICT");
    http:Response current = check send("GET", "/campaigns/" + id, (), token);
    test:assertEquals(check (check current.getJsonPayload()).title, "Changed by someone else");

    http:Response stale = check send("PATCH", "/campaigns/" + id, {version: 1, title: "Mine"}, token);
    test:assertEquals(stale.statusCode, 409);
    http:Response ok = check send("PATCH", "/campaigns/" + id, {version: 2, title: "Mine", tags: ["A"]}, token);
    test:assertEquals(ok.statusCode, 200);
    check assertShape(ok, "Campaign");
    check assertStandardJson(ok);
    test:assertEquals(check (check ok.getJsonPayload()).version, 3);
}

@test:Config {groups: ["writes"]}
function testPatchValidationAndArchive() returns error? {
    string token = check mint({sub: "mkt-0001", email: "mkt@wso2.com", groups: [MARKETING_GROUP]});
    string id = check registered("urn:li:share:9102", token);
    string[] many = from int i in 0 ..< 21 select string `t${i}`;
    [json, int, string][] cases = [
        [{version: 1, tags: many}, 400, "VALIDATION_FAILED"],
        [{version: 1, summary: "s".padEnd(2001, "s")}, 400, "VALIDATION_FAILED"],
        [{version: 1, opensAt: "yesterday"}, 400, "VALIDATION_FAILED"],
        [{version: 1, categoryCode: "NOPE"}, 422, "INVALID_CAMPAIGN"],
        [{version: 1, title: ""}, 422, "INVALID_CAMPAIGN"],
        [{version: 1, opensAt: "2026-10-20T00:00:00Z", closesAt: "2026-10-19T00:00:00Z"}, 422, "INVALID_WINDOW"],
        [{version: 1, hack: 1}, 400, "VALIDATION_FAILED"]
    ];
    foreach [json, int, string] [body, status, code] in cases {
        http:Response res = check send("PATCH", "/campaigns/" + id, body, token);
        test:assertEquals(res.statusCode, status, body.toJsonString());
        test:assertEquals(check codeIn(res), code, body.toJsonString());
    }
    test:assertEquals((check send("PATCH", "/campaigns/" + SAMPLE_UUID, {version: 1}, token)).statusCode, 404);
    test:assertEquals((check send("PATCH", "/campaigns/nope", {version: 1}, token)).statusCode, 400);

    http:Response archived = check send("DELETE", "/campaigns/" + id, (), token);
    test:assertEquals(archived.statusCode, 200);
    test:assertEquals(check (check archived.getJsonPayload()).status, "ARCHIVED");
    http:Response again = check send("DELETE", "/campaigns/" + id, (), token);
    test:assertEquals(check codeIn(again), "CAMPAIGN_ARCHIVED");
    http:Response edit = check send("PATCH", "/campaigns/" + id, {version: 2, title: "x"}, token);
    test:assertEquals(check codeIn(edit), "CAMPAIGN_ARCHIVED");
    test:assertEquals((check send("DELETE", "/campaigns/" + SAMPLE_UUID, (), token)).statusCode, 404);

    // Employees never see an archived campaign; editors do.
    string emp = check employee("emp-arch-1");
    connect("emp-arch-1");
    test:assertEquals((check send("GET", "/campaigns/" + id, (), emp)).statusCode, 404);
    test:assertEquals((check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"}, emp)).statusCode, 404);
    test:assertEquals((check send("GET", "/campaigns/" + id, (), token)).statusCode, 200);
    http:Response editorShare = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"},
            check mint({sub: "emp-arch-1", email: "emp-arch-1@wso2.com", groups: [MARKETING_GROUP]}));
    test:assertEquals(check codeIn(editorShare), "CAMPAIGN_CLOSED");
}

@test:Config {groups: ["writes"]}
function testRegisterValidation() returns error? {
    string token = check po();
    string[] many = from int i in 0 ..< 21 select string `t${i}`;
    [json, int, string][] cases = [
        [{resourceUrn: "urn:li:share:9110", ownerUrn: WSO2_PAGE, title: "t", categoryCode: "PRODUCT", tags: many}, 400,
            "VALIDATION_FAILED"],
        [{resourceUrn: "urn:li:share:9111", ownerUrn: WSO2_PAGE, title: "t", categoryCode: "PRODUCT",
            summary: "s".padEnd(2001, "s")}, 400, "VALIDATION_FAILED"],
        [{resourceUrn: "urn:li:share:9112", ownerUrn: WSO2_PAGE, title: "t", categoryCode: "NOPE"}, 422,
            "INVALID_CAMPAIGN"],
        [{resourceUrn: "not-an-urn", ownerUrn: WSO2_PAGE, title: "t", categoryCode: "PRODUCT"}, 422, "INVALID_POST_URN"],
        [{resourceUrn: "urn:li:share:9113", ownerUrn: WSO2_PAGE, title: "t", categoryCode: "PRODUCT",
            imageUrl: "http://insecure.example/x.png"}, 422, "INVALID_CAMPAIGN"]
    ];
    foreach [json, int, string] [body, status, code] in cases {
        http:Response res = check send("POST", "/campaigns", body, token);
        test:assertEquals(res.statusCode, status, body.toJsonString());
        test:assertEquals(check codeIn(res), code, body.toJsonString());
    }
}

// ---- Shares ------------------------------------------------------------------------------------------

@test:Config {groups: ["writes"]}
function testShareKillSwitch() returns error? {
    string id = check registered("urn:li:share:9120", check po());
    string emp = check employee("emp-kill-1");
    connect("emp-kill-1");
    setSetting("sharing.enabled", false);
    http:Response paused = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"}, emp);
    clearSettings();
    test:assertEquals(paused.statusCode, 409);
    test:assertEquals(check codeIn(paused), "FEATURE_DISABLED");
    http:Response commentary = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST_COMMENTARY"}, emp);
    test:assertEquals(check codeIn(commentary), "COMMENTARY_REQUIRED");
    http:Response queued = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"}, emp);
    test:assertEquals(queued.statusCode, 202);
}

// ---- C2 scoring ---------------------------------------------------------------------------------------

@test:Config {groups: ["writes"]}
function testScoringValidation() returns error? {
    string token = check po();
    [string, string, json, int, string][] cases = [
        ["POST", "/po/point-rules", {action: "LIKE", points: 5}, 400, "VALIDATION_FAILED"],
        ["POST", "/po/point-rules", {action: "REPOST", points: 10001}, 400, "VALIDATION_FAILED"],
        ["POST", "/po/point-rules", {action: "REPOST", points: -1}, 422, "INVALID_POINTS"],
        ["POST", "/po/point-rules", {action: "REPOST", points: 5, effectiveFrom: "soon"}, 400, "VALIDATION_FAILED"],
        ["POST", "/po/points/adjustments", {employeeId: "x", points: 0, reason: "r"}, 404, "NOT_FOUND"],
        ["POST", "/po/points/adjustments", {employeeId: "x", points: 20000, reason: "r"}, 400, "VALIDATION_FAILED"],
        ["POST", "/po/points/adjustments", {employeeId: "x", points: 5, reason: "r".padEnd(1001, "r")}, 400,
            "VALIDATION_FAILED"],
        ["POST", "/po/points/adjustments", {employeeId: "bad id", points: 5, reason: "r"}, 422, "INVALID_EMPLOYEE_ID"],
        ["POST", "/po/points/not-a-reference/reverse", {reason: "r"}, 422, "INVALID_LEDGER_REFERENCE"],
        ["POST", "/po/points/ADJ:x:1/reverse", {reason: "r".padEnd(1001, "r")}, 400, "VALIDATION_FAILED"],
        ["POST", "/po/external-shares/nope/approve", (), 400, "VALIDATION_FAILED"],
        ["POST", "/po/external-shares/" + SAMPLE_UUID + "/approve", (), 404, "NOT_FOUND"]
    ];
    foreach [string, string, json, int, string] [method, path, body, status, code] in cases {
        http:Response res = check send(method, path, body, token);
        test:assertEquals(res.statusCode, status, string `${path} ${body.toJsonString()}`);
        test:assertEquals(check codeIn(res), code, string `${path} ${body.toJsonString()}`);
    }
    _ = check send("GET", "/me", (), check employee("emp-zero-1"));
    http:Response zero = check send("POST", "/po/points/adjustments", {employeeId: "emp-zero-1", points: 0, reason: "r"},
            token);
    test:assertEquals(check codeIn(zero), "INVALID_POINTS");
    http:Response added = check send("POST", "/po/point-rules", {action: "REPOST", points: 7}, token);
    test:assertEquals(added.statusCode, 201);
    check assertShape(added, "PointRule");
    check assertStandardJson(added);
}

@test:Config {groups: ["writes"]}
function testSelfReviewIsForbidden() returns error? {
    string token = check po();
    http:Response claimed = check send("POST", "/external-shares",
            {evidenceUrl: "https://dev.to/po/own-claim", certified: true}, token);
    test:assertEquals(claimed.statusCode, 201);
    string id = (check (check claimed.getJsonPayload()).id).toString();
    http:Response self = check send("POST", string `/po/external-shares/${id}/approve`, (), token);
    test:assertEquals(self.statusCode, 403);
    test:assertEquals(check codeIn(self), "SELF_REVIEW");
}

// ---- Announcements -----------------------------------------------------------------------------------

@test:Config {groups: ["writes"]}
function testAnnouncementRetry() returns error? {
    string failedId = "01900000-0000-7000-8000-0000000000b1";
    fakeAnnouncements.put({campaignId: failedId, outboxId: 1, space: "club", threadKey: "campaign-b1",
        chatMessageName: (), queuedAt: [1760000000, 0], sentAt: (), failedAt: [1760000100, 0], lastError: "HTTP 500"});
    string admin = check mint({sub: "adm-ann", email: "adm-ann@wso2.com", groups: [ADMIN_GROUP]});
    http:Response list = check send("GET", "/admin/announcements", (), admin);
    test:assertEquals(list.statusCode, 200);
    check assertShape(list, "AnnouncementList");

    setSetting("announcements.enabled", false);
    http:Response paused = check send("POST", string `/admin/announcements/${failedId}/retry`, (), admin);
    clearSettings();
    test:assertEquals(check codeIn(paused), "FEATURE_DISABLED");

    http:Response retried = check send("POST", string `/admin/announcements/${failedId}/retry`, (), admin);
    test:assertEquals(retried.statusCode, 202);
    check assertShape(retried, "Announcement");
    test:assertEquals(check (check retried.getJsonPayload()).status, "QUEUED");
    http:Response twice = check send("POST", string `/admin/announcements/${failedId}/retry`, (), admin);
    test:assertEquals(twice.statusCode, 409);
    test:assertEquals(check codeIn(twice), "ANNOUNCEMENT_NOT_FAILED");
    test:assertEquals((check send("POST", string `/admin/announcements/${SAMPLE_UUID}/retry`, (), admin)).statusCode, 404);
    test:assertEquals((check send("POST", "/admin/announcements/nope/retry", (), admin)).statusCode, 400);
    _ = announcements:QUEUED;
}

// ---- Settings ------------------------------------------------------------------------------------------

@test:Config {groups: ["writes", "scheduler"]}
function testSettingsVersionConflictIs409() returns error? {
    resetSync();
    setSaveConflicts(true);
    http:Response res = check putSetting("run.schedule", "*/15 * * * *");
    setSaveConflicts(false);
    test:assertEquals(res.statusCode, 409);
    test:assertEquals(check codeIn(res), "VERSION_CONFLICT");
    test:assertEquals(takeEvents(), [], "a refused save pushes nothing");

    [json, int, string][] cases = [
        [{changes: []}, 400, "VALIDATION_FAILED"],
        [{changes: [{key: "team.visibility", value: "EVERYONE", version: 1}]}, 422, "INVALID_SETTING"],
        [{changes: [{key: "sharing.enabled", value: "yes", version: 1}]}, 422, "INVALID_SETTING"],
        [{changes: [{key: "leaderboard.top_n", value: 2.5, version: 1}]}, 422, "INVALID_SETTING"],
        [{changes: [{key: "leaderboard.top_n", value: 3}]}, 400, "VALIDATION_FAILED"]
    ];
    string admin = check adminToken();
    foreach [json, int, string] [body, status, code] in cases {
        http:Response bad = check send("PUT", "/admin/settings", body, admin);
        test:assertEquals(bad.statusCode, status, body.toJsonString());
        test:assertEquals(check codeIn(bad), code, body.toJsonString());
    }
}

@test:Config {groups: ["writes", "scheduler"]}
function testSyncPushesCommittedSettingsNotTheCache() returns error? {
    resetSync();
    readonly & store:Setting row = {key: "run.schedule", value: "*/7 * * * *", version: 2, updatedBy: "adm",
        updatedAt: [1760000000, 0]};
    lock {
        fakeSettingRows = [row];
    }
    // A reader cached the rows from just before the commit (the cache is off in tests, so plant it).
    readonly & Settings stale = {runSchedule: "@every 5m"};
    decimal later = time:monotonicNow() + 3600d;
    lock {
        settingsCache.entry = [stale, later];
    }
    SchedulerSyncResult result = syncScheduler((), "test-fresh");
    forgetSettings();
    test:assertEquals(result.status, "SYNCED");
    scheduler:JobSpec run = check fakeScheduler.job(JOB_RUN).ensureType();
    test:assertEquals(run.schedule, "*/7 * * * *", "the push reads the committed rows, never the cache");
}

@test:Config {groups: ["writes"]}
function testSettingsReadBeforeASaveIsNotCached() returns error? {
    forgetSettings();
    int generation;
    lock {
        generation = settingsCache.generation;
    }
    readonly & Settings old = {topN: 9};
    // The read started, then this replica saved (forgetSettings), then the read finished.
    forgetSettings();
    cacheSettings(old, time:monotonicNow(), generation);
    lock {
        test:assertTrue(settingsCache.entry is (), "pre-commit rows never land in the cache after a save");
    }
    int now;
    lock {
        now = settingsCache.generation;
    }
    cacheSettings(old, time:monotonicNow(), now);
    lock {
        test:assertTrue(settingsCache.entry !is ());
    }
    forgetSettings();
    runtime:sleep(0.01);
}

// An employee's share on a campaign that is not open (scheduled or closed) is a 404, the same answer as
// `GET /campaigns/{id}`, so the route does not confirm the id exists. An editor still gets the specific 409
// CAMPAIGN_CLOSED (checked at the end of the archived-campaign test above). Pinned on purpose.
@test:Config {groups: ["writes"]}
function testShareOnNonOpenCampaignIsNotFoundForAnEmployee() returns error? {
    string token = check po();
    string emp = check employee("emp-closed-1");
    connect("emp-closed-1");
    map<json> scheduled = <map<json>>registerBody("urn:li:share:9130").clone();
    scheduled["opensAt"] = "2999-01-01T00:00:00Z";
    scheduled["closesAt"] = "2999-02-01T00:00:00Z";
    map<json> closed = <map<json>>registerBody("urn:li:share:9131").clone();
    closed["opensAt"] = "2020-01-01T00:00:00Z";
    closed["closesAt"] = "2020-02-01T00:00:00Z";
    foreach json body in [scheduled, closed] {
        http:Response created = check send("POST", "/campaigns", body, token);
        test:assertEquals(created.statusCode, 201, body.toJsonString());
        string id = (check (check created.getJsonPayload()).campaign.id).toString();
        http:Response res = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"}, emp);
        test:assertEquals(res.statusCode, 404, body.toJsonString());
        string editorToken = check mint({sub: "emp-closed-1", email: "emp-closed-1@wso2.com", groups: [MARKETING_GROUP]});
        http:Response asEditor = check send("POST", string `/campaigns/${id}/shares`, {kind: "REPOST"}, editorToken);
        test:assertEquals(check codeIn(asEditor), "CAMPAIGN_CLOSED", body.toJsonString());
    }
}
// ---- PATCH /campaigns/{id}: post link and id ------------------------------------------------------------

@test:Config {groups: ["writes"]}
function testPatchPostLinkAndIdValidation() returns error? {
    string token = check po();
    string id = check registered("urn:li:share:9201", token);
    string longLink = "https://www.linkedin.com/" + "a".padEnd(2100, "a");
    [json, int, string][] cases = [
        [{version: 1, resourceUrn: "urn:li:person:abc"}, 422, "INVALID_POST_URN"],
        [{version: 1, resourceUrn: "https://www.linkedin.com/feed/update/urn:li:share:1"}, 422, "INVALID_POST_URN"],
        [{version: 1, resourceUrn: "urn:li:share:" + "1".padEnd(300, "1")}, 400, "VALIDATION_FAILED"],
        [{version: 1, resourceUrl: "https://evil.example/post"}, 422, "INVALID_CAMPAIGN"],
        [{version: 1, resourceUrl: longLink}, 400, "VALIDATION_FAILED"],
        [{version: 1, resourceUrl: 5}, 400, "VALIDATION_FAILED"]
    ];
    foreach [json, int, string] [body, status, code] in cases {
        http:Response res = check send("PATCH", "/campaigns/" + id, body, token);
        string label = body.toJsonString().substring(0, int:min(80, body.toJsonString().length()));
        test:assertEquals(res.statusCode, status, label);
        test:assertEquals(check codeIn(res), code, label);
    }
}

@test:Config {groups: ["writes"]}
function testPatchPostIdFrozenByActivityLinkStillEditable() returns error? {
    string token = check po();
    string id = check registered("urn:li:share:9202", token);
    string other = check registered("urn:li:share:9203", token);

    // No activity: both change, the version moves once.
    http:Response ok = check send("PATCH", "/campaigns/" + id, {version: 1, resourceUrn: "urn:li:ugcPost:9300",
            resourceUrl: "https://www.linkedin.com/feed/update/urn:li:ugcPost:9300"}, token);
    test:assertEquals(ok.statusCode, 200);
    check assertShape(ok, "Campaign");
    json body = check ok.getJsonPayload();
    test:assertEquals(check body.resourceUrn, "urn:li:ugcPost:9300");
    test:assertEquals(check body.resourceUrl, "https://www.linkedin.com/feed/update/urn:li:ugcPost:9300");
    test:assertEquals(check body.version, 2);

    // Another campaign's post id: the registration conflict, and it doesn't name the campaign.
    http:Response clash = check send("PATCH", "/campaigns/" + id, {version: 2, resourceUrn: "urn:li:share:9203"}, token);
    test:assertEquals(clash.statusCode, 409);
    test:assertEquals(check codeIn(clash), "CAMPAIGN_ALREADY_REGISTERED");
    test:assertFalse((check clash.getTextPayload()).includes(other));

    // With a share recorded: the id is frozen, the link is not.
    fakeCampaigns.markActive(id);
    http:Response frozen = check send("PATCH", "/campaigns/" + id, {version: 2, resourceUrn: "urn:li:share:9400"}, token);
    test:assertEquals(frozen.statusCode, 409);
    test:assertEquals(check codeIn(frozen), "POST_HAS_ACTIVITY");
    http:Response linkOnly = check send("PATCH", "/campaigns/" + id,
            {version: 2, resourceUrl: "https://www.linkedin.com/posts/wso2_edited"}, token);
    test:assertEquals(linkOnly.statusCode, 200);
    test:assertEquals(check (check linkOnly.getJsonPayload()).resourceUrn, "urn:li:ugcPost:9300");
    test:assertEquals(check (check linkOnly.getJsonPayload()).version, 3);
}
