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

import amplify_common.events;
import amplify_common.types;

import ballerina/test;
import ballerina/time;

final time:Utc T0 = [1790000000, 0];

isolated function code(any|error result) returns string {
    if result is types:DomainError {
        return result.detail().code;
    }
    return result is error ? "ERROR" : "OK";
}

@test:Config
function announcedExactlyOnce() returns error? {
    Announcement a = check queueAnnouncement((), "c1", 42, T0);
    test:assertEquals(announcementStatus(a), QUEUED);
    test:assertEquals(a.space, NOVERA_SPACE);
    test:assertEquals(a.idempotencyKey, "amplify:c1", "the key Novera gets on every attempt");
    test:assertEquals(code(queueAnnouncement(a, "c1", 43, T0)), types:ERR_ALREADY_ANNOUNCED);
}

@test:Config
function sentFailedAndRetry() returns error? {
    Announcement a = check queueAnnouncement((), "c1", 42, T0);
    Announcement sent = check markSent(a, "novera:c1", T0);
    test:assertEquals(announcementStatus(sent), SENT);
    test:assertEquals(sent.messageName, "novera:c1");
    events:OutboxEvent event = campaignAnnouncedEvent(sent);
    test:assertEquals(event.idempotencyKey, "CampaignAnnounced:42");
    test:assertEquals(code(markSent(sent, "x", T0)), types:ERR_ANNOUNCEMENT_NOT_QUEUED);
    test:assertEquals(code(retryAnnouncement(sent)), types:ERR_ANNOUNCEMENT_NOT_FAILED, "only FAILED can be retried");

    Announcement failed = check markFailed(a, "HTTP 500", T0);
    test:assertEquals(announcementStatus(failed), FAILED);
    Announcement requeued = check retryAnnouncement(failed);
    test:assertEquals(announcementStatus(requeued), QUEUED);
}

@test:Config
function announcedKeyIsUniqueWhenTheOutboxIdIsMissing() {
    // `outbox_id` is nullable: keying on a `?: 0` default would put every such announcement on
    // `CampaignAnnounced:0` and the unique index would silently drop all but the first.
    Announcement one = {campaignId: "c1", outboxId: (), space: "novera", idempotencyKey: "amplify:c1",
        messageName: "novera:c1", queuedAt: T0, sentAt: T0, failedAt: (), lastError: ()};
    Announcement two = {campaignId: "c2", outboxId: (), space: "novera", idempotencyKey: "amplify:c2",
        messageName: "novera:c2", queuedAt: T0, sentAt: T0, failedAt: (), lastError: ()};
    test:assertEquals(campaignAnnouncedEvent(one).idempotencyKey, "CampaignAnnounced:c1");
    test:assertEquals(campaignAnnouncedEvent(two).idempotencyKey, "CampaignAnnounced:c2");
    test:assertNotEquals(campaignAnnouncedEvent(one).idempotencyKey, campaignAnnouncedEvent(two).idempotencyKey);
    // A row that has its outbox id keeps the catalogue key.
    Announcement keyed = {campaignId: "c3", outboxId: 7, space: "novera", idempotencyKey: "amplify:c3",
        messageName: "novera:c3", queuedAt: T0, sentAt: T0, failedAt: (), lastError: ()};
    test:assertEquals(campaignAnnouncedEvent(keyed).idempotencyKey, "CampaignAnnounced:7");
}

const string BUTTON = "https://one.wso2.com/amplify/celebrate?share={campaignId}";
const string X_BUTTON = "https://x.example/p?share={campaignId}";

@test:Config
function noveraNotificationHasAnAmplifyButtonFromTheTemplateAndKeepsOnlyAnHttpsIcon() returns error? {
    NoveraNotification n = check buildNoveraNotification(
            {campaignId: "c1", title: "T", summary: "S", imageUrl: (), isPriority: true},
            BUTTON, "https://media.wso2.com/amplify-avatar.png");
    test:assertEquals(n.'source, "amplify");
    test:assertEquals(n.button.url, "https://one.wso2.com/amplify/celebrate?share=c1");
    test:assertEquals(n.button.label, "Amplify");
    test:assertEquals(n.subtitle, "Amplify · Priority");
    test:assertEquals(n.iconUrl, "https://media.wso2.com/amplify-avatar.png");
    test:assertFalse((check buildNoveraNotification({campaignId: "c1", title: "T", summary: (), imageUrl: (),
            isPriority: false}, X_BUTTON, "http://insecure.example/a.png")).hasKey("iconUrl"));
    // Every placeholder is replaced, wherever it sits.
    NoveraNotification twice = check buildNoveraNotification({campaignId: "0192f0e0-aaaa-7bbb-8ccc-123456789abc",
            title: "T", summary: (), imageUrl: (), isPriority: false},
            "https://x.example/posts/{campaignId}/share?id={campaignId}");
    test:assertEquals(twice.button.url, "https://x.example/posts/0192f0e0-aaaa-7bbb-8ccc-123456789abc/share?id="
            + "0192f0e0-aaaa-7bbb-8ccc-123456789abc");
}

@test:Config
function aButtonTemplateThatCantGiveALinkBuildsNoCard() {
    CampaignCardSource c = {campaignId: "c1", title: "T", summary: (), imageUrl: (), isPriority: false};
    foreach string template in ["", "   ", "https://x.example/p", "https://x.example/p?share={id}",
            "https://x.example/{campaignId}/{other}", "ftp://x.example/{campaignId}", "https://x.example/a b/{campaignId}"] {
        test:assertEquals(code(buildNoveraNotification(c, template)), ERR_INVALID_BUTTON_URL, template);
    }
    // A campaign id that isn't a uuid can't smuggle braces into the link.
    test:assertEquals(code(buildNoveraNotification({campaignId: "{x}", title: "T", summary: (), imageUrl: (),
            isPriority: false}, X_BUTTON)), ERR_INVALID_BUTTON_URL);
}

@test:Config
function buttonTemplateCheckWantsHttpsAndThePlaceholder() {
    test:assertEquals(checkButtonUrlTemplate(BUTTON), ());
    test:assertEquals(code(checkButtonUrlTemplate("http://one.wso2.com/amplify/celebrate?share={campaignId}")),
            ERR_INVALID_BUTTON_URL, "plain http is refused");
    test:assertEquals(checkButtonUrlTemplate("http://localhost:3000/amplify/celebrate?share={campaignId}", true), (),
            "http only with the local allow-insecure flag");
    test:assertEquals(code(checkButtonUrlTemplate("https://one.wso2.com/amplify/celebrate")), ERR_INVALID_BUTTON_URL,
            "the placeholder is required");
    test:assertEquals(code(checkButtonUrlTemplate("https://one.wso2.com/{campaignId}/{x}")), ERR_INVALID_BUTTON_URL,
            "no other braces");
}

@test:Config
function noveraNotificationPicksThePostImageThenTheDefaultAndOnlyWhenChatCanFetchIt() returns error? {
    string own = "https://media.wso2.com/leader.png";
    string fallback = "https://media.wso2.com/default.png";
    NoveraNotification withOwn = check buildNoveraNotification(
            {campaignId: "c1", title: "T", summary: "S", imageUrl: own, isPriority: false}, X_BUTTON,
            (), fallback);
    test:assertEquals(withOwn.imageUrl, own);
    // A private host or plain http can't be fetched by Chat: the default image stands in.
    NoveraNotification unusable = check buildNoveraNotification(
            {campaignId: "c1", title: "T", summary: "S", imageUrl: "https://intranet.local/a.png", isPriority: false},
            X_BUTTON, (), fallback);
    test:assertEquals(unusable.imageUrl, fallback);
    // Neither usable: no image at all.
    test:assertFalse((check buildNoveraNotification({campaignId: "c1", title: "T", summary: "S", imageUrl: (),
            isPriority: false}, X_BUTTON)).hasKey("imageUrl"));
}

@test:Config
function noveraNotificationCutsToNoveraLimitsAndFillsAnEmptySummary() returns error? {
    string long = string:'join("", from int i in 0 ..< 6000 select "x");
    NoveraNotification n = check buildNoveraNotification(
            {campaignId: "c1", title: long, summary: long, imageUrl: (), isPriority: false}, X_BUTTON);
    test:assertEquals(n.title.length(), 300);
    test:assertEquals(n.body.length(), 5000);
    NoveraNotification blank = check buildNoveraNotification(
            {campaignId: "c1", title: "T", summary: "  ", imageUrl: (), isPriority: false}, X_BUTTON);
    test:assertEquals(blank.body, "A new post is ready to share.");
}

// ---- the attempt marker (Novera doesn't dedupe; at most one card per campaign) --------------------------

final time:Utc T1 = [1790000060, 0];

@test:Config
function aQueuedAnnouncementHasNoMarkerAndMarkAttemptedSetsIt() returns error? {
    Announcement a = check queueAnnouncement((), "c1", 42, T0);
    test:assertEquals(a.attemptedAt, (), "a new announcement carries no marker");
    test:assertFalse(hasUnfinishedAttempt(a));
    Announcement attempted = check markAttempted(a, T1);
    test:assertEquals(attempted.attemptedAt, T1);
    test:assertEquals(announcementStatus(attempted), QUEUED, "the marker is not a status");
    test:assertTrue(hasUnfinishedAttempt(attempted));
    // Only a queued announcement can be attempted.
    test:assertEquals(code(markAttempted(check markSent(attempted, "novera:c1", T1), T1)),
            types:ERR_ANNOUNCEMENT_NOT_QUEUED);
    test:assertEquals(code(markAttempted(check markFailed(a, "x", T1), T1)), types:ERR_ANNOUNCEMENT_NOT_QUEUED);
}

@test:Config
function clearAttemptRemovesTheMarkerAfterADefiniteNonDelivery() returns error? {
    Announcement attempted = check markAttempted(check queueAnnouncement((), "c1", 42, T0), T1);
    Announcement cleared = check clearAttempt(attempted);
    test:assertEquals(cleared.attemptedAt, ());
    test:assertFalse(hasUnfinishedAttempt(cleared));
    test:assertEquals(announcementStatus(cleared), QUEUED);
    test:assertEquals(code(clearAttempt(check markSent(attempted, "novera:c1", T1))), types:ERR_ANNOUNCEMENT_NOT_QUEUED);
}

@test:Config
function markDeliveryUnknownFailsTheAnnouncementAndKeepsTheMarker() returns error? {
    Announcement attempted = check markAttempted(check queueAnnouncement((), "c1", 42, T0), T1);
    Announcement unknown = check markDeliveryUnknown(attempted, T1);
    test:assertEquals(announcementStatus(unknown), FAILED);
    test:assertEquals(unknown.failedAt, T1);
    test:assertEquals(unknown.attemptedAt, T1, "the marker stays as evidence");
    test:assertEquals(unknown.lastError,
            "Delivery unknown: an earlier attempt may have reached Novera; check Novera before retrying");
    test:assertFalse(hasUnfinishedAttempt(unknown), "a failed announcement is not an unfinished attempt");
    Announcement withReason = check markDeliveryUnknown(attempted, T1, "Novera OUTCOME_UNKNOWN (HTTP 502)");
    string lastError = withReason.lastError ?: "";
    test:assertTrue(lastError.startsWith("Delivery unknown:"));
    test:assertTrue(lastError.includes("HTTP 502"));
    test:assertEquals(code(markDeliveryUnknown(unknown, T1)), types:ERR_ANNOUNCEMENT_NOT_QUEUED);
}

@test:Config
function adminRetryClearsBothTheFailureAndTheMarker() returns error? {
    Announcement attempted = check markAttempted(check queueAnnouncement((), "c1", 42, T0), T1);
    Announcement unknown = check markDeliveryUnknown(attempted, T1);
    Announcement requeued = check retryAnnouncement(unknown);
    test:assertEquals(requeued.failedAt, ());
    test:assertEquals(requeued.attemptedAt, (), "retrying is the person's decision to send again");
    test:assertEquals(announcementStatus(requeued), QUEUED);
    test:assertFalse(hasUnfinishedAttempt(requeued));
    test:assertEquals(code(retryAnnouncement(attempted)), types:ERR_ANNOUNCEMENT_NOT_FAILED,
            "a queued attempt is not retried by hand");
}

// ---- Novera seen counts (V023) ---------------------------------------------------------------------

@test:Config
function referenceGoesOutOnlyWhenAskedForAndOnlyWhenUrlSafe() returns error? {
    CampaignCardSource c = {campaignId: "0192f0e0-aaaa-7bbb-8ccc-123456789abc", title: "T", summary: (), imageUrl: (),
        isPriority: false};
    NoveraNotification plain = check buildNoveraNotification(c, BUTTON);
    test:assertFalse(plain.hasKey("reference"), "an older Novera refuses unknown fields: no reference by default");
    NoveraNotification counted = check buildNoveraNotification(c, BUTTON, withReference = true);
    test:assertEquals(counted?.reference, "0192f0e0-aaaa-7bbb-8ccc-123456789abc");
}

@test:Config
function onlyUrlSafeIdsAreNoveraIds() {
    foreach string ok in ["0b9a7c1e-1f2d-4c3b-9a8e-7d6c5b4a3f21", "amplify:c1", "a.b_c-d"] {
        test:assertTrue(isNoveraId(ok), ok);
    }
    string long = "";
    foreach int _ in 0 ..< 101 {
        long += "a";
    }
    foreach string bad in ["", "a/b", "../x", "a b", "a?b", long] {
        test:assertFalse(isNoveraId(bad), bad);
    }
}

@test:Config
function aSentAnnouncementKeepsNoverasBroadcastId() returns error? {
    Announcement a = check queueAnnouncement((), "c1", 42, T0);
    Announcement sent = check markSent(a, "novera:c1", T0, "0b9a7c1e-1f2d-4c3b-9a8e-7d6c5b4a3f21");
    test:assertEquals(sent.noveraNotificationId, "0b9a7c1e-1f2d-4c3b-9a8e-7d6c5b4a3f21");
    test:assertEquals((check markSent(a, "novera:c1", T0)).noveraNotificationId, (), "an older Novera returns no id");
    test:assertEquals((check markSent(a, "novera:c1", T0, "a/b")).noveraNotificationId, (), "an unsafe id is dropped");
}
