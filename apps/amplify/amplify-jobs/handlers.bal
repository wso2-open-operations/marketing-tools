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

// Outbox handlers (plan M6). Each one is idempotent: it re-reads the aggregate and does nothing when the
// work is already done, so a rerun, a stale-lock release or a duplicate trigger never posts twice or
// awards twice (the ledger reference and the engagement unique keys are the last line).

import amplify_common.crypto;
import amplify_common.events;
import amplify_common.googlechat;
import amplify_common.linkedin;
import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/log;
import ballerina/time;

# What one handler call sees.
type HandlerContext record {|
    Store store;
    store:OutboxRow row;
    string correlationId;
    RunSettings settings;
    RunConfig config;
    ChatPort? chat;
    NoveraPort? novera = ();
    linkedin:ProviderAdapter? linkedIn;
    crypto:TokenCipher? cipher;
    LinkedInBudget budget;
    # True when a RETRY now would exhaust `maxAttempts`: the handler records the domain failure instead
    boolean finalAttempt;
    time:Utc now;
|};

# LinkedIn posts this run may still make (per-run and per-day ceilings).
isolated class LinkedInBudget {
    private int remaining;
    private int usedCount = 0;

    isolated function init(int remaining) {
        self.remaining = remaining < 0 ? 0 : remaining;
    }

    # Takes one post from the budget.
    #
    # + return - False when the ceiling is reached
    isolated function take() returns boolean {
        lock {
            if self.remaining <= 0 {
                return false;
            }
            self.remaining -= 1;
            self.usedCount += 1;
            return true;
        }
    }

    isolated function used() returns int {
        lock {
            return self.usedCount;
        }
    }
}

# Routes a row to its handler. Unexpected errors become RETRY (FAIL on the last attempt).
#
# + ctx - Context
# + return - Outcome
isolated function dispatch(HandlerContext ctx) returns Outcome {
    Outcome|error outcome = route(ctx);
    if outcome is error {
        error safe = resilience:loggable(outcome);
        log:printError(string `Handler error for outbox ${ctx.row.id} (${ctx.row.eventType})`, safe,
                correlationId = ctx.correlationId);
        string note = string `${ctx.row.eventType} handler error: ${safe.message()}`;
        return ctx.finalAttempt ? failed(note) : retryLater(note);
    }
    return outcome;
}

isolated function route(HandlerContext ctx) returns Outcome|error {
    match ctx.row.eventType {
        events:CAMPAIGN_REGISTERED => {
            return handleCampaignRegistered(ctx, check ctx.row.payload.cloneWithType());
        }
        events:REPOST_REQUESTED => {
            return handleRepostRequested(ctx, check ctx.row.payload.cloneWithType());
        }
        events:ENGAGEMENT_RECORDED => {
            return handleEngagementRecorded(ctx, check ctx.row.payload.cloneWithType());
        }
        events:EXTERNAL_SHARE_APPROVED|events:EXTERNAL_SHARE_AMPLIFIED => {
            // amplify-api already wrote the award in the decision's transaction (ADR-024 item 1). Scoring
            // again here would only hit `ON CONFLICT DO NOTHING`, so the row is acknowledged as is.
            return done("scored by amplify-api in the decision transaction (ADR-024)");
        }
    }
    // Every other event (CampaignAnnounced, ConnectionReady/Revoked/Removed, RepostFailed, Points*,
    // ExternalShareSubmitted/Rejected) has no phase 1 subscriber.
    return done("no phase 1 subscriber");
}

// ---- CampaignRegistered → Club card (M6a, B8) ------------------------------------------------------

isolated function handleCampaignRegistered(HandlerContext ctx, events:CampaignRegistered event) returns Outcome|error {
    if !ctx.settings.announcementsEnabled {
        return deferFor(ctx.config.deferSeconds, "announcements.enabled is off");
    }
    // Novera (AMPLIFY_ON_NOVERA) is the primary channel when it is on: its outcome drives retry and failure.
    // The Club webhook (AMPLIFY_ON_WEBHOOK) is then best effort, so a retry never posts the same card twice.
    NoveraPort? novera = ctx.novera;
    ChatPort? chat = ctx.chat;
    if novera is () && chat is () {
        return deferFor(ctx.config.deferSeconds,
            "no announcement channel: Novera and the Google Chat webhook are off or not configured");
    }
    campaign:Campaign? c = check ctx.store.campaign(event.campaignId);
    if c is () {
        return done("campaign not found");
    }
    campaign:CampaignStatus status = campaign:campaignStatus(c, ctx.now);
    if status == campaign:ARCHIVED || status == campaign:CLOSED {
        return done(string `campaign ${status}, not announced`);
    }
    if status == campaign:SCHEDULED {
        decimal waitSeconds = time:utcDiffSeconds(c.opensAt, ctx.now);
        return deferFor(waitSeconds < 1d ? 1d : waitSeconds, "campaign not open yet");
    }

    announcements:Announcement? existing = check ctx.store.announcement(c.id);
    announcements:Announcement queued;
    if existing is () {
        string space = novera is () ? (<ChatPort>chat).space() : NOVERA_SPACE;
        queued = check announcements:queueAnnouncement((), c.id, ctx.row.id, space, ctx.now);
        check ctx.store.insertAnnouncement(queued);
    } else {
        announcements:AnnouncementStatus current = announcements:announcementStatus(existing);
        if current == announcements:SENT {
            return done("already announced");
        }
        // FAILED and re-queued by the admin retry (ADR-024 item 2): clear failed_at when it goes out.
        queued = current == announcements:FAILED ? check announcements:retryAnnouncement(existing) : existing;
    }

    announcements:CampaignCardSource campaignSource = {campaignId: c.id, title: c.title, summary: c.summary,
        imageUrl: c.imageUrl, isPriority: c.isPriority};
    string messageName;
    string? threadName = ();

    if novera is NoveraPort {
        NoveraError? rejected = novera.notify(announcements:buildNoveraNotification(campaignSource,
            ctx.config.sharePageBaseUrl, ctx.config.cardAvatarUrl, ctx.config.defaultImageUrl), ctx.correlationId);
        if rejected is NoveraError {
            string note = string `Novera ${rejected.detail().code} (HTTP ${rejected.detail().httpStatus.toString()})`;
            if rejected.detail().retryable && !ctx.finalAttempt {
                return retryLater(note);
            }
            check ctx.store.saveAnnouncement(check announcements:markFailed(queued, note, ctx.now), []);
            return failed(note);
        }
        // Novera answers 202 before it sends, so there is no Chat message name: a stable marker stands in.
        // If the save below fails after Novera accepted the notification, the outbox retries this handler and
        // Novera is notified again. Owner decision (2026-11-02): a duplicate announcement is better than a missed
        // one, and the notification carries no id Novera could dedupe on, so the retry stands.
        messageName = string `${NOVERA_SPACE}:${c.id}`;
        if chat is ChatPort {
            string? note = postClubCard(ctx, chat, campaignSource, queued.threadKey);
            if note is string {
                log:printWarn("Club webhook card failed after Novera accepted the announcement; not retried",
                    detail = note, correlationId = ctx.correlationId);
            }
        }
    } else {
        // Webhook only.
        json|types:DomainError card = announcements:buildCard(campaignSource, ctx.config.sharePageBaseUrl,
            ctx.config.cardAvatarUrl, ctx.config.defaultImageUrl);
        if card is types:DomainError {
            check ctx.store.saveAnnouncement(check announcements:markFailed(queued, card.message(), ctx.now), []);
            return failed(string `card rejected: ${card.message()}`);
        }
        googlechat:ChatMessage|googlechat:ChatError sent = (<ChatPort>chat).post(card, queued.threadKey,
            ctx.correlationId);
        if sent is googlechat:ChatError {
            string note = string `Google Chat ${sent.detail().code} (HTTP ${sent.detail().httpStatus.toString()})`;
            if sent.detail().retryable && !ctx.finalAttempt {
                return retryLater(note);
            }
            check ctx.store.saveAnnouncement(check announcements:markFailed(queued, note, ctx.now), []);
            return failed(note);
        }
        messageName = sent.name;
        threadName = sent.threadName;
    }

    announcements:Announcement done = check announcements:markSent(queued, messageName, ctx.now, threadName);
    check ctx.store.saveAnnouncement(done, [announcements:campaignAnnouncedEvent(done)]);
    return {kind: DONE, note: "announced"};
}

# Posts the Club card as the secondary channel.
#
# + return - Why it failed, or `()` when it went out
isolated function postClubCard(HandlerContext ctx, ChatPort chat, announcements:CampaignCardSource campaignSource,
        string threadKey) returns string? {
    json|types:DomainError card = announcements:buildCard(campaignSource, ctx.config.sharePageBaseUrl,
        ctx.config.cardAvatarUrl, ctx.config.defaultImageUrl);
    if card is types:DomainError {
        return string `card rejected: ${card.message()}`;
    }
    googlechat:ChatMessage|googlechat:ChatError sent = chat.post(card, threadKey, ctx.correlationId);
    return sent is googlechat:ChatError ? string `Google Chat ${sent.detail().code}` : ();
}

// ---- RepostRequested → LinkedIn (C1, B9, B14) ------------------------------------------------------

isolated function handleRepostRequested(HandlerContext ctx, events:RepostRequested event) returns Outcome|error {
    if !ctx.settings.sharingEnabled {
        return deferFor(ctx.config.deferSeconds, "sharing.enabled is off");
    }
    linkedin:ProviderAdapter? linkedIn = ctx.linkedIn;
    crypto:TokenCipher? cipher = ctx.cipher;
    if linkedIn is () || cipher is () {
        return deferFor(ctx.config.deferSeconds, "LinkedIn or token keys not configured");
    }
    sharing:ShareRequest? share = check ctx.store.share(event.campaignId, event.employeeId);
    if share is () {
        return done("share request not found");
    }
    if share.attempts != event.attempts {
        return done("superseded by a newer request round");
    }
    if sharing:ensurePublishable(share) is types:DomainError {
        // Already published (a rerun) or already failed: never post twice.
        return done(string `share already ${sharing:shareStatus(share)}`);
    }
    if share.lastErrorCode == PUBLISH_IN_FLIGHT {
        // A previous attempt wrote the in-flight marker and never cleared it: LinkedIn may already have the
        // post. Posting again could duplicate it, so fail the row for an operator to reconcile by hand.
        return failed("a previous publish attempt may already have posted; manual review required");
    }

    connection:LinkedInConnection? conn = check ctx.store.connection(event.employeeId);
    if conn is () || !connection:canShare(conn, ctx.now, ctx.settings.reminderDays) {
        return failShare(ctx, share, types:NEEDS_RECONNECT, (), "connection not usable");
    }
    connection:TokenRef? ref = conn.currentToken;
    connection:StoredToken? token = ref is () ? () : check ctx.store.token(ref);
    if token is () {
        return failShare(ctx, share, types:NEEDS_RECONNECT, (), "token row gone");
    }
    campaign:Campaign? c = check ctx.store.campaign(event.campaignId);

    // Plaintext lives only in this frame, only for the call. Never logged.
    string|error bearer = connection:openToken(cipher, token);
    if bearer is error {
        log:printError("Token could not be decrypted (key ring?)", bearer, correlationId = ctx.correlationId);
        return ctx.finalAttempt ? failShare(ctx, share, types:RETRIES_EXHAUSTED, "TOKEN_KEY", "token key missing")
            : retryLater("token could not be decrypted");
    }
    resealOnUse(ctx, cipher, token);
    // Taken only right before the call, so a share that never reaches LinkedIn doesn't use up the ceiling.
    if !ctx.budget.take() {
        return deferFor(ctx.config.deferSeconds, "LinkedIn post ceiling reached");
    }
    // Durable marker before the external call. If this attempt dies after the post (a crash, or a failed
    // record write), the next run sees it and fails the row for manual review instead of posting again.
    sharing:ShareRequest inFlight = withInFlight(share);
    check ctx.store.updateShare(inFlight, share.version, []);
    types:PostUrn|linkedin:ProviderError posted = linkedIn.publishShare(bearer, {
        authorUrn: conn.memberUrn,
        kind: share.kind,
        targetUrn: share.targetResourceUrn,
        targetUrl: c is () ? () : c.resourceUrl,
        // LinkedIn requires `content.article.title` on SHARE* posts (RC-03): the campaign's own title, not the
        // generic default.
        targetTitle: c is () ? () : c.title,
        commentary: share.commentary,
        correlationId: ctx.correlationId
    });
    if posted is linkedin:ProviderError {
        return handleLinkedInFailure(ctx, inFlight, conn, posted);
    }
    // The post is out: the published result clears the marker.
    sharing:ShareRequest publishedSource = withoutInFlight(inFlight);
    sharing:PublishResult result = check sharing:markPublished(publishedSource, posted, conn.memberUrn,
            types:newUuidV7(), ctx.now);
    error? saved = ctx.store.recordPublish(result, inFlight.version);
    if saved is error {
        if store:isUniqueViolation(saved) {
            // The post went out, but this employee's engagement for the target was already recorded (an earlier
            // round). Settle the request on that engagement instead of leaving it QUEUED for good (H-5).
            if check ctx.store.recordDuplicatePublish(result, inFlight.version) {
                return done("published; engagement already recorded");
            }
            return failShare(ctx, publishedSource, types:PROVIDER_REJECTED, "DUPLICATE_ENGAGEMENT",
                    "engagement unique key without a matching engagement");
        }
        // LinkedIn accepted the post but the record could not be written. Retrying would post again: the
        // in-flight marker stays, so the next run fails the row for manual review.
        log:printError("Published to LinkedIn but the share record could not be written; not retrying",
                resilience:loggable(saved), correlationId = ctx.correlationId);
        return failed("published to LinkedIn but the share record could not be written; manual review required");
    }
    return {kind: DONE, note: "published"};
}

# Re-seals a token row written under an older key, right after it opened (key rotation, common H4). Best
# effort: a failure is logged without token material and never fails the share; the maintenance pass
# (`POST /maintenance/partitions`) picks up whatever is left.
#
# + ctx - Context
# + cipher - Token cipher
# + token - The row that just opened
isolated function resealOnUse(HandlerContext ctx, crypto:TokenCipher cipher, connection:StoredToken token) {
    crypto:SealedToken|error? resealed = connection:resealToken(cipher, token);
    if resealed is () {
        return;
    }
    if resealed is error {
        log:printWarn("Key rotation: the row could not be re-sealed on use", correlationId = ctx.correlationId);
        return;
    }
    boolean|error updated = ctx.store.updateSeal(token, resealed);
    if updated is error {
        log:printWarn("Key rotation: re-seal on use failed; the maintenance pass retries",
                'error = resilience:loggable(updated), correlationId = ctx.correlationId);
    }
}

isolated function handleLinkedInFailure(HandlerContext ctx, sharing:ShareRequest share,
        connection:LinkedInConnection conn, linkedin:ProviderError err) returns Outcome|error {
    linkedin:ProviderErrorDetail d = err.detail();
    string note = string `LinkedIn ${d.code} (HTTP ${d.httpStatus.toString()})`;
    // The call returned an error, so it did not post: clear the in-flight marker before the row is retried or
    // failed (a retry must not read it as "may already have posted").
    sharing:ShareRequest cleared = check clearInFlight(ctx, share);
    if d.code == linkedin:UNAUTHORIZED {
        // Token expired or revoked: the connection needs a reconnect (B9) and this share fails with it.
        connection:ConnectionChange|types:DomainError change = connection:revoke(conn, ctx.now);
        if change is connection:ConnectionChange {
            check ctx.store.saveConnection(change, conn.version);
        }
        return failShare(ctx, cleared, types:NEEDS_RECONNECT, d.code, note);
    }
    // `OUTCOME_UNKNOWN` (timeout, dropped connection, 502/504) is not `retryable` in the adapter because the post may
    // be live, but the owner's decision (board thread 36, 2026-11-01) is that a lost answer leaves the row pending
    // and the outbox retries (ADR-025). The window that accepts: LinkedIn took the post and only the answer was lost,
    // so the retry can post a second time. The marker covers the other case, a failed record write after a
    // *received* acceptance, which is never retried.
    if d.retryable || d.code == linkedin:OUTCOME_UNKNOWN {
        // 429, 5xx, timeout or open breaker: the share stays QUEUED (B14) and the outbox retries.
        return ctx.finalAttempt ? failShare(ctx, cleared, types:RETRIES_EXHAUSTED, d.code, note) : retryLater(note);
    }
    int? serviceCode = d.serviceErrorCode;
    return failShare(ctx, cleared, types:PROVIDER_REJECTED, serviceCode is int ? serviceCode.toString() : d.code, note);
}

# Clears the in-flight marker after LinkedIn answered with an error (so it did not post), so a retry or a
# failure can write the share row again.
#
# + ctx - Context
# + share - The share row carrying the marker
# + return - The share with the marker cleared and the next version, or an error when the write failed
isolated function clearInFlight(HandlerContext ctx, sharing:ShareRequest share) returns sharing:ShareRequest|error {
    sharing:ShareRequest cleared = withoutInFlight(share);
    check ctx.store.updateShare(cleared, share.version, []);
    return cleared;
}

# A copy of the share row carrying the in-flight marker and the next version.
#
# + share - The share row as read
# + return - The copy to write before the call
isolated function withInFlight(sharing:ShareRequest share) returns sharing:ShareRequest {
    sharing:ShareRequest copy = {...share};
    copy.lastErrorCode = PUBLISH_IN_FLIGHT;
    copy.version = share.version + 1;
    return copy;
}

# A copy of the share row with the marker cleared, at the same version (it was written by the marker step).
#
# + share - The share row carrying the marker
# + return - The copy to write
isolated function withoutInFlight(sharing:ShareRequest share) returns sharing:ShareRequest {
    sharing:ShareRequest copy = {...share};
    copy.lastErrorCode = ();
    return copy;
}

isolated function failShare(HandlerContext ctx, sharing:ShareRequest share, types:FailureReason reason, string? code,
        string note) returns Outcome|error {
    sharing:ShareRequest failedShare = check sharing:markFailed(share, reason, code, ctx.now);
    check ctx.store.updateShare(failedShare, share.version, [sharing:repostFailedEvent(failedShare)]);
    return done(string `share failed: ${reason} (${note})`);
}

// ---- EngagementRecorded → points (C2) + recognition (B12) -------------------------------------------

isolated function handleEngagementRecorded(HandlerContext ctx, events:EngagementRecorded event) returns Outcome|error {
    time:Utc occurredAt = check time:utcFromString(event.occurredAt);
    scoring:PointRule[] rules = check ctx.store.pointRules();
    // Priced at the rule in force when the engagement happened (plan M6).
    scoring:LedgerAppend|types:DomainError award = scoring:awardForEngagement(rules, {
        engagementId: event.engagementId,
        provider: event.provider,
        targetResourceUrn: event.targetResourceUrn,
        employeeId: event.employeeId,
        action: event.action,
        campaignId: event.campaignId
    }, ctx.correlationId, occurredAt);
    if award is types:DomainError {
        return failed(string `not scored: ${award.message()}`);
    }
    // `ON CONFLICT DO NOTHING` on the reference + recognition upkeep, one transaction (B12).
    boolean inserted = check ctx.store.appendLedger(award);
    return done(inserted ? "points awarded" : "already awarded");
}
