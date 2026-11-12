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
# + noveraNotificationId - Novera's broadcast id, when it returned one
# + return - The sent announcement, or `ANNOUNCEMENT_NOT_QUEUED`
public isolated function markSent(Announcement announcement, string messageName, time:Utc now,
        string? noveraNotificationId = ()) returns Announcement|types:DomainError {
    check ensureQueued(announcement);
    Announcement sent = announcement.clone();
    sent.sentAt = now;
    sent.messageName = messageName;
    sent.lastError = ();
    sent.noveraNotificationId = noveraNotificationId is string && isNoveraId(noveraNotificationId)
        ? noveraNotificationId : ();
    return sent;
}

# Whether a value is safe as a Novera reference or broadcast id: 1-100 letters, digits, `.`, `_`, `:` or `-`, the
# shape both sides check (it goes into a URL path as is).
#
# + value - Candidate
# + return - True when it fits
public isolated function isNoveraId(string value) returns boolean => re `[A-Za-z0-9._:-]{1,100}`.isFullMatch(value);

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

# Records that a send is about to start: the attempt marker is saved before Novera is called, so a later run can
# tell that an earlier attempt may already have reached Novera (Novera doesn't dedupe; owner decision 2026-11-03).
#
# + announcement - Queued announcement
# + now - Current time
# + return - The announcement carrying the marker, or `ANNOUNCEMENT_NOT_QUEUED`
public isolated function markAttempted(Announcement announcement, time:Utc now) returns Announcement|types:DomainError {
    check ensureQueued(announcement);
    Announcement attempted = announcement.clone();
    attempted.attemptedAt = now;
    return attempted;
}

# Clears the attempt marker after a call that definitely sent nothing (the token endpoint or an open breaker
# stopped it before the request, or Novera answered 401, 403, 429 or 503), so the automatic retry may send.
#
# + announcement - Queued announcement carrying the marker
# + return - The announcement without the marker, or `ANNOUNCEMENT_NOT_QUEUED`
public isolated function clearAttempt(Announcement announcement) returns Announcement|types:DomainError {
    check ensureQueued(announcement);
    Announcement cleared = announcement.clone();
    cleared.attemptedAt = ();
    return cleared;
}

# True when a queued announcement carries the attempt marker: an earlier attempt may have reached Novera.
#
# + announcement - Announcement
# + return - True when queued with `attemptedAt` set
public isolated function hasUnfinishedAttempt(Announcement announcement) returns boolean =>
    announcementStatus(announcement) == QUEUED && announcement.attemptedAt !is ();

# Fails an announcement whose delivery can't be known (an earlier attempt may have reached Novera, or the call
# lost its answer). It is never sent again automatically: a person checks Novera and uses the admin retry only if
# the card did not go out. The attempt marker stays as evidence.
#
# + announcement - Queued announcement
# + now - Current time
# + reason - Safe text for why the outcome is unknown
# + return - The failed announcement (`lastError` starts with `Delivery unknown:`), or `ANNOUNCEMENT_NOT_QUEUED`
public isolated function markDeliveryUnknown(Announcement announcement, time:Utc now,
        string reason = "an earlier attempt may have reached Novera") returns Announcement|types:DomainError {
    return markFailed(announcement, string `${DELIVERY_UNKNOWN} ${reason}; check Novera before retrying`, now);
}

# Admin retry (`POST /admin/announcements/{id}/retry`): only a `FAILED` announcement is re-queued. Retrying is the
# person's decision to send again, so both the failure and the attempt marker are cleared.
#
# + announcement - Failed announcement
# + return - The re-queued announcement, or `ANNOUNCEMENT_NOT_FAILED`
public isolated function retryAnnouncement(Announcement announcement) returns Announcement|types:DomainError {
    if announcementStatus(announcement) != FAILED {
        return types:domainError(types:ERR_ANNOUNCEMENT_NOT_FAILED, "Only a failed announcement can be retried");
    }
    Announcement queued = announcement.clone();
    queued.failedAt = ();
    queued.attemptedAt = ();
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
# + buttonUrlTemplate - The button's link (`noveraButtonUrl`): every `{campaignId}` is replaced with the campaign id
# + iconUrl - Icon beside the title, kept only when it is https
# + defaultImageUrl - Picture used when the campaign's own image is missing or unusable (Chat fetches it, so it
# must be public https)
# + withReference - Send the campaign id as `reference`, so Novera counts who has seen the card. Only for a Novera
# that knows the field: an older one refuses the whole card
# + return - The notification: icon, title, subtitle, picture, summary and an Amplify button, or
# `INVALID_BUTTON_URL` when the template can't give a link (never a card without a button)
public isolated function buildNoveraNotification(CampaignCardSource campaign, string buttonUrlTemplate,
        string? iconUrl = (), string? defaultImageUrl = (), boolean withReference = false)
        returns NoveraNotification|types:DomainError {
    string buttonUrl = check buttonUrlFor(buttonUrlTemplate, campaign.campaignId);
    string? summary = campaign.summary;
    string body = summary is () || summary.trim() == "" ? "A new post is ready to share." : summary.trim();
    NoveraNotification n = {
        'source: NOVERA_SOURCE,
        title: cutTo(campaign.title.trim(), NOVERA_LINE_MAX),
        subtitle: campaign.isPriority ? "Amplify · Priority" : "Amplify",
        body: cutTo(body, NOVERA_BODY_MAX),
        button: {url: buttonUrl, label: CARD_BUTTON_TEXT}
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
    if withReference && isNoveraId(campaign.campaignId) {
        n.reference = campaign.campaignId;
    }
    return n;
}

# Checks a button URL template (`noveraButtonUrl`): an https URL (http only when the local stack allows it) that
# contains `{campaignId}` and no other braces or whitespace.
#
# + template - The template
# + allowInsecureHttp - Local stack only: accept an http URL
# + return - `INVALID_BUTTON_URL` naming the problem, or `()`
public isolated function checkButtonUrlTemplate(string template, boolean allowInsecureHttp = false)
        returns types:DomainError? {
    string lower = template.toLowerAscii();
    if !lower.startsWith("https://") && !(allowInsecureHttp && lower.startsWith("http://")) {
        return types:domainError(ERR_INVALID_BUTTON_URL, allowInsecureHttp
            ? "The button URL must start with https:// or http://" : "The button URL must start with https://");
    }
    _ = check buttonUrlFor(template, "00000000-0000-0000-0000-000000000000");
}

# The button's link for one campaign: `{campaignId}` replaced, and nothing left that looks like a placeholder.
#
# + template - The template
# + campaignId - Campaign id (a uuid)
# + return - The link, or `INVALID_BUTTON_URL`
isolated function buttonUrlFor(string template, string campaignId) returns string|types:DomainError {
    string trimmed = template.trim();
    if trimmed == "" {
        return types:domainError(ERR_INVALID_BUTTON_URL, "The button URL is not configured");
    }
    string lower = trimmed.toLowerAscii();
    if !lower.startsWith("https://") && !lower.startsWith("http://") {
        return types:domainError(ERR_INVALID_BUTTON_URL, "The button URL must be an http(s) URL");
    }
    if !trimmed.includes(BUTTON_URL_PLACEHOLDER) {
        return types:domainError(ERR_INVALID_BUTTON_URL, "The button URL must contain " + BUTTON_URL_PLACEHOLDER);
    }
    string url = re `\{campaignId\}`.replaceAll(trimmed, campaignId);
    if url.includes("{") || url.includes("}") || re `\s`.find(url) !is () {
        return types:domainError(ERR_INVALID_BUTTON_URL,
            "The button URL may contain no braces other than " + BUTTON_URL_PLACEHOLDER + " and no spaces");
    }
    return url;
}

isolated function cutTo(string text, int max) returns string => text.length() <= max ? text : text.substring(0, max);
