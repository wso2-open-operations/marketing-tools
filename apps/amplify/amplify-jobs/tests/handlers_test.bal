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

// Handler and run branches the M6 tests didn't reach (deep review 2026-10-17): kill switches and missing
// configuration defer, terminal campaign states, card rejection, token edge cases, the final attempt,
// scoring without a rule, the daily ceiling, the run time budget, a panic inside a run, settings parsing.

import amplify_common.crypto;
import amplify_common.events;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.connection;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/test;
import ballerina/time;

function shareWorld(string emp, string mode = "ok") returns [World, string, int]|error {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    var share = queuedShare(cid, emp, now);
    w.mem.putShare(share);
    check connectedEmployee(w.mem, w.cipher, emp, now);
    w.linkedIn.setMode(mode);
    int id = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, emp));
    return [w, cid, id];
}

// ---- a panic inside a run ------------------------------------------------------------------------

@test:Config
function aPanicInsideARunReleasesTheFlagAndTheLock() returns error? {
    World w = harness();
    CountingLock runLock = new;
    Deps panicking = {...w.deps};
    panicking.runStore = new PanickingRunStore(w.queue);
    panicking.runLock = runLock;
    RunReport|RunSkipped|error broken = runOnce(panicking, "corr-panic");
    test:assertTrue(broken is error, "the panic comes back as an error, not a crash");
    test:assertEquals(runLock.counts(), [1, 1], "the advisory lock is released after the panic");
    test:assertFalse(isRunInProgress(), "the in-process flag is released");
    // The next call runs instead of answering SKIPPED forever.
    RunReport|RunSkipped|error next = runOnce(w.deps, "corr-after-panic");
    test:assertTrue(next is RunReport, "a later run works after a panic");
}

// ---- CampaignRegistered ----------------------------------------------------------------------------

@test:Config
function campaignRegisteredDefersWhenNoveraIsOffOrNotConfigured() returns error? {
    World w = harness();
    w.deps.novera = ();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    RunReport r = check run(w);
    test:assertEquals(r.deferred, 1);
    test:assertEquals(w.queue.statusOf(id), ["PENDING", 0, "Novera is off or not configured"]);
}

@test:Config
function campaignRegisteredIsAnnouncedThroughNovera() returns error? {
    World w = harness();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    _ = check run(w);
    test:assertEquals(w.novera.sent(), 1);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    var a = check w.mem.announcement(cid);
    test:assertTrue(a !is () && a.space == "novera" && a.sentAt !is (), "announced, space labelled novera");
}

@test:Config
function aNovera503RetriesWithTheSameIdempotencyKey() returns error? {
    World w = harness();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));

    w.novera.setMode("503");
    RunReport retried = check run(w);
    test:assertEquals(retried.retried, 1, "a Novera 503 retries the row");
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING");
    string? firstKey = w.novera.idempotencyKey();

    w.novera.setMode("ok");
    w.queue.makeAllDue();
    _ = check run(w);
    test:assertEquals(w.novera.sent(), 1);
    test:assertEquals(w.novera.idempotencyKey(), firstKey, "a retry sends the key the first attempt sent");
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
}

@test:Config
function aRefusedNoveraAnnouncementFailsWithoutRetry() returns error? {
    World w = harness();
    w.novera.setMode("400");
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    RunReport r = check run(w);
    test:assertEquals(r.failed, 1);
    test:assertEquals(w.queue.statusOf(id)[0], "FAILED");
    var a = check w.mem.announcement(cid);
    test:assertTrue(a !is () && a.failedAt !is (), "FAILED, so the admin retry can re-queue it");
}

// ---- at most one card per campaign (Novera doesn't dedupe; owner decision 2026-11-03) -----------------------

function announceWorld() returns [World, string, int] {
    World w = harness();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    int id = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid));
    return [w, cid, id];
}

function storedAnnouncement(World w, string cid) returns announcements:Announcement|error {
    announcements:Announcement? a = check w.mem.announcement(cid);
    return a is () ? error("no announcement row") : a;
}

@test:Config
function campaignRegisteredDefersWhenTheButtonUrlIsNotConfigured() returns error? {
    [World, string, int] [w, _, id] = announceWorld();
    RunConfig cfg = {...TEST_CONFIG};
    cfg.noveraButtonUrl = "";
    w.deps.config = cfg;
    RunReport r = check run(w);
    test:assertEquals(r.deferred, 1);
    test:assertEquals(w.queue.statusOf(id), ["PENDING", 0, "Novera button URL is not configured"]);
    test:assertEquals(w.novera.calls(), 0, "never a card without its button");
}

@test:Config
function theCardButtonOpensTheConfiguredLinkForTheCampaign() returns error? {
    [World, string, int] [w, cid, _] = announceWorld();
    _ = check run(w);
    test:assertEquals(w.novera.buttonUrl(), "https://one.wso2.com/amplify/celebrate?share=" + cid);
}

@test:Config
function aQueuedRowWithoutTheMarkerIsSentOnce() returns error? {
    [World, string, int] [w, cid, id] = announceWorld();
    w.mem.putAnnouncement(check announcements:queueAnnouncement((), cid, id, time:utcNow()));
    _ = check run(w);
    test:assertEquals(w.novera.calls(), 1);
    test:assertEquals(w.novera.sent(), 1);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    w.queue.redeliver(id);
    _ = check run(w);
    test:assertEquals(w.novera.calls(), 1, "a sent announcement is never sent again");
}

@test:Config
function aFailedSaveAfterNoveraAcceptedNeverSendsASecondCard() returns error? {
    [World, string, int] [w, cid, id] = announceWorld();
    w.mem.failNextAnnouncementSave("SENT");
    RunReport first = check run(w);
    test:assertEquals(first.retried, 1, "the handler error retries the row");
    test:assertEquals(w.novera.sent(), 1, "Novera took the card");

    w.queue.makeAllDue();
    RunReport second = check run(w);
    test:assertEquals(second.failed, 1);
    test:assertEquals(w.novera.calls(), 1, "the retry does not call Novera again");
    test:assertEquals(w.queue.statusOf(id)[0], "FAILED");
    announcements:Announcement a = check storedAnnouncement(w, cid);
    test:assertEquals(announcements:announcementStatus(a), announcements:FAILED);
    test:assertTrue((a.lastError ?: "").startsWith("Delivery unknown:"));
    test:assertEquals(a.lastError,
            "Delivery unknown: an earlier attempt may have reached Novera; check Novera before retrying");
    test:assertTrue(a.attemptedAt !is (), "the marker stays as evidence");

    w.queue.makeAllDue();
    _ = check run(w);
    test:assertEquals(w.novera.calls(), 1, "still one call");
}

@test:Config
function aCrashAfterTheCallLeavesTheMarkerAndTheNextRunDoesNotSend() returns error? {
    [World, string, int] [w, cid, id] = announceWorld();
    // What a crash between the Novera call and the save leaves behind: a queued row carrying the marker.
    time:Utc now = time:utcNow();
    w.mem.putAnnouncement(check announcements:markAttempted(
            check announcements:queueAnnouncement((), cid, id, now), now));
    RunReport r = check run(w);
    test:assertEquals(r.failed, 1);
    test:assertEquals(w.novera.calls(), 0);
    test:assertEquals(w.queue.statusOf(id)[0], "FAILED");
    test:assertTrue(((check storedAnnouncement(w, cid)).lastError ?: "").startsWith("Delivery unknown:"));
}

@test:Config
function anAmbiguousNoveraFailureIsDeliveryUnknownAndNeverRetried() returns error? {
    foreach string mode in ["500", "502", "timeout"] {
        [World, string, int] [w, cid, id] = announceWorld();
        w.novera.setMode(mode);
        RunReport r = check run(w);
        test:assertEquals(r.failed, 1, mode);
        test:assertEquals(r.retried, 0, mode);
        test:assertEquals(w.queue.statusOf(id)[0], "FAILED", mode);
        announcements:Announcement a = check storedAnnouncement(w, cid);
        test:assertEquals(announcements:announcementStatus(a), announcements:FAILED, mode);
        test:assertTrue((a.lastError ?: "").startsWith("Delivery unknown:"), mode);
        test:assertTrue(a.attemptedAt !is (), mode);
        w.novera.setMode("ok");
        w.queue.makeAllDue();
        _ = check run(w);
        test:assertEquals(w.novera.calls(), 1, mode + ": no automatic second call");
    }
}

@test:Config
function aDefiniteNonDeliveryClearsTheMarkerAndRetries() returns error? {
    foreach string mode in ["429", "503", "401", "unreachable"] {
        [World, string, int] [w, cid, id] = announceWorld();
        w.novera.setMode(mode);
        RunReport r = check run(w);
        test:assertEquals(r.retried, 1, mode);
        test:assertEquals(w.queue.statusOf(id)[0], "PENDING", mode);
        announcements:Announcement a = check storedAnnouncement(w, cid);
        test:assertEquals(a.attemptedAt, (), mode + ": marker cleared, nothing went out");
        test:assertEquals(announcements:announcementStatus(a), announcements:QUEUED, mode);
        w.novera.setMode("ok");
        w.queue.makeAllDue();
        _ = check run(w);
        test:assertEquals(w.novera.calls(), 2, mode);
        test:assertEquals(w.novera.sent(), 1, mode + ": sent once");
        test:assertEquals(w.queue.statusOf(id)[0], "DONE", mode);
    }
}

@test:Config
function aMarkerThatCantBeSavedSendsNothingAndRetries() returns error? {
    [World, string, int] [w, cid, id] = announceWorld();
    w.mem.failNextAnnouncementSave("ATTEMPT");
    RunReport r = check run(w);
    test:assertEquals(r.retried, 1);
    test:assertEquals(w.novera.calls(), 0, "Novera is not called without a durable marker");
    test:assertEquals((check storedAnnouncement(w, cid)).attemptedAt, ());
    w.queue.makeAllDue();
    _ = check run(w);
    test:assertEquals(w.novera.sent(), 1);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
}

@test:Config
function theAdminRetryAfterDeliveryUnknownSendsOnce() returns error? {
    [World, string, int] [w, cid, id] = announceWorld();
    w.novera.setMode("502");
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "FAILED");
    // A person checked Novera, saw no card and pressed Retry.
    w.novera.setMode("ok");
    w.queue.adminRetry(id);
    _ = check run(w);
    test:assertEquals(w.novera.calls(), 2);
    test:assertEquals(w.novera.sent(), 1);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    announcements:Announcement a = check storedAnnouncement(w, cid);
    test:assertTrue(a.sentAt !is () && a.failedAt is ());
}

@test:Config
function aFailedAnnouncementComingBackWithoutTheAdminRetryIsNotSent() returns error? {
    [World, string, int] [w, _, id] = announceWorld();
    w.novera.setMode("400");
    _ = check run(w);
    test:assertEquals(w.novera.calls(), 1);
    // The row comes back on a later attempt (its failure was saved but the row wasn't finished).
    w.novera.setMode("ok");
    w.queue.redeliver(id);
    RunReport r = check run(w);
    test:assertEquals(r.failed, 1);
    test:assertEquals(w.novera.calls(), 1, "no second card without a person's retry");
    test:assertEquals(w.queue.statusOf(id)[2], "announcement already failed; waiting for an admin retry");
}

@test:Config
function campaignRegisteredForAMissingArchivedOrClosedCampaignIsDoneWithoutACard() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    int missing = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(types:newUuidV7()));

    string archivedId = types:newUuidV7();
    var archived = openCampaign(archivedId, now);
    archived.archivedAt = now;
    w.mem.putCampaign(archived);
    int archivedRow = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(archivedId));

    string closedId = types:newUuidV7();
    var closed = openCampaign(closedId, now, -7200);
    closed.closesAt = time:utcAddSeconds(now, -60);
    w.mem.putCampaign(closed);
    int closedRow = w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(closedId));

    RunReport r = check run(w);
    test:assertEquals(r.succeeded, 3);
    test:assertEquals(w.novera.sent(), 0, "nothing is announced");
    test:assertEquals(w.queue.statusOf(missing)[0], "DONE");
    test:assertEquals(w.queue.statusOf(archivedRow)[0], "DONE");
    test:assertEquals(w.queue.statusOf(closedRow)[0], "DONE");
}

@test:Config
function repostDefersWhenSharingIsOffOrLinkedInIsNotConfigured() returns error? {
    [World, string, int] [w, _, id] = check shareWorld("emp-off");
    w.mem.setSettings({sharingEnabled: false});
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id), ["PENDING", 0, "sharing.enabled is off"]);

    w.mem.setSettings({});
    w.queue.makeAllDue();
    w.deps.linkedIn = ();
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id), ["PENDING", 0, "LinkedIn or token keys not configured"]);

    w.queue.makeAllDue();
    w.deps.linkedIn = w.linkedIn;
    w.deps.cipher = ();
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id), ["PENDING", 0, "LinkedIn or token keys not configured"]);
    test:assertEquals(w.linkedIn.postCount(), 0);
}

@test:Config
function repostForAMissingOrAlreadyPublishedShareIsDone() returns error? {
    World w = harness();
    int missing = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(types:newUuidV7(), types:newUuidV7(), "emp-x"));
    _ = check run(w);
    [string, int, string?] [status, _, _] = w.queue.statusOf(missing);
    test:assertEquals(status, "DONE");

    [World, string, int] [w2, _, id] = check shareWorld("emp-published");
    _ = check run(w2);
    test:assertEquals(w2.linkedIn.postCount(), 1);
    w2.queue.redeliver(id);
    _ = check run(w2);
    test:assertEquals(w2.linkedIn.postCount(), 1, "already PUBLISHED: never posts twice");
}

@test:Config
function repostWithTheTokenRowGoneFailsWithNeedsReconnect() returns error? {
    [World, string, int] [w, cid, _] = check shareWorld("emp-gone");
    w.mem.dropTokens();
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 0);
    var failedShare = check w.mem.share(cid, "emp-gone");
    test:assertTrue(failedShare !is () && failedShare.failureReason == types:NEEDS_RECONNECT);
}

@test:Config
function undecryptableTokenRetriesThenFailsWithRetriesExhausted() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    var share = queuedShare(cid, "emp-key", now);
    w.mem.putShare(share);
    // Sealed under a key the run's ring doesn't hold (a retired key).
    byte[] other = [];
    foreach int i in 0 ..< 32 {
        other.push(<byte>(200 - i));
    }
    crypto:TokenCipher retired = check new ([{keyId: "k-retired", key: other}], "k-retired");
    check connectedEmployee(w.mem, retired, "emp-key", now);
    int id = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-key"));
    foreach int i in 1 ... TEST_CONFIG.maxAttempts {
        _ = check run(w);
        w.queue.makeAllDue();
    }
    test:assertEquals(w.linkedIn.postCount(), 0);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE", "the share failed, so the row is handled");
    var failedShare = check w.mem.share(cid, "emp-key");
    test:assertTrue(failedShare !is () && failedShare.failureReason == types:RETRIES_EXHAUSTED);
    test:assertTrue(failedShare !is () && failedShare.lastErrorCode == "TOKEN_KEY");
}

@test:Config
function aShareThatNeverReachesLinkedInDoesNotUseTheCeiling() returns error? {
    // Ceiling 1: the first row's token can't be decrypted (no call), so the second row still posts.
    World w = harness();
    RunConfig cfg = {...TEST_CONFIG};
    cfg.linkedinMaxPostsPerRun = 1;
    w.deps.config = cfg;
    time:Utc now = time:utcNow();
    byte[] other = [];
    foreach int i in 0 ..< 32 {
        other.push(<byte>(100 + i));
    }
    crypto:TokenCipher retired = check new ([{keyId: "k-old", key: other}], "k-old");
    foreach [string, crypto:TokenCipher] [emp, sealer] in [["ceil-bad", retired], ["ceil-ok", w.cipher]] {
        string cid = types:newUuidV7();
        var share = queuedShare(cid, emp, now);
        w.mem.putCampaign(openCampaign(cid, now));
        w.mem.putShare(share);
        check connectedEmployee(w.mem, sealer, emp, now);
        _ = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, emp));
    }
    RunReport r = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1, "the ceiling is spent only by a real call");
    test:assertEquals(r.retried, 1);
    test:assertEquals(r.deferred, 0);
}

@test:Config
function retryableLinkedInErrorOnTheFinalAttemptFailsTheShare() returns error? {
    [World, string, int] [w, cid, id] = check shareWorld("emp-429-final", "429");
    foreach int i in 1 ... TEST_CONFIG.maxAttempts {
        _ = check run(w);
        w.queue.makeAllDue();
    }
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    var failedShare = check w.mem.share(cid, "emp-429-final");
    test:assertTrue(failedShare !is () && failedShare.failureReason == types:RETRIES_EXHAUSTED,
            "B14: QUEUED until the last attempt, then FAILED");
}

// A previous attempt wrote the in-flight marker and never cleared it: LinkedIn may already have the post.
@test:Config
function aShareCarryingTheInFlightMarkerIsFailedWithoutCallingLinkedIn() returns error? {
    World w = harness();
    time:Utc now = time:utcNow();
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, now));
    sharing:ShareRequest share = queuedShare(cid, "emp-inflight", now);
    share.lastErrorCode = PUBLISH_IN_FLIGHT;
    w.mem.putShare(share);
    check connectedEmployee(w.mem, w.cipher, "emp-inflight", now);
    int id = w.queue.enqueue(events:REPOST_REQUESTED, repostRequested(share.id, cid, "emp-inflight"));
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 0, "never post what a previous attempt may already have posted");
    [string, int, string?] [status, _, lastError] = w.queue.statusOf(id);
    test:assertEquals(status, "FAILED", "failed for manual review, never retried");
    test:assertTrue(lastError is string && lastError.startsWith("a previous publish attempt may already have posted"));
}

// The post is out but `recordPublish` hit a database blip: the marker stays, so a redelivery cannot post twice.
@test:Config
function aFailedRecordWriteAfterThePostLeavesTheMarkerAndNeverPostsTwice() returns error? {
    [World, string, int] [w, cid, id] = check shareWorld("emp-lost-write");
    w.mem.failNextPublishWrite();
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1);
    test:assertEquals(w.queue.statusOf(id)[0], "FAILED", "failed for manual review, not retried");
    sharing:ShareRequest? stuck = check w.mem.share(cid, "emp-lost-write");
    test:assertTrue(stuck is sharing:ShareRequest && stuck.lastErrorCode == PUBLISH_IN_FLIGHT,
            "the marker stays: the post may be out");
    test:assertEquals(w.mem.engagementCount(), 0, "the engagement was not recorded");
    // A duplicate delivery / admin retry of the same row must not post again.
    w.queue.redeliver(id);
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1, "no second post");
}

// Scott 2026-11-01: the post is accepted, then the record ("mark sent") write fails. However many times the
// outbox row comes back, LinkedIn has exactly one post.
@test:Config
function aFailedMarkSentWriteAfterAnAcceptedPostGivesExactlyOnePostAcrossAllRetries() returns error? {
    [World, string, int] [w, cid, id] = check shareWorld("emp-lost-write-retries");
    w.mem.failNextPublishWrite();
    foreach int i in 0 ... TEST_CONFIG.maxAttempts + 1 {
        _ = check run(w);
        w.queue.makeAllDue();
        if i == 1 {
            w.queue.redeliver(id);
        }
    }
    test:assertEquals(w.linkedIn.postCount(), 1, "exactly one post across every retry and redelivery");
    test:assertEquals(w.queue.statusOf(id)[0], "FAILED", "settled for manual review, never PENDING again");
    sharing:ShareRequest? stuck = check w.mem.share(cid, "emp-lost-write-retries");
    test:assertTrue(stuck is sharing:ShareRequest && stuck.lastErrorCode == PUBLISH_IN_FLIGHT
            && sharing:shareStatus(stuck) == sharing:QUEUED, "the marker stays and the share is not marked published");
    test:assertEquals(w.mem.engagementCount(), 0);
}

// A 5xx (LinkedIn did not take the post) leaves the share QUEUED and the outbox row PENDING with the marker
// cleared; the retry posts once.
@test:Config
function aProviderServerErrorLeavesTheRowPendingAndTheRetryPostsOnce() returns error? {
    [World, string, int] [w, cid, id] = check shareWorld("emp-503", "503");
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING");
    sharing:ShareRequest? queued = check w.mem.share(cid, "emp-503");
    test:assertTrue(queued is sharing:ShareRequest && queued.lastErrorCode == () && sharing:shareStatus(queued) == sharing:QUEUED);
    test:assertEquals(w.linkedIn.postCount(), 0);
    w.linkedIn.setMode("ok");
    w.queue.makeAllDue();
    _ = check run(w);
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
}

// Scott 2026-11-01: a timeout leaves the row pending and the outbox retries (ADR-025). The marker is cleared
// (the call returned an error, no record write was lost), the retry posts, and the share ends published.
@test:Config
function aTimeoutLeavesTheRowPendingAndTheRetryPostsOnce() returns error? {
    [World, string, int] [w, cid, id] = check shareWorld("emp-timeout", "timeout");
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING", "not failed: the outbox retries");
    sharing:ShareRequest? queued = check w.mem.share(cid, "emp-timeout");
    test:assertTrue(queued is sharing:ShareRequest && queued.lastErrorCode == () && sharing:shareStatus(queued) == sharing:QUEUED);
    w.linkedIn.setMode("ok");
    w.queue.makeAllDue();
    _ = check run(w);
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    sharing:ShareRequest? published = check w.mem.share(cid, "emp-timeout");
    test:assertTrue(published is sharing:ShareRequest && sharing:shareStatus(published) == sharing:PUBLISHED);
}

// A lost answer after LinkedIn accepted the post is the window ADR-025 item 5 accepts: the row stays pending and is
// retried, so a second post is possible. On the last attempt the share fails (RETRIES_EXHAUSTED) rather than loop.
@test:Config
function aLostAnswerKeepsRetryingUntilTheLastAttemptThenFailsTheShare() returns error? {
    [World, string, int] [w, cid, id] = check shareWorld("emp-lost-answer", "timeout-after-post");
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING");
    foreach int i in 1 ..< TEST_CONFIG.maxAttempts {
        w.queue.makeAllDue();
        _ = check run(w);
    }
    sharing:ShareRequest? failedShare = check w.mem.share(cid, "emp-lost-answer");
    test:assertTrue(failedShare is sharing:ShareRequest && failedShare.failureReason == types:RETRIES_EXHAUSTED,
            "the share fails on the last attempt");
    test:assertEquals(w.linkedIn.postCount(), TEST_CONFIG.maxAttempts, "the accepted window: one post per attempt, bounded by maxAttempts");
}

// LinkedIn answered with an error, so it did not post: the marker is cleared and the retry posts.
@test:Config
function aLinkedInErrorClearsTheInFlightMarkerSoTheRetryCanPost() returns error? {
    [World, string, int] [w, cid, id] = check shareWorld("emp-marker-clear", "429");
    _ = check run(w);
    sharing:ShareRequest? queued = check w.mem.share(cid, "emp-marker-clear");
    test:assertTrue(queued is sharing:ShareRequest && queued.lastErrorCode == (),
            "the marker is cleared: LinkedIn answered, so nothing was posted");
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING");
    w.linkedIn.setMode("ok");
    w.queue.makeAllDue();
    _ = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 1, "the retry posts");
    sharing:ShareRequest? published = check w.mem.share(cid, "emp-marker-clear");
    test:assertTrue(published is sharing:ShareRequest && sharing:shareStatus(published) == sharing:PUBLISHED);
}

@test:Config
function dailyCeilingAlreadySpentDefersEveryShare() returns error? {
    [World, string, int] [w, _, id] = check shareWorld("emp-daily");
    RunConfig cfg = {...TEST_CONFIG};
    cfg.linkedinMaxPostsPerDay = 10;
    w.deps.config = cfg;
    w.deps.runStore = new PublishedTodayRunStore(w.queue, 10);
    RunReport r = check run(w);
    test:assertEquals(w.linkedIn.postCount(), 0);
    test:assertEquals(r.deferred, 1);
    test:assertEquals(w.queue.statusOf(id), ["PENDING", 0, "LinkedIn post ceiling reached"]);
}

// ---- EngagementRecorded --------------------------------------------------------------------------

@test:Config
function engagementWithoutAPointRuleFailsAndBadTimeRetries() returns error? {
    World w = harness();
    w.mem.putRules([]);
    json engagement = {engagementId: types:newUuidV7(), provider: "linkedin",
        targetResourceUrn: "urn:li:share:1000000000000000001", campaignId: (), employeeId: "emp-rule",
        action: types:REPOST_COMMENTARY, occurredAt: time:utcToString(time:utcNow())};
    int noRule = w.queue.enqueue(events:ENGAGEMENT_RECORDED, engagement);
    map<json> badTime = (<map<json>>engagement).clone();
    badTime["engagementId"] = types:newUuidV7();
    badTime["occurredAt"] = "yesterday";
    int bad = w.queue.enqueue(events:ENGAGEMENT_RECORDED, badTime);
    RunReport r = check run(w);
    [string, int, string?] [status, _, lastError] = w.queue.statusOf(noRule);
    test:assertEquals(status, "FAILED");
    test:assertTrue(lastError is string && lastError.startsWith("not scored"));
    test:assertEquals(w.queue.statusOf(bad)[0], "PENDING", "an unexpected error is retried");
    test:assertEquals(r.retried, 1);
    test:assertEquals(w.mem.ledgerSize(), 0);
}

// ---- the run ---------------------------------------------------------------------------------------

@test:Config
function rowsLeftWhenTheTimeBudgetIsSpentGoBackUntouched() returns error? {
    World w = harness();
    RunConfig cfg = {...TEST_CONFIG};
    cfg.maxSeconds = 1;
    w.deps.config = cfg;
    w.novera.setMode("ok", 1.2);
    int[] ids = [];
    foreach int i in 0 ..< 3 {
        string cid = types:newUuidV7();
        w.mem.putCampaign(openCampaign(cid, time:utcNow()));
        ids.push(w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid)));
    }
    RunReport r = check run(w);
    test:assertEquals(r.claimed, 3);
    test:assertEquals(r.succeeded, 1, "the first row is handled");
    test:assertEquals(r.deferred, 2, "the rest go back");
    test:assertEquals(w.queue.statusOf(ids[1]), ["PENDING", 0, "run time budget spent"],
            "attempt given back, due now");
}

@test:Config
function settingsParseKillSwitchesAndRejectBadNumbers() {
    RunSettings s = toRunSettings([
        setting("sharing.enabled", false),
        setting("announcements.enabled", true),
        setting("leaderboard.top_n", 5),
        setting("connection.reminder_days", 10),
        setting("unrelated.key", "x")
    ]);
    test:assertEquals(s, {sharingEnabled: false, announcementsEnabled: true, topN: 5, reminderDays: 10});
    RunSettings fallback = toRunSettings([
        setting("leaderboard.top_n", 0),
        setting("connection.reminder_days", -1),
        setting("sharing.enabled", "yes")
    ]);
    test:assertEquals(fallback.topN, 3, "top_n below 1 keeps the default");
    test:assertEquals(fallback.reminderDays, connection:DEFAULT_REMINDER_DAYS);
    test:assertTrue(fallback.sharingEnabled, "only an explicit false turns sharing off");
}

function setting(string key, json value) returns store:Setting =>
    {key, value, updatedBy: "system", updatedAt: time:utcNow(), version: 1};
