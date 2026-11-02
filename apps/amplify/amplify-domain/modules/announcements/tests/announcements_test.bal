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
    Announcement a = check queueAnnouncement((), "c1", 42, "club", T0);
    test:assertEquals(announcementStatus(a), QUEUED);
    test:assertEquals(a.threadKey, "campaign-c1");
    test:assertEquals(code(queueAnnouncement(a, "c1", 43, "club", T0)), types:ERR_ALREADY_ANNOUNCED);
}

@test:Config
function sentFailedAndRetry() returns error? {
    Announcement a = check queueAnnouncement((), "c1", 42, "club", T0);
    Announcement sent = check markSent(a, "spaces/club/messages/m1", T0, "spaces/club/threads/t1");
    test:assertEquals(announcementStatus(sent), SENT);
    test:assertEquals(sent.chatThreadName, "spaces/club/threads/t1");
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
    Announcement one = {campaignId: "c1", outboxId: (), space: "club", threadKey: "campaign-c1",
        chatMessageName: "spaces/club/messages/m1", queuedAt: T0, sentAt: T0, failedAt: (), lastError: ()};
    Announcement two = {campaignId: "c2", outboxId: (), space: "club", threadKey: "campaign-c2",
        chatMessageName: "spaces/club/messages/m2", queuedAt: T0, sentAt: T0, failedAt: (), lastError: ()};
    test:assertEquals(campaignAnnouncedEvent(one).idempotencyKey, "CampaignAnnounced:c1");
    test:assertEquals(campaignAnnouncedEvent(two).idempotencyKey, "CampaignAnnounced:c2");
    test:assertNotEquals(campaignAnnouncedEvent(one).idempotencyKey, campaignAnnouncedEvent(two).idempotencyKey);
    // A row that has its outbox id keeps the catalogue key.
    Announcement keyed = {campaignId: "c3", outboxId: 7, space: "club", threadKey: "campaign-c3",
        chatMessageName: "spaces/club/messages/m3", queuedAt: T0, sentAt: T0, failedAt: (), lastError: ()};
    test:assertEquals(campaignAnnouncedEvent(keyed).idempotencyKey, "CampaignAnnounced:7");
}

@test:Config
function cardLinksToOneWso2SharePage() returns error? {
    json card = check buildCard({campaignId: "c1", title: "T", summary: (), imageUrl: (), isPriority: false},
            "https://one.wso2.com/amplify/celebrate/", "https://media.wso2.com/amplify-avatar.png");
    json[] cards = <json[]>check card.cardsV2;
    json[] sections = <json[]>check cards[0].card.sections;
    json[] widgets = <json[]>check sections[0].widgets;
    json[] buttons = <json[]>check widgets[0].buttonList.buttons;
    test:assertEquals(check buttons[0].onClick.openLink.url, "https://one.wso2.com/amplify/celebrate?share=c1");
    test:assertEquals(check cards[0].card.header.imageUrl, "https://media.wso2.com/amplify-avatar.png");
}

@test:Config
function noveraNotificationHasAnAmplifyButtonToTheSharePageAndKeepsOnlyAnHttpsIcon() {
    NoveraNotification n = buildNoveraNotification(
            {campaignId: "c1", title: "T", summary: "S", imageUrl: (), isPriority: true},
            "https://one.wso2.com/amplify/celebrate/", "https://media.wso2.com/amplify-avatar.png");
    test:assertEquals(n.'source, "amplify");
    test:assertEquals(n.button.url, "https://one.wso2.com/amplify/celebrate?share=c1");
    test:assertEquals(n.button.label, "Amplify");
    test:assertEquals(n.subtitle, "Amplify · Priority");
    test:assertEquals(n.iconUrl, "https://media.wso2.com/amplify-avatar.png");
    test:assertFalse(buildNoveraNotification({campaignId: "c1", title: "T", summary: (), imageUrl: (),
            isPriority: false}, "https://x.example", "http://insecure.example/a.png").hasKey("iconUrl"));
}

@test:Config
function noveraNotificationPicksThePostImageThenTheDefaultAndOnlyWhenChatCanFetchIt() {
    string own = "https://media.wso2.com/leader.png";
    string fallback = "https://media.wso2.com/default.png";
    NoveraNotification withOwn = buildNoveraNotification(
            {campaignId: "c1", title: "T", summary: "S", imageUrl: own, isPriority: false}, "https://x.example",
            (), fallback);
    test:assertEquals(withOwn.imageUrl, own);
    // A private host or plain http can't be fetched by Chat: the default image stands in.
    NoveraNotification unusable = buildNoveraNotification(
            {campaignId: "c1", title: "T", summary: "S", imageUrl: "https://intranet.local/a.png", isPriority: false},
            "https://x.example", (), fallback);
    test:assertEquals(unusable.imageUrl, fallback);
    // Neither usable: no image at all.
    test:assertFalse(buildNoveraNotification({campaignId: "c1", title: "T", summary: "S", imageUrl: (),
            isPriority: false}, "https://x.example").hasKey("imageUrl"));
}

@test:Config
function noveraNotificationCutsToNoveraLimitsAndFillsAnEmptySummary() {
    string long = string:'join("", from int i in 0 ..< 6000 select "x");
    NoveraNotification n = buildNoveraNotification(
            {campaignId: "c1", title: long, summary: long, imageUrl: (), isPriority: false}, "https://x.example");
    test:assertEquals(n.title.length(), 300);
    test:assertEquals(n.body.length(), 5000);
    NoveraNotification blank = buildNoveraNotification(
            {campaignId: "c1", title: "T", summary: "  ", imageUrl: (), isPriority: false}, "https://x.example");
    test:assertEquals(blank.body, "A new post is ready to share.");
}
