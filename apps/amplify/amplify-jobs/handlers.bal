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
    NoveraPort? novera;
    linkedin:ProviderAdapter? linkedIn;
    crypto:TokenCipher? cipher;
    LinkedInBudget budget;
    # True when a RETRY now would exhaust `maxAttempts`: the handler records the domain failure instead
    boolean finalAttempt;
    time:Utc now;
|};

# LinkedIn posts this run may still make (per-run and per-day ceilings), and whether posting halted because
# several members were refused the same way.
isolated class LinkedInBudget {
    private int remaining;
    private int usedCount = 0;
    # Members refused with a 403, by refusal key (`code|serviceErrorCode`)
    private map<string[]> refusedMembers = {};
    private string? haltedOn = ();

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

    # Records a 403 for a member. Once `SAME_REFUSAL_HALT_MEMBERS` distinct members got the same refusal, posting
    # halts for the rest of the run.
    #
    # + refusal - Refusal key (`code|serviceErrorCode`)
    # + memberUrn - Member the call was made for
    # + return - True when this refusal halted the run
    isolated function recordRefusal(string refusal, string memberUrn) returns boolean {
        lock {
            if self.haltedOn !is () {
                return false;
            }
            string[] members = self.refusedMembers[refusal] ?: [];
            if members.indexOf(memberUrn) is () {
                members.push(memberUrn);
            }
            self.refusedMembers[refusal] = members;
            if members.length() >= SAME_REFUSAL_HALT_MEMBERS {
                self.haltedOn = refusal;
                return true;
            }
            return false;
        }
    }

    # + return - The refusal key posting halted on, or `()` while posting goes on
    isolated function halted() returns string? {
        lock {
            return self.haltedOn;
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
        events:CONNECTION_REVOKED => {
            events:ConnectionRevoked event = check ctx.row.payload.cloneWithType();
            return failSharesForLostConnection(ctx, event.employeeId, event.revokedAt);
        }
        events:CONNECTION_REMOVED => {
            events:ConnectionRemoved event = check ctx.row.payload.cloneWithType();
            return failSharesForLostConnection(ctx, event.employeeId, event.removedAt);
        }
        events:EXTERNAL_SHARE_APPROVED|events:EXTERNAL_SHARE_AMPLIFIED => {
            // amplify-api already wrote the award in the decision's transaction (ADR-024 item 1). Scoring
            // again here would only hit `ON CONFLICT DO NOTHING`, so the row is acknowledged as is.
            return done("scored by amplify-api in the decision transaction (ADR-024)");
        }
    }
    // Every other event (CampaignAnnounced, ConnectionReady, RepostFailed, Points*,
    // ExternalShareSubmitted/Rejected) has no phase 1 subscriber.
    return done("no phase 1 subscriber");
}

// ---- CampaignRegistered → Novera announcement (M6a, B8) ----------------------------------------------
//
// At most one card per campaign (owner decision 2026-11-03: Novera does not dedupe on `Idempotency-Key`, so Amplify
// must). The attempt marker (`announcement.attempted_at`) is saved before Novera is called and cleared only when
// the call definitely sent nothing. A queued row that still carries it on a later run (a crash after the call, a
// lost answer, or a failed save after Novera accepted) may already have reached Novera: it is failed as
// "Delivery unknown" for a person to check, never sent again automatically. The admin retry is that person's
// decision to send again and clears the marker.

isolated function handleCampaignRegistered(HandlerContext ctx, events:CampaignRegistered event) returns Outcome|error {
    if !ctx.settings.announcementsEnabled {
        return deferFor(ctx.config.deferSeconds, "announcements.enabled is off");
    }
    // Novera is the one announcement channel. Off (`AMPLIFY_ON_NOVERA=false`) or not configured: the row waits.
    NoveraPort? novera = ctx.novera;
    if novera is () {
        return deferFor(ctx.config.deferSeconds, "Novera is off or not configured");
    }
    // A card never goes out without its button: no link configured, the row waits too.
    if ctx.config.noveraButtonUrl.trim() == "" {
        return deferFor(ctx.config.deferSeconds, "Novera button URL is not configured");
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
        queued = check announcements:queueAnnouncement((), c.id, ctx.row.id, ctx.now);
        check ctx.store.insertAnnouncement(queued);
    } else {
        announcements:AnnouncementStatus current = announcements:announcementStatus(existing);
        if current == announcements:SENT {
            return done("already announced");
        }
        if current == announcements:FAILED {
            // The admin retry resets the outbox row's attempts, so it is claimed as attempt 1. A FAILED announcement
            // on a later attempt is this row coming back after its failure was saved but the row wasn't finished (a
            // crash or a failed outbox write): sending now could be a second card.
            if ctx.row.attempts > 1 {
                return failed("announcement already failed; waiting for an admin retry");
            }
            // FAILED and re-queued by the admin retry (ADR-024 item 2): the person decided to send again, so the
            // failure and the attempt marker are cleared.
            queued = check announcements:retryAnnouncement(existing);
        } else if announcements:hasUnfinishedAttempt(existing) {
            // An earlier attempt may have reached Novera: never send a second card on a guess.
            announcements:Announcement unknown = check announcements:markDeliveryUnknown(existing, ctx.now);
            check ctx.store.saveAnnouncement(unknown, []);
            log:printWarn("Novera announcement delivery unknown; manual check needed", outboxId = ctx.row.id,
                    correlationId = ctx.correlationId);
            return failed(unknown.lastError ?: announcements:DELIVERY_UNKNOWN);
        } else {
            queued = existing;
        }
    }

    announcements:CampaignCardSource campaignSource = {campaignId: c.id, title: c.title, summary: c.summary,
        imageUrl: c.imageUrl, isPriority: c.isPriority};
    announcements:NoveraNotification|types:DomainError notification = announcements:buildNoveraNotification(
            campaignSource, ctx.config.noveraButtonUrl, ctx.config.cardAvatarUrl, ctx.config.defaultImageUrl);
    if notification is types:DomainError {
        // Start-up validation refuses a bad template, so this is only a guard: nothing is sent.
        return deferFor(ctx.config.deferSeconds, "Novera button URL is invalid");
    }

    // The marker is durable before the call. If it can't be saved, nothing was sent and the row simply retries.
    announcements:Announcement attempted = check announcements:markAttempted(queued, ctx.now);
    error? marked = ctx.store.saveAnnouncement(attempted, []);
    if marked is error {
        log:printWarn("Novera attempt marker could not be saved; nothing sent", 'error = resilience:loggable(marked),
                correlationId = ctx.correlationId);
        return retryLater("attempt marker could not be saved; nothing sent");
    }
    // The stored key goes out on every attempt, in case Novera ever honours `Idempotency-Key`.
    NoveraError? rejected = novera.notify(notification, attempted.idempotencyKey, ctx.correlationId);
    if rejected is NoveraError {
        NoveraErrorDetail d = rejected.detail();
        string note = string `Novera ${d.code} (HTTP ${d.httpStatus.toString()})`;
        if d.delivered == "UNKNOWN" {
            // The request may have reached Novera (no answer, or a 5xx other than 503): no automatic retry.
            announcements:Announcement unknown = check announcements:markDeliveryUnknown(attempted, ctx.now,
                    string `${note}, the card may have gone out`);
            check ctx.store.saveAnnouncement(unknown, []);
            log:printWarn("Novera announcement delivery unknown; manual check needed", outboxId = ctx.row.id,
                    correlationId = ctx.correlationId);
            return failed(unknown.lastError ?: note);
        }
        // Definitely not sent: clear the marker so the retry (or the admin retry) may send.
        announcements:Announcement cleared = check announcements:clearAttempt(attempted);
        if d.retryable && !ctx.finalAttempt {
            check ctx.store.saveAnnouncement(cleared, []);
            return retryLater(note);
        }
        check ctx.store.saveAnnouncement(check announcements:markFailed(cleared, note, ctx.now), []);
        return failed(note);
    }
    // Novera answers 202 before it sends, so there is no message name: a stable marker stands in. If this save
    // fails, the row retries and finds the attempt marker (case "delivery unknown"), so there is no second card.
    announcements:Announcement done = check announcements:markSent(attempted,
        string `${announcements:NOVERA_SPACE}:${c.id}`, ctx.now);
    check ctx.store.saveAnnouncement(done, [announcements:campaignAnnouncedEvent(done)]);
    return {kind: DONE, note: "announced"};
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
    // Mentions are read before the budget and the in-flight marker: a store error here means nothing was sent, so
    // the row simply retries (through `dispatch`) without a used-up post or a marker that would fail it next run.
    map<linkedin:MentionTarget> mentions = check resolveMentions(ctx, share.commentary);
    string? haltedOn = ctx.budget.halted();
    if haltedOn is string {
        return deferFor(ctx.config.deferSeconds, string `LinkedIn posting halted this run (${haltedOn})`);
    }
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
        mentions,
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
    int? serviceCode = d.serviceErrorCode;
    if d.httpStatus == 403 {
        // The same 403 for several members in one run is about the app, not their grants: halt posting for the
        // rest of the run, and don't revoke this member's connection or fail the share on it.
        string refusal = string `${d.code}|${serviceCode is int ? serviceCode.toString() : "-"}`;
        if ctx.budget.recordRefusal(refusal, conn.memberUrn) {
            log:printError("LinkedIn refused several members with the same 403; posting halted for this run. "
                    + "Check the app's LinkedIn products and permissions", refusal = refusal,
                    members = SAME_REFUSAL_HALT_MEMBERS, correlationId = ctx.correlationId);
            return deferFor(ctx.config.deferSeconds, string `LinkedIn posting halted this run (${refusal})`);
        }
    }
    if d.code == linkedin:UNAUTHORIZED || d.code == linkedin:FORBIDDEN {
        // 401: token expired or revoked by the member at LinkedIn. `FORBIDDEN` is only the 403 whose body says the
        // member's token lacks the permission (`ACCESS_DENIED`; a member post needs only `w_member_social`), so
        // the grant is no longer good either. Any other 403 is `REJECTED` and falls through to
        // `PROVIDER_REJECTED` below without touching the connection. The connection is revoked and its token row
        // deleted, so `GET /me` asks for a re-link (B9); this share fails with it, and `ConnectionRevoked` fails
        // the employee's other queued shares.
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
    return failShare(ctx, cleared, types:PROVIDER_REJECTED, serviceCode is int ? serviceCode.toString() : d.code, note);
}

# Resolves the mention tokens in a share's commentary to what Amplify holds: linked colleagues (member URN, and
# the LinkedIn name when known) and the configured company page. A token whose ref doesn't resolve (not linked,
# removed, unknown org) is left out, so the adapter writes it as plain text. The ref is all that is used from the
# token: names and URNs never come from the commentary.
#
# + ctx - Context
# + commentary - Commentary with mention tokens
# + return - Targets by ref, or a store error
isolated function resolveMentions(HandlerContext ctx, string? commentary) returns map<linkedin:MentionTarget>|error {
    map<linkedin:MentionTarget> targets = {};
    if commentary is () {
        return targets;
    }
    types:EmployeeId[] people = [];
    foreach types:MentionToken token in types:mentionTokens(commentary) {
        [string, string]? parts = types:splitMentionRef(token.ref);
        if parts is () {
            continue;
        }
        var [kind, key] = parts;
        if kind == types:MENTION_ORG {
            linkedin:MentionTarget? org = ctx.config.orgMentions[token.ref];
            if org is linkedin:MentionTarget {
                targets[token.ref] = org;
            }
        } else if people.indexOf(key) is () {
            people.push(key);
        }
    }
    if people.length() == 0 {
        return targets;
    }
    foreach connection:MentionableMember member in check ctx.store.mentionable(people) {
        string? name = connection:mentionName(member);
        if name is string {
            targets[types:MENTION_PERSON + ":" + member.employeeId] = {name, urn: member.memberUrn};
        }
    }
    return targets;
}

# `ConnectionRevoked` / `ConnectionRemoved`: the employee's queued shares can't be posted any more, so they fail
# with `NEEDS_RECONNECT` and the UI asks for a re-link. Only shares requested at or before the loss fail: when
# the event is handled late, the employee may have re-linked and queued new shares since. If the connection is
# usable again now, nothing fails. A share carrying the in-flight marker may already be on LinkedIn; it is left
# for the publish path's manual review instead.
#
# + ctx - Context
# + employeeId - Employee whose connection was lost
# + lostAtText - The event's `revokedAt` / `removedAt`
# + return - Outcome, or a store error (the outbox retries)
isolated function failSharesForLostConnection(HandlerContext ctx, types:EmployeeId employeeId, string lostAtText)
        returns Outcome|error {
    connection:LinkedInConnection? current = check ctx.store.connection(employeeId);
    if connection:canShare(current, ctx.now, ctx.settings.reminderDays) {
        return done("connection usable again; queued shares left to publish");
    }
    time:Utc|error parsedLostAt = time:utcFromString(lostAtText);
    time:Utc lostAt;
    if parsedLostAt is error {
        // Never expected (the event is written with `time:utcToString`): fall back to now, the old behaviour.
        log:printWarn("Lost-connection event time could not be read; using now", correlationId = ctx.correlationId);
        lostAt = ctx.now;
    } else {
        lostAt = parsedLostAt;
    }
    int failedCount = 0;
    foreach sharing:ShareRequest share in check ctx.store.queuedShares(employeeId) {
        if share.lastErrorCode == PUBLISH_IN_FLIGHT {
            continue;
        }
        if types:isBefore(lostAt, share.requestedAt) {
            // Requested after the loss: the publish path checks the connection when it gets there.
            continue;
        }
        sharing:ShareRequest? failedShare = sharing:failForLostConnection(share, ctx.now);
        if failedShare is sharing:ShareRequest {
            error? saved = ctx.store.updateShare(failedShare, share.version, [sharing:repostFailedEvent(failedShare)]);
            if saved is error && !isVersionConflict(saved) {
                return saved;
            }
            // A version conflict means the publish path moved the row meanwhile; that path settles it.
            failedCount += saved is () ? 1 : 0;
        }
    }
    return done(string `connection lost: ${failedCount} queued share(s) failed NEEDS_RECONNECT`);
}

isolated function isVersionConflict(error err) returns boolean =>
    err is types:DomainError && err.detail().code == types:ERR_VERSION_CONFLICT;

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
