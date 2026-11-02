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

import amplify_common.googlechat;
import amplify_common.types;

import ballerina/time;

# Announcement status from its facts.
#
# + announcement - Announcement
# + return - `SENT` if sent; `FAILED` if failed; else `QUEUED`
public isolated function announcementStatus(Announcement announcement) returns AnnouncementStatus {
    if announcement.sentAt !is () {
        return SENT;
    }
    if announcement.failedAt !is () {
        return FAILED;
    }
    return QUEUED;
}

# Queues the Club card for a campaign. Announced exactly once: a second queue is refused.
#
# + existing - Current announcement row, if any
# + campaignId - Campaign
# + outboxId - `CampaignRegistered` outbox id
# + space - Target space
# + now - Current time
# + return - The queued announcement, or `ALREADY_ANNOUNCED`
public isolated function queueAnnouncement(Announcement? existing, string campaignId, int outboxId, string space,
        time:Utc now) returns Announcement|types:DomainError {
    if existing !is () {
        return types:domainError(types:ERR_ALREADY_ANNOUNCED, "This campaign was already announced");
    }
    return {
        campaignId,
        outboxId,
        space,
        threadKey: googlechat:threadKey(campaignId),
        chatMessageName: (),
        queuedAt: now,
        sentAt: (),
        failedAt: (),
        lastError: ()
    };
}

# Records a sent card.
#
# + announcement - Queued announcement
# + chatMessageName - Name Chat returned
# + now - Current time
# + chatThreadName - Thread name Chat returned, if any
# + return - The sent announcement, or `ANNOUNCEMENT_NOT_QUEUED`
public isolated function markSent(Announcement announcement, string chatMessageName, time:Utc now,
        string? chatThreadName = ()) returns Announcement|types:DomainError {
    check ensureQueued(announcement);
    Announcement sent = announcement.clone();
    sent.sentAt = now;
    sent.chatMessageName = chatMessageName;
    sent.chatThreadName = chatThreadName;
    sent.lastError = ();
    return sent;
}

# Records a failed card after retries ran out.
#
# + announcement - Queued announcement
# + lastError - Safe error text
# + now - Current time
# + return - The failed announcement, or `ANNOUNCEMENT_NOT_QUEUED`
public isolated function markFailed(Announcement announcement, string lastError, time:Utc now)
        returns Announcement|types:DomainError {
    check ensureQueued(announcement);
    Announcement failed = announcement.clone();
    failed.failedAt = now;
    failed.lastError = lastError;
    return failed;
}

# Admin retry (`POST /admin/announcements/{id}/retry`): only a `FAILED` card is re-queued.
#
# + announcement - Failed announcement
# + return - The re-queued announcement, or `ANNOUNCEMENT_NOT_FAILED`
public isolated function retryAnnouncement(Announcement announcement) returns Announcement|types:DomainError {
    if announcementStatus(announcement) != FAILED {
        return types:domainError(types:ERR_ANNOUNCEMENT_NOT_FAILED, "Only a failed announcement can be retried");
    }
    Announcement queued = announcement.clone();
    queued.failedAt = ();
    return queued;
}

# Builds the Club card: image, title, summary and an Amplify button that opens One WSO2's Celebrate page with
# the campaign's share dialog (`?share=<campaignId>`).
#
# + campaign - Campaign fields
# + sharePageBaseUrl - One WSO2 Celebrate page URL, for example `https://one.wso2.com/amplify/celebrate`
# + avatarUrl - Public HTTPS Amplify avatar for the card header, or `()`
# + defaultImageUrl - Public HTTPS image used when the campaign's own image is missing or unusable, or `()`
# + return - cardsV2 JSON, or a domain error
public isolated function buildCard(CampaignCardSource campaign, string sharePageBaseUrl, string? avatarUrl = (),
        string? defaultImageUrl = ()) returns json|types:DomainError {
    string base = sharePageBaseUrl.endsWith("/") ? sharePageBaseUrl.substring(0, sharePageBaseUrl.length() - 1)
        : sharePageBaseUrl;
    return googlechat:buildCampaignCard({
        campaignId: campaign.campaignId,
        title: campaign.title,
        summary: campaign.summary,
        imageUrl: campaign.imageUrl,
        sharePageUrl: string `${base}${base.includes("?") ? "&" : "?"}share=${campaign.campaignId}`,
        isPriority: campaign.isPriority,
        avatarUrl,
        defaultImageUrl
    });
}

isolated function ensureQueued(Announcement announcement) returns types:DomainError? {
    if announcementStatus(announcement) != QUEUED {
        return types:domainError(types:ERR_ANNOUNCEMENT_NOT_QUEUED, "The announcement isn't queued");
    }
    return ();
}

# Builds the Novera notification for a campaign. Text is cut to Novera's field limits instead of rejected, so a
# long title never blocks an announcement.
#
# + campaign - Campaign
# + sharePageBaseUrl - One WSO2 Celebrate page; the link adds `?share=<campaignId>`
# + iconUrl - Icon beside the title, kept only when it is https
# + defaultImageUrl - Picture used when the campaign's own image is missing or unusable (Chat fetches it, so it
# must be public https)
# + return - The notification: icon, title, subtitle, picture, summary and an Amplify button, like the Club card
public isolated function buildNoveraNotification(CampaignCardSource campaign, string sharePageBaseUrl,
        string? iconUrl = (), string? defaultImageUrl = ()) returns NoveraNotification {
    string base = sharePageBaseUrl.endsWith("/") ? sharePageBaseUrl.substring(0, sharePageBaseUrl.length() - 1)
        : sharePageBaseUrl;
    string? summary = campaign.summary;
    string body = summary is () || summary.trim() == "" ? "A new post is ready to share." : summary.trim();
    NoveraNotification n = {
        'source: NOVERA_SOURCE,
        title: cutTo(campaign.title.trim(), NOVERA_LINE_MAX),
        subtitle: campaign.isPriority ? "Amplify · Priority" : "Amplify",
        body: cutTo(body, NOVERA_BODY_MAX),
        button: {url: string `${base}${base.includes("?") ? "&" : "?"}share=${campaign.campaignId}`,
            label: googlechat:CARD_BUTTON_TEXT}
    };
    if iconUrl is string && iconUrl.startsWith("https://") {
        n.iconUrl = iconUrl;
    }
    string? imageUrl = campaign.imageUrl;
    if imageUrl is string && googlechat:isPublicHttpsUrl(imageUrl) {
        n.imageUrl = imageUrl;
    } else if defaultImageUrl is string && googlechat:isPublicHttpsUrl(defaultImageUrl) {
        n.imageUrl = defaultImageUrl;
    }
    return n;
}

isolated function cutTo(string text, int max) returns string => text.length() <= max ? text : text.substring(0, max);
