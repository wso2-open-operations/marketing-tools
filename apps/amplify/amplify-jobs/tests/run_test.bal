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

// Unit tests for the Run (in-memory ports): backoff, dispatch, each handler, rerun safety, one run at a time.

import amplify_common.crypto;
import amplify_common.events;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.sharing;

import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

type World record {|
    MemRunStore queue;
    MemStore mem;
    FakeNovera novera;
    FakeLinkedIn linkedIn;
    crypto:TokenCipher cipher;
    Deps deps;
|};

function harness(boolean lockFree = true) returns World {
    MemRunStore queue = new;
    FakeNovera novera = new;
    FakeLinkedIn linkedIn = new;
    crypto:TokenCipher cipher = checkpanic testCipher();
    MemStore mem = new (queue);
    queue.attach(mem);
    mem.putRules(repostRule(time:utcNow()));
    return {queue, mem, novera, linkedIn, cipher, deps: {runStore: queue, runLock: new MemLock(lockFree), novera,
        linkedIn, cipher, config: TEST_CONFIG, breakers: noBreakers}};
}

function run(World w) returns RunReport|error {
    RunReport|RunSkipped result = check runOnce(w.deps, "corr-test");
    if result is RunSkipped {
        return error("run was skipped");
    }
    return result;
}

function registered(string campaignId) returns json => {campaignId, provider: "linkedin",
    resourceUrn: "urn:li:share:1000000000000000001", title: "T", isPriority: false, shareNow: true,
    opensAt: "2026-10-01T00:00:00Z"};

function repostRequested(string shareId, string campaignId, string employeeId, int attempts = 1) returns json => {
    shareRequestId: shareId, campaignId, employeeId, kind: types:REPOST_COMMENTARY,
    targetResourceUrn: "urn:li:share:1000000000000000001", attempts};

// ---- backoff ---------------------------------------------------------------------------------------

@test:Config
function backoffDoublesWithEqualJitterAndCaps() {
    test:assertEquals(backoffSeconds(1, 30, 3600, 0.0), 15d);
    test:assertEquals(backoffSeconds(1, 30, 3600, 0.5), 22.5d);
    test:assertEquals(backoffSeconds(3, 30, 3600, 0.0), 60d, "30 * 2^2 / 2");
    test:assertEquals(backoffSeconds(30, 30, 3600, 0.0), 1800d, "capped at max, half fixed");
    decimal random = backoffSeconds(2, 30, 3600);
    test:assertTrue(random >= 30d && random <= 60d);
}

// ---- dispatch ------------------------------------------------------------------------------------

@test:Config
function eventsWithoutSubscriberAndApiScoredEventsAreDone() returns error? {
    World w = harness();
    int approved = w.queue.enqueue(events:EXTERNAL_SHARE_APPROVED, {externalShareId: "x"});
    int other = w.queue.enqueue(events:CONNECTION_READY, {});
    RunReport r = check run(w);
    test:assertEquals(r.succeeded, 2);
    test:assertEquals(w.queue.statusOf(approved)[0], "DONE");
    test:assertEquals(w.queue.statusOf(other)[0], "DONE");
    test:assertEquals(w.mem.ledgerSize(), 0, "jobs never re-awards an approval (ADR-024)");
}

@test:Config
function badPayloadRetriesThenFails() returns error? {
    World w = harness();
    int id = w.queue.enqueue(events:REPOST_REQUESTED, {nonsense: true});
    foreach int i in 1 ... TEST_CONFIG.maxAttempts {
        _ = check run(w);
        w.queue.makeAllDue();
    }
    [string, int, string?] [status, attempts, _] = w.queue.statusOf(id);
    test:assertEquals(status, "FAILED");
    test:assertEquals(attempts, TEST_CONFIG.maxAttempts);
}

// ---- CampaignRegistered ------------------------------------------------------------------------------

@test:Config
function campaignRegisteredSendsOneCardEvenWhenRedelivered() returns error? {
    World w = harness();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid), "corr-campaign");
    RunReport r = check run(w);
    test:assertEquals(w.novera.sent(), 1);
    test:assertEquals(w.novera.correlation(), "corr-campaign", "correlation id reaches the Novera call");
    test:assertEquals(w.novera.idempotencyKey(), "amplify:" + cid, "the same key goes out on every attempt");
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    test:assertEquals(w.queue.countByType(events:CAMPAIGN_ANNOUNCED), 1);
    test:assertTrue(r.succeeded >= 1);
    var a = check w.mem.announcement(cid);
    test:assertTrue(a !is () && a.sentAt !is () && a.idempotencyKey == "amplify:" + cid
        && a.messageName == "novera:" + cid && a.space == "novera");

    w.queue.redeliver(id);
    _ = check run(w);
    test:assertEquals(w.novera.sent(), 1, "rerun never announces twice");
}

@test:Config
function campaignRegisteredRetriesOn429AndFailsAfterMaxAttempts() returns error? {
    World w = harness();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    w.novera.setMode("429");
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    RunReport first = check run(w);
    test:assertEquals(first.retried, 1);
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING");
    foreach int i in 2 ... TEST_CONFIG.maxAttempts {
        w.queue.makeAllDue();
        _ = check run(w);
    }
    test:assertEquals(w.queue.statusOf(id)[0], "FAILED");
    var a = check w.mem.announcement(cid);
    test:assertTrue(a !is () && a.failedAt !is (), "announcement FAILED for the admin retry");

    // Admin retry re-queues the row (attempts reset); the next good send clears failed_at.
    w.novera.setMode("ok");
    w.queue.adminRetry(id);
    _ = check run(w);
    var sent = check w.mem.announcement(cid);
    test:assertTrue(sent !is () && sent.sentAt !is () && sent.failedAt is ());
}

@test:Config
function campaignRegisteredDefersWhenOffOrNotOpen() returns error? {
    World w = harness();
    string later = types:newUuidV7();
    w.mem.putCampaign(openCampaign(later, time:utcNow(), 7200));
    int scheduled = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(later));
    RunReport r = check run(w);
    test:assertEquals(r.deferred, 1);
    test:assertEquals(w.queue.statusOf(scheduled), ["PENDING", 0, "campaign not open yet"]);

    w.mem.setSettings({announcementsEnabled: false});
    string now = types:newUuidV7();
    w.mem.putCampaign(openCampaign(now, time:utcNow()));
    int off = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(now));
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(off)[0], "PENDING");
    test:assertEquals(w.novera.sent(), 0);
}

// ---- RepostRequested → EngagementRecorded → points ---------------------------------------------------

@test:Config
function repostPublishesOnceRecordsEngagementAndScoresOnce() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    var share = queuedShare(cid, "emp-1", now);
    w.mem.putShare(share);
    check connectedEmployee(w.mem, w.cipher, "emp-1", now);
    int first = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-1"), "corr-share");
    int duplicate = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-1"), "corr-share");

    RunReport r = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1, "two deliveries, one post");
    [string?, string?, string?] [bearer, commentary, corr] = w.linkedIn.last();
    test:assertEquals(bearer, "bearer-emp-1", "token decrypted in memory for the call");
    test:assertEquals(commentary, "Proud of the team");
    test:assertEquals(corr, "corr-share");
    test:assertEquals(r.linkedinPosts, 1);
    var published = check w.mem.share(cid, "emp-1");
    test:assertTrue(published !is () && published.publishedAt !is () && published.commentary is (),
            "published, commentary cleared");
    test:assertEquals(w.mem.engagementCount(), 1);
    test:assertEquals(w.mem.ledgerSize(), 1, "EngagementRecorded scored in the same run");
    test:assertEquals(w.mem.ledgerPoints(), 20);
    test:assertEquals(w.queue.statusOf(first)[0], "DONE");
    test:assertEquals(w.queue.statusOf(duplicate)[0], "DONE");

    // Second run over a redelivered outbox: no second post, no second ledger row.
    w.queue.redeliver(first);
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1);
    test:assertEquals(w.mem.ledgerSize(), 1);
}

@test:Config
function linkedIn401RevokesConnectionAndFailsShare() returns error? {
    check rejectedTokenForcesRelink("401", "emp-401");
}

@test:Config
function linkedIn403RevokesConnectionAndFailsShare() returns error? {
    check rejectedTokenForcesRelink("403", "emp-403");
}

# LinkedIn refuses the token: the connection is revoked, its token row deleted, this share and the employee's
# other queued shares fail NEEDS_RECONNECT (through ConnectionRevoked), and nothing is retried.
function rejectedTokenForcesRelink(string mode, string emp) returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    string otherCid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    w.mem.putCampaign(openCampaign(otherCid, now));
    var share = queuedShare(cid, emp, now);
    w.mem.putShare(share);
    // A second share of the same employee, queued but not yet picked up (its RepostRequested row is later).
    w.mem.putShare(queuedShare(otherCid, emp, now));
    check connectedEmployee(w.mem, w.cipher, emp, now);
    var before = check w.mem.connection(emp);
    string tokenId = before is () ? "" : (<connection:TokenRef>before.currentToken).tokenId;
    w.linkedIn.setMode(mode);
    int id = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, emp));
    _ = check run(w);
    w.queue.makeAllDue();
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE", mode);
    var conn = check w.mem.connection(emp);
    test:assertTrue(conn !is () && conn.revokedAt !is () && conn.currentToken is (), mode + ": revoked, no token");
    test:assertTrue(conn !is () && connection:connectionStatus(conn, now) == connection:NEEDS_RECONNECT, mode);
    test:assertFalse(w.mem.hasToken(tokenId), mode + ": the stored token row is deleted");
    var failedShare = check w.mem.share(cid, emp);
    test:assertTrue(failedShare !is () && failedShare.failureReason == types:NEEDS_RECONNECT, mode);
    var otherShare = check w.mem.share(otherCid, emp);
    test:assertTrue(otherShare !is () && otherShare.failureReason == types:NEEDS_RECONNECT,
            mode + ": the other queued share fails through ConnectionRevoked");
    test:assertEquals(w.queue.countByType(events:CONNECTION_REVOKED), 1, mode);
    test:assertEquals(w.queue.countByType(events:REPOST_FAILED), 2, mode);
    test:assertEquals(w.linkedIn.postCount(), 0, mode);
}

@test:Config
function other403FailsTheShareAndKeepsTheConnection() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    string otherCid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    w.mem.putCampaign(openCampaign(otherCid, now));
    sharing:ShareRequest share = queuedShare(cid, "emp-403o", now);
    w.mem.putShare(share);
    w.mem.putShare(queuedShare(otherCid, "emp-403o", now));
    check connectedEmployee(w.mem, w.cipher, "emp-403o", now);
    var before = check w.mem.connection("emp-403o");
    string tokenId = before is () ? "" : (<connection:TokenRef>before.currentToken).tokenId;
    w.linkedIn.setMode("403-other");
    int id = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-403o"));
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    var failedShare = check w.mem.share(cid, "emp-403o");
    test:assertTrue(failedShare !is () && failedShare.failureReason == types:PROVIDER_REJECTED
            && failedShare.lastErrorCode == "100", "fails on LinkedIn's code, not NEEDS_RECONNECT");
    var conn = check w.mem.connection("emp-403o");
    test:assertTrue(conn !is () && conn.revokedAt is () && conn.currentToken !is (), "connection untouched");
    test:assertTrue(w.mem.hasToken(tokenId), "token row kept");
    test:assertEquals(w.queue.countByType(events:CONNECTION_REVOKED), 0);
    var otherShare = check w.mem.share(otherCid, "emp-403o");
    test:assertTrue(otherShare !is () && otherShare.failedAt is (), "the other queued share is left alone");
}

@test:Config
function sameRefusalForSeveralMembersHaltsPosting() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    w.linkedIn.setMode("403-other");
    string[] employees = ["emp-h1", "emp-h2", "emp-h3", "emp-h4"];
    foreach string emp in employees {
        sharing:ShareRequest share = queuedShare(cid, emp, now);
        w.mem.putShare(share);
        check connectedEmployee(w.mem, w.cipher, emp, now);
        _ = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, emp));
    }
    RunReport report = check run(w);
    foreach string emp in employees.slice(0, 2) {
        var refused = check w.mem.share(cid, emp);
        test:assertTrue(refused !is () && refused.failureReason == types:PROVIDER_REJECTED, emp);
    }
    // The third member refused the same way halts the run: that share and the next stay queued, unfailed.
    foreach string emp in employees.slice(2) {
        var waiting = check w.mem.share(cid, emp);
        test:assertTrue(waiting !is () && waiting.failedAt is () && waiting.lastErrorCode is (), emp);
    }
    test:assertEquals(w.linkedIn.last()[0], "bearer-emp-h3", "the fourth share never called LinkedIn");
    test:assertEquals(report.deferred, 2);
    foreach string emp in employees {
        var conn = check w.mem.connection(emp);
        test:assertTrue(conn !is () && conn.revokedAt is (), emp + ": connection untouched");
    }
}

@test:Config
function mentionReadErrorRetriesWithoutMarkerOrBudget() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    sharing:ShareRequest share = queuedShare(cid, "emp-mx", now);
    share.commentary = "Thanks @[Jay](amplify:person:jane@wso2.com)";
    w.mem.putShare(share);
    check connectedEmployee(w.mem, w.cipher, "emp-mx", now);
    w.mem.putMentionable({employeeId: "jane@wso2.com", memberUrn: "urn:li:person:jane1", displayName: "Jane S",
        memberName: "Jane Smith"});
    w.mem.failNextMentionable();
    int id = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-mx"));
    RunReport first = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING", "retried");
    test:assertEquals(first.linkedinPosts, 0, "no budget slot used");
    test:assertEquals(w.linkedIn.postCount(), 0);
    var afterError = check w.mem.share(cid, "emp-mx");
    test:assertTrue(afterError !is () && afterError.lastErrorCode is () && afterError.failedAt is (),
            "no in-flight marker left behind");
    w.queue.makeAllDue();
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE", "the retry publishes");
    test:assertEquals(w.linkedIn.postCount(), 1);
}

@test:Config
function lateLostConnectionEventSkipsSharesQueuedAfterIt() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    time:Utc lostAt = time:utcAddSeconds(now, -600);
    string oldCid = types:newUuidV7();
    string newCid = types:newUuidV7();
    sharing:ShareRequest old = queuedShare(oldCid, "emp-late", time:utcAddSeconds(lostAt, -60));
    w.mem.putShare(old);
    // Queued after the loss (the employee re-linked, then the connection expired again before the event ran).
    w.mem.putShare(queuedShare(newCid, "emp-late", time:utcAddSeconds(lostAt, 60)));
    _ = w.queue.enqueue(events:CONNECTION_REVOKED, {employeeId: "emp-late", provider: "linkedin",
        memberUrn: "urn:li:person:emp-late", revokedAt: time:utcToString(lostAt)});
    _ = check run(w);
    var oldShare = check w.mem.share(oldCid, "emp-late");
    test:assertTrue(oldShare !is () && oldShare.failureReason == types:NEEDS_RECONNECT, "requested before: fails");
    var newShare = check w.mem.share(newCid, "emp-late");
    test:assertTrue(newShare !is () && newShare.failedAt is (), "requested after the loss: left alone");
}

@test:Config
function lostConnectionEventSkipsWhenTheConnectionIsUsableAgain() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putShare(queuedShare(cid, "emp-back", time:utcAddSeconds(now, -1200)));
    check connectedEmployee(w.mem, w.cipher, "emp-back", now);
    _ = w.queue.enqueue(events:CONNECTION_REMOVED, {employeeId: "emp-back", provider: "linkedin",
        memberUrn: "urn:li:person:emp-back", removedAt: time:utcToString(time:utcAddSeconds(now, -600))});
    _ = check run(w);
    var share = check w.mem.share(cid, "emp-back");
    test:assertTrue(share !is () && share.failedAt is (), "re-linked since: nothing fails");
}

@test:Config
function connectionRemovedFailsQueuedSharesButNotAnInFlightOne() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string queuedCid = types:newUuidV7();
    string inFlightCid = types:newUuidV7();
    w.mem.putShare(queuedShare(queuedCid, "emp-rm", now));
    sharing:ShareRequest inFlight = queuedShare(inFlightCid, "emp-rm", now);
    inFlight.lastErrorCode = PUBLISH_IN_FLIGHT;
    w.mem.putShare(inFlight);
    _ = w.queue.enqueue(events:CONNECTION_REMOVED, {employeeId: "emp-rm", provider: "linkedin",
        memberUrn: "urn:li:person:emp-rm", removedAt: time:utcToString(now)});
    _ = check run(w);
    var queued = check w.mem.share(queuedCid, "emp-rm");
    test:assertTrue(queued !is () && queued.failureReason == types:NEEDS_RECONNECT);
    var stillInFlight = check w.mem.share(inFlightCid, "emp-rm");
    test:assertTrue(stillInFlight !is () && stillInFlight.failedAt is (), "left for the manual-review path");
}

@test:Config
function mentionsResolveFromWhatAmplifyHolds() returns error? {
    World w = harness();
    RunConfig cfg = {...TEST_CONFIG};
    cfg.orgMentions = {"org:wso2": {name: "WSO2", urn: "urn:li:organization:1477"}};
    w.deps.config = cfg;
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    sharing:ShareRequest share = queuedShare(cid, "emp-m", now);
    share.commentary = "Thanks @[Jay](amplify:person:jane@wso2.com), @[Old](amplify:person:gone@wso2.com) "
        + "and @[WSO2](amplify:org:wso2) @[X](amplify:org:other)";
    w.mem.putShare(share);
    check connectedEmployee(w.mem, w.cipher, "emp-m", now);
    w.mem.putMentionable({employeeId: "jane@wso2.com", memberUrn: "urn:li:person:jane1", displayName: "Jane S",
        memberName: "Jane Smith"});
    _ = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-m"));
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1);
    test:assertEquals(w.linkedIn.lastMentionTargets(), {
        "person:jane@wso2.com": {name: "Jane Smith", urn: "urn:li:person:jane1"},
        "org:wso2": {name: "WSO2", urn: "urn:li:organization:1477"}
    }, "the LinkedIn name and URN Amplify holds; unknown refs left out");
}

@test:Config
function linkedIn429KeepsShareQueuedAndRetries() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    var share = queuedShare(cid, "emp-429", now);
    w.mem.putCampaign(openCampaign(cid, now));
    w.mem.putShare(share);
    check connectedEmployee(w.mem, w.cipher, "emp-429", now);
    w.linkedIn.setMode("429");
    int id = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-429"));
    RunReport r = check run(w);
    test:assertEquals(r.retried, 1);
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING");
    var still = check w.mem.share(cid, "emp-429");
    test:assertTrue(still !is () && still.publishedAt is () && still.failedAt is (), "B14: stays QUEUED");

    w.linkedIn.setMode("ok");
    w.queue.makeAllDue();
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1);
}

@test:Config
function linkedInRejectionFailsShareWithoutRetry() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    var share = queuedShare(cid, "emp-422", now);
    w.mem.putCampaign(openCampaign(cid, now));
    w.mem.putShare(share);
    check connectedEmployee(w.mem, w.cipher, "emp-422", now);
    w.linkedIn.setMode("422");
    _ = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-422"));
    _ = check run(w);
    var failedShare = check w.mem.share(cid, "emp-422");
    test:assertTrue(failedShare !is () && failedShare.failureReason == types:PROVIDER_REJECTED);
}

@test:Config
function missingConnectionFailsShareWithNeedsReconnect() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    var share = queuedShare(cid, "emp-none", now);
    w.mem.putShare(share);
    _ = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-none"));
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 0);
    var failedShare = check w.mem.share(cid, "emp-none");
    test:assertTrue(failedShare !is () && failedShare.failureReason == types:NEEDS_RECONNECT);
}

@test:Config
function linkedInCeilingDefersTheRest() returns error? {
    World w = harness();
    RunConfig cfg = {...TEST_CONFIG};
    cfg.linkedinMaxPostsPerRun = 1;
    w.deps.config = cfg;
    time:Utc now = time:utcNow();
    int[] ids = [];
    foreach string emp in ["c-1", "c-2"] {
        string cid = types:newUuidV7();
        var share = queuedShare(cid, emp, now);
        w.mem.putCampaign(openCampaign(cid, now));
        w.mem.putShare(share);
        check connectedEmployee(w.mem, w.cipher, emp, now);
        ids.push(w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, emp)));
    }
    RunReport r = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1);
    test:assertEquals(r.deferred, 1);
    test:assertEquals(w.queue.statusOf(ids[1]), ["PENDING", 0, "LinkedIn post ceiling reached"]);
}

@test:Config
function staleRequestRoundIsIgnored() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    var share = queuedShare(cid, "emp-old", now);
    share.attempts = 2;
    w.mem.putShare(share);
    check connectedEmployee(w.mem, w.cipher, "emp-old", now);
    _ = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-old", 1));
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 0, "round 1 event after a retry to round 2 does nothing");
}

// ---- One run at a time ------------------------------------------------------------------------------

@test:Config
function twoConcurrentRunsRunOnce() returns error? {
    World w = harness();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    w.novera.setMode("ok", 1);
    _ = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    Deps deps = w.deps;
    future<RunReport|RunSkipped|error> first = start runOnce(deps);
    runtime:sleep(0.3);
    RunReport|RunSkipped|error second = runOnce(deps);
    test:assertTrue(second is RunSkipped, "the second caller is told a run is in progress");
    RunReport|RunSkipped|error firstResult = wait first;
    test:assertTrue(firstResult is RunReport);
    test:assertEquals(w.novera.sent(), 1);
    // The flag is released: a later run works.
    test:assertTrue(runOnce(deps) is RunReport);
}

@test:Config
function runSkipsWhenAnotherReplicaHoldsTheLock() returns error? {
    World w = harness(false);
    RunReport|RunSkipped result = check runOnce(w.deps);
    test:assertTrue(result is RunSkipped);
}
