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

# Queues the Novera announcement for a campaign. Announced exactly once: a second queue is refused.
#
# + existing - Current announcement row, if any
# + campaignId - Campaign
# + outboxId - `CampaignRegistered` outbox id
# + now - Current time
# + return - The queued announcement, or `ALREADY_ANNOUNCED`
public isolated function queueAnnouncement(Announcement? existing, string campaignId, int outboxId, time:Utc now)
        returns Announcement|types:DomainError {
    if existing !is () {
        return types:domainError(types:ERR_ALREADY_ANNOUNCED, "This campaign was already announced");
    }
    return {
        campaignId,
        outboxId,
        space: NOVERA_SPACE,
        idempotencyKey: announcementKey(campaignId),
        messageName: (),
        queuedAt: now,
        sentAt: (),
        failedAt: (),
        lastError: ()
    };
}

# The key Novera gets as `Idempotency-Key` for a campaign's announcement: the same on every retry.
#
# + campaignId - Campaign
# + return - `amplify:{campaignId}`
public isolated function announcementKey(string campaignId) returns string => NOVERA_SOURCE + ":" + campaignId;

# Records an announcement Novera accepted.
#
# + announcement - Queued announcement
# + messageName - Delivery marker (`novera:{campaignId}`)
# + now - Current time
# + return - The sent announcement, or `ANNOUNCEMENT_NOT_QUEUED`
public isolated function markSent(Announcement announcement, string messageName, time:Utc now)
        returns Announcement|types:DomainError {
    check ensureQueued(announcement);
    Announcement sent = announcement.clone();
    sent.sentAt = now;
    sent.messageName = messageName;
    sent.lastError = ();
    return sent;
}

# Records a failed announcement (Novera refused it, or retries ran out).
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

# Admin retry (`POST /admin/announcements/{id}/retry`): only a `FAILED` announcement is re-queued.
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
# + return - The notification: icon, title, subtitle, picture, summary and an Amplify button
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
            label: CARD_BUTTON_TEXT}
    };
    if iconUrl is string && iconUrl.startsWith("https://") {
        n.iconUrl = iconUrl;
    }
    string? imageUrl = campaign.imageUrl;
    if imageUrl is string && types:isPublicHttpsUrl(imageUrl) {
        n.imageUrl = imageUrl;
    } else if defaultImageUrl is string && types:isPublicHttpsUrl(defaultImageUrl) {
        n.imageUrl = defaultImageUrl;
    }
    return n;
}

isolated function cutTo(string text, int max) returns string => text.length() <= max ? text : text.substring(0, max);
