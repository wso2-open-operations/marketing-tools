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

// Novera seen counts (V023): the card's post id goes out as `reference` only when the switch is on, the broadcast
// id Novera returns is kept, and runs copy the counts for recent broadcasts without ever failing the run.

import amplify_common.events;
import amplify_common.types;
import amplify_domain.announcements;

import ballerina/test;
import ballerina/time;

function seenWorld(boolean enabled, announcements:NoveraStatsTarget[] due = [], int batch = 20)
        returns [World, MemNoveraStats] {
    World w = harness();
    RunConfig cfg = {...TEST_CONFIG};
    cfg.noveraSeenStatsEnabled = enabled;
    cfg.noveraStatsBatch = batch;
    w.deps.config = cfg;
    MemNoveraStats stats = new (due);
    w.deps.noveraStats = stats;
    return [w, stats];
}

@test:Config
function referenceIsSentOnlyWhenSeenCountsAreOn() returns error? {
    // Off: an older Novera refuses unknown fields, so the card goes out exactly as before.
    var [off, _] = seenWorld(false);
    string cid = types:newUuidV7();
    off.mem.putCampaign(openCampaign(cid, time:utcNow()));
    _ = off.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    _ = check run(off);
    test:assertEquals(off.novera.sent(), 1);
    test:assertEquals(off.novera.reference(), (), "no reference while the switch is off");

    var [enabled, _] = seenWorld(true);
    string cid2 = types:newUuidV7();
    enabled.mem.putCampaign(openCampaign(cid2, time:utcNow()));
    _ = enabled.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid2));
    _ = check run(enabled);
    test:assertEquals(enabled.novera.reference(), cid2, "the post id is the reference");
}

@test:Config
function theBroadcastIdNoveraReturnsIsKeptWithTheSentAnnouncement() returns error? {
    var [w, _] = seenWorld(true);
    w.novera.returnId("0b9a7c1e-1f2d-4c3b-9a8e-7d6c5b4a3f21");
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    announcements:Announcement? a = check w.mem.announcement(cid);
    test:assertTrue(a is announcements:Announcement && a.sentAt !is ());
    if a is announcements:Announcement {
        test:assertEquals(a.noveraNotificationId, "0b9a7c1e-1f2d-4c3b-9a8e-7d6c5b4a3f21");
    }
}

@test:Config
function anOlderNoveraWithoutAnIdStillAnnounces() returns error? {
    var [w, _] = seenWorld(true);
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE", "no id is not a failure");
    announcements:Announcement? a = check w.mem.announcement(cid);
    test:assertTrue(a is announcements:Announcement && a.sentAt !is () && a.noveraNotificationId is ());
}

@test:Config
function aRunCopiesTheDueCountsAndKeepsGoingPastAnswersForOneBroadcast() returns error? {
    var [w, stats] = seenWorld(true, [
        {campaignId: "c1", notificationId: "n1"},
        {campaignId: "c2", notificationId: "n2"},
        {campaignId: "c3", notificationId: "n3"},
        {campaignId: "c4", notificationId: "n4"}
    ]);
    w.novera.setStats("n1", {recipients: 900, seen: 312});
    w.novera.setStats("n2", "NOT_FOUND");
    w.novera.setStats("n3", "500");
    w.novera.setStats("n4", "BAD_RESPONSE");
    RunReport r = check run(w);
    test:assertEquals(r.noveraStats, 1, "one count saved");
    test:assertEquals(w.novera.statsCalls(), ["n1", "n2", "n3", "n4"], "a 500 for one broadcast doesn't stop the rest");
    test:assertEquals(stats.savedIds(), ["c1", "c2", "c4"], "unknown and unreadable keep the time; a 500 is retried");
    test:assertEquals(stats.savedFor("c1"), {recipients: 900, seen: 312});
    test:assertEquals(stats.savedFor("c2"), ());
    test:assertEquals(stats.query(), [14, 10800, 20], "window, refresh interval and batch come from the config");
}

@test:Config
function noveraUnreachableOrRefusingStopsTheBatch() returns error? {
    foreach string mode in ["down", "503", "429", "401"] {
        var [w, stats] = seenWorld(true, [{campaignId: "a", notificationId: "na"}, {campaignId: "b", notificationId: "nb"}]);
        w.novera.setStats("na", mode);
        w.novera.setStats("nb", {recipients: 10, seen: 1});
        RunReport r = check run(w);
        test:assertEquals(r.noveraStats, 0, mode);
        test:assertEquals(w.novera.statsCalls(), ["na"], string `${mode} stops the batch`);
        test:assertEquals(stats.savedIds().length(), 0, mode);
    }
}

@test:Config
function seenCountsAreOffByDefaultAndTheBatchIsCapped() returns error? {
    var [off, offStats] = seenWorld(false, [{campaignId: "c1", notificationId: "n1"}]);
    RunReport r = check run(off);
    test:assertEquals(r.noveraStats, 0);
    test:assertEquals(off.novera.statsCalls().length(), 0, "nothing asked while the switch is off");
    test:assertEquals(offStats.query().length(), 0);

    var [capped, cappedStats] = seenWorld(true, [
        {campaignId: "c1", notificationId: "n1"}, {campaignId: "c2", notificationId: "n2"},
        {campaignId: "c3", notificationId: "n3"}
    ], batch = 2);
    capped.novera.setStats("n1", {recipients: 5, seen: 5});
    capped.novera.setStats("n2", {recipients: 5, seen: 0});
    capped.novera.setStats("n3", {recipients: 5, seen: 1});
    RunReport c = check run(capped);
    test:assertEquals(c.noveraStats, 2);
    test:assertEquals(cappedStats.query()[2], 2, "the due list asks for the batch size");
}

@test:Config
function aSeenCountProblemNeverFailsTheRun() returns error? {
    var [w, stats] = seenWorld(true, [{campaignId: "c1", notificationId: "n1"}]);
    stats.failDueList();
    RunReport|RunSkipped|error r = runOnce(w.deps, "corr-seen");
    test:assertTrue(r is RunReport, "the run finishes");
    if r is RunReport {
        test:assertEquals(r.noveraStats, 0);
    }
    // Without Novera configured nothing is asked either.
    var [noNovera, _] = seenWorld(true, [{campaignId: "c1", notificationId: "n1"}]);
    noNovera.deps.novera = ();
    RunReport n = check run(noNovera);
    test:assertEquals(n.noveraStats, 0);
}

@test:Config
function seenCountSettingsAreCheckedAtStartUp() {
    RunConfig cfg = {...TEST_CONFIG};
    test:assertEquals(validateRunConfig(cfg, 10), ());
    cfg.noveraStatsWindowDays = 0;
    test:assertTrue(validateRunConfig(cfg, 10) is error);
    cfg = {...TEST_CONFIG};
    cfg.noveraStatsRefreshSeconds = 30;
    test:assertTrue(validateRunConfig(cfg, 10) is error);
    cfg = {...TEST_CONFIG};
    cfg.noveraStatsBatch = -1;
    test:assertTrue(validateRunConfig(cfg, 10) is error);
}
