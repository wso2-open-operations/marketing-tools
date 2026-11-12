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


// PostgreSQL reads of `announcement` for the admin screen and dashboard (M5), and the admin retry and send.
// The jobs worker owns the announcement's normal writes. A retry re-queues the announcement's `CampaignRegistered`
// outbox row (ADR-024) and, in the same transaction, clears `failed_at`, `last_error` and `attempted_at` on the
// announcement row (the person decided to send again), so the board reads Queued at once, even while the worker
// defers the row (Novera off). A send does the same for a campaign that has no announcement row yet: it makes the
// `CampaignRegistered` outbox row due now (writing it when missing) and adds a queued `announcement` row.
// Column names predate Novera: `thread_key` holds the idempotency key and `chat_message_name` the delivery marker.
// `chat_thread_name` (V011, Club webhook threads) is no longer read or written; old rows keep their value.

import amplify_common.events;
import amplify_common.types;
import amplify_domain.store;

import ballerina/sql;
import ballerina/time;
import ballerinax/postgresql;

const string ANNOUNCEMENT_TABLE = "announcement";

type AnnouncementRow record {|
    string campaign_id;
    int? outbox_id;
    string space;
    string thread_key;
    string? chat_message_name;
    time:Utc queued_at;
    time:Utc? sent_at;
    time:Utc? failed_at;
    string? last_error;
    time:Utc? attempted_at;
    string? novera_notification_id;
|};

# Persistence port for the admin side of S5.
public type AnnouncementRepository isolated object {
    # Finds a campaign's announcement.
    #
    # + campaignId - Campaign
    # + return - The announcement, `()` if none, or an error
    public isolated function findByCampaign(string campaignId) returns Announcement|error?;

    # Lists announcements, newest first.
    #
    # + status - Status filter, or `()`
    # + 'limit - Most rows
    # + return - Announcements, or an error
    public isolated function list(AnnouncementStatus? status, int 'limit) returns Announcement[]|error;

    # Puts the announcement's `CampaignRegistered` outbox row back in the queue.
    #
    # + campaignId - Campaign
    # + return - `NOT_FOUND` when there is no outbox row, or another error
    public isolated function requeue(string campaignId) returns error?;

    # Admin send: queues the announcement of a campaign that has none yet. Makes its `CampaignRegistered` outbox row
    # due now (a `PENDING` one), resets a `FAILED` one, or writes `event` when the row is missing.
    #
    # + campaignId - Campaign
    # + event - The `CampaignRegistered` outbox event to write when none exists
    # + return - `ALREADY_ANNOUNCED` when an announcement row exists, `ANNOUNCEMENT_NOT_FAILED` when the row is
    #            being sent or was sent, or another error
    public isolated function send(string campaignId, events:OutboxEvent event) returns error?;
};

# `AnnouncementRepository` over PostgreSQL.
public isolated class PgAnnouncementRepository {
    *AnnouncementRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client (`amplify_api`)
    # + actor - Who (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function findByCampaign(string campaignId) returns Announcement|error? {
        AnnouncementRow|error row = self.db->queryRow(`
            SELECT campaign_id::text AS campaign_id, outbox_id, space, thread_key, chat_message_name,
                   queued_at, sent_at, failed_at, last_error, attempted_at, novera_notification_id
            FROM announcement WHERE campaign_id = CAST(${campaignId} AS uuid)`);
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        return toAnnouncement(row);
    }

    public isolated function list(AnnouncementStatus? status, int 'limit) returns Announcement[]|error {
        sql:ParameterizedQuery cond = status is () ? `` : `WHERE status = ${status}`;
        stream<AnnouncementRow, error?> rows = self.db->query(sql:queryConcat(`
            SELECT campaign_id::text AS campaign_id, outbox_id, space, thread_key, chat_message_name,
                   queued_at, sent_at, failed_at, last_error, attempted_at, novera_notification_id
            FROM announcement_v `, cond, ` ORDER BY queued_at DESC LIMIT ${'limit}`));
        return from AnnouncementRow r in rows
            select toAnnouncement(r);
    }

    public isolated function requeue(string campaignId) returns error? =>
        store:inTransaction(isolated function () returns error? => self.requeueTx(campaignId));

    private isolated function requeueTx(string campaignId) returns error? {
        string key = events:idempotencyKey(events:CAMPAIGN_REGISTERED, campaignId);
        transaction {
            var result = check self.db->execute(`
                UPDATE messaging_outbox
                SET status = 'PENDING', attempts = 0, next_attempt_at = now(), locked_by = NULL, locked_until = NULL,
                    last_error = NULL, processed_at = NULL
                WHERE idempotency_key = ${key} AND status = 'FAILED'`);
            if result.affectedRowCount != 1 {
                // Only a FAILED row is re-queued. An IN_PROGRESS row is held by a run right now (resetting its
                // lock would let a second run send it again), and a DONE or PENDING row must stay as it
                // is: a second admin's Retry would otherwise send an announcement that already went out.
                string|sql:Error state = self.db->queryRow(`
                    SELECT status FROM messaging_outbox WHERE idempotency_key = ${key}`);
                if state is sql:NoRowsError {
                    fail types:domainError(types:ERR_NOT_FOUND, "The announcement's queue entry is gone");
                }
                if state is sql:Error {
                    fail state;
                }
                fail types:domainError(types:ERR_ANNOUNCEMENT_NOT_FAILED, state == "IN_PROGRESS"
                    ? "The card is being sent right now"
                    : state == "DONE" ? "The card was already sent" : "The card is already queued");
            }
            // The announcement row mirrors what the worker would clear on its next claim, so the board shows Queued
            // now. The attempt marker goes too: the person decided to send again.
            _ = check self.db->execute(`
                UPDATE announcement SET failed_at = NULL, last_error = NULL, attempted_at = NULL
                WHERE campaign_id = CAST(${campaignId} AS uuid)`);
            check store:writeAudit(self.db, store:auditOf(self.actor, "AnnouncementRetried", ANNOUNCEMENT_TABLE,
                    campaignId));
            check commit;
        }
    }

    public isolated function send(string campaignId, events:OutboxEvent event) returns error? {
        final events:OutboxEvent & readonly frozen = event.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.sendTx(campaignId, frozen));
    }

    private isolated function sendTx(string campaignId, events:OutboxEvent event) returns error? {
        string key = events:idempotencyKey(events:CAMPAIGN_REGISTERED, campaignId);
        transaction {
            int|sql:Error existing = self.db->queryRow(`
                SELECT 1 FROM announcement WHERE campaign_id = CAST(${campaignId} AS uuid)`);
            if existing is int {
                fail types:domainError(types:ERR_ALREADY_ANNOUNCED,
                        "This post already has an announcement; use Retry if it failed");
            }
            if !store:isNoRows(existing) {
                fail existing;
            }
            string|sql:Error state = self.db->queryRow(`
                SELECT status FROM messaging_outbox WHERE idempotency_key = ${key} FOR UPDATE`);
            if state is sql:Error && !store:isNoRows(state) {
                fail state;
            }
            if state is sql:Error {
                _ = check store:writeOutbox(self.db, [event]);
            } else if state == "PENDING" || state == "FAILED" {
                _ = check self.db->execute(`
                    UPDATE messaging_outbox
                    SET status = 'PENDING', attempts = 0, next_attempt_at = now(), locked_by = NULL,
                        locked_until = NULL, last_error = NULL, processed_at = NULL
                    WHERE idempotency_key = ${key}`);
            } else {
                fail types:domainError(types:ERR_ANNOUNCEMENT_NOT_FAILED, state == "IN_PROGRESS"
                    ? "The card is being sent right now"
                    : "The card was already sent");
            }
            // A queued announcement row, so the board reads Queued at once: without it the post stays "Not announced"
            // until a run claims the outbox row (never, while Novera is off). The worker sends a queued row that has
            // no attempt marker.
            int outboxId = check self.db->queryRow(`SELECT id FROM messaging_outbox WHERE idempotency_key = ${key}`);
            _ = check self.db->execute(`
                INSERT INTO announcement (campaign_id, outbox_id, space, thread_key)
                VALUES (CAST(${campaignId} AS uuid), ${outboxId}, ${NOVERA_SPACE}, ${announcementKey(campaignId)})
                ON CONFLICT (campaign_id) DO NOTHING`);
            check store:writeAudit(self.db, store:auditOf(self.actor, "AnnouncementSendRequested",
                    ANNOUNCEMENT_TABLE, campaignId));
            check commit;
        }
    }
}

# Jobs-side writes of `announcement` (`amplify_jobs` owns them, ADR-024). Kept off the
# `AnnouncementRepository` port, which amplify-api uses read-only.
public isolated class PgAnnouncementWriter {
    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client (`amplify_jobs`)
    # + actor - Who (audit), with the run's correlation id
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    # Inserts a queued announcement. An existing row (a rerun) is kept: PK = campaign, announced once.
    #
    # + announcement - From `queueAnnouncement`
    # + return - An error
    public isolated function insertQueued(Announcement announcement) returns error? {
        Announcement a = announcement;
        _ = check self.db->execute(`
            INSERT INTO announcement (campaign_id, outbox_id, space, thread_key, queued_at)
            VALUES (CAST(${a.campaignId} AS uuid), ${a.outboxId}, ${a.space}, ${a.idempotencyKey},
                    CAST(${store:ts(a.queuedAt)} AS timestamptz))
            ON CONFLICT (campaign_id) DO NOTHING`);
    }

    # Stores a sent, failed or attempted announcement with its events and an audit row, in one transaction. The
    # attempt marker (`attempted_at`) is written here too, so it is durable before the Novera call starts.
    #
    # + announcement - From `markAttempted` / `clearAttempt` / `markSent` / `markFailed` / `markDeliveryUnknown` /
    # `retryAnnouncement`
    # + outbox - `CampaignAnnounced` when sent
    # + return - An error
    public isolated function save(Announcement announcement, events:OutboxEvent[] outbox) returns error? {
        final readonly & Announcement a = announcement.cloneReadOnly();
        final readonly & events:OutboxEvent[] queued = outbox.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.saveTx(a, queued));
    }

    private isolated function saveTx(Announcement announcement, events:OutboxEvent[] outbox) returns error? {
        Announcement a = announcement;
        transaction {
            _ = check self.db->execute(`
                UPDATE announcement
                SET chat_message_name = ${a.messageName},
                    sent_at = CAST(${store:ts(a.sentAt)} AS timestamptz),
                    failed_at = CAST(${store:ts(a.failedAt)} AS timestamptz), last_error = ${a.lastError},
                    attempted_at = CAST(${store:ts(a.attemptedAt)} AS timestamptz),
                    novera_notification_id = ${a.noveraNotificationId}
                WHERE campaign_id = CAST(${a.campaignId} AS uuid)`);
            _ = check store:writeOutbox(self.db, outbox, self.actor.correlationId);
            string action = outbox.length() > 0 ? outbox[0].eventType
                : a.failedAt !is () ? "AnnouncementFailed"
                : a.attemptedAt !is () ? "AnnouncementAttempted" : "AnnouncementQueued";
            check store:writeAudit(self.db, store:auditOf(self.actor, action, ANNOUNCEMENT_TABLE, a.campaignId,
                    {status: announcementStatus(a), space: a.space}));
            check commit;
        }
    }
}

# Announcements whose Novera seen counts are due: sent with a Novera broadcast id inside the window, and never
# counted or counted longer ago than the refresh interval. The oldest count goes first, so one broadcast that keeps
# failing can't hold the others back for long.
#
# + db - Client (`amplify_jobs`)
# + windowDays - Only broadcasts sent this many days back or less
# + refreshSeconds - Least time between two counts of one broadcast
# + 'limit - Most rows
# + return - The due announcements, or an error
public isolated function noveraStatsDue(postgresql:Client db, int windowDays, int refreshSeconds, int 'limit)
        returns NoveraStatsTarget[]|error {
    stream<record {|string campaign_id; string novera_notification_id;|}, error?> rows = db->query(`
        SELECT campaign_id::text AS campaign_id, novera_notification_id
        FROM announcement
        WHERE novera_notification_id IS NOT NULL AND sent_at IS NOT NULL
          AND sent_at >= now() - make_interval(days => CAST(${windowDays} AS int))
          AND (novera_checked_at IS NULL
               OR novera_checked_at < now() - make_interval(secs => CAST(${refreshSeconds} AS double precision)))
        ORDER BY novera_checked_at NULLS FIRST, sent_at DESC
        LIMIT ${'limit}`);
    return from var r in rows
        select {campaignId: r.campaign_id, notificationId: r.novera_notification_id};
}

# Saves a Novera seen count. With no count (Novera doesn't know the broadcast), only the time is kept, so the row
# waits a refresh interval instead of being asked again on every run. Not audited: a count is a reading, not a
# decision.
#
# + db - Client (`amplify_jobs`)
# + campaignId - Campaign
# + stats - The count, or `()` to record only that it was asked
# + checkedAt - When Novera answered
# + return - An error
public isolated function saveNoveraStats(postgresql:Client db, string campaignId, NoveraSeenStats? stats,
        time:Utc checkedAt) returns error? {
    if stats is () {
        _ = check db->execute(`
            UPDATE announcement SET novera_checked_at = CAST(${store:ts(checkedAt)} AS timestamptz)
            WHERE campaign_id = CAST(${campaignId} AS uuid)`);
        return;
    }
    _ = check db->execute(`
        UPDATE announcement
        SET novera_recipients = ${stats.recipients}, novera_seen = ${stats.seen},
            novera_checked_at = CAST(${store:ts(checkedAt)} AS timestamptz)
        WHERE campaign_id = CAST(${campaignId} AS uuid)`);
}

# Announcement status by campaign id, for the dashboard campaign tile.
#
# + db - Client
# + campaignIds - Campaigns
# + return - Status by campaign id (campaigns without a row are left out), or an error
public isolated function statusesOf(postgresql:Client db, string[] campaignIds) returns map<AnnouncementStatus>|error {
    string ids = store:arrayLiteral(campaignIds);
    stream<record {|string campaign_id; string status;|}, error?> rows = db->query(`
        SELECT campaign_id::text AS campaign_id, status FROM announcement_v
        WHERE campaign_id = ANY (CAST(${ids} AS uuid[]))`);
    map<AnnouncementStatus> result = {};
    check from var r in rows
        do {
            result[r.campaign_id] = check r.status.ensureType();
        };
    return result;
}

isolated function toAnnouncement(AnnouncementRow r) returns Announcement => {
    campaignId: r.campaign_id,
    outboxId: r.outbox_id,
    space: r.space,
    idempotencyKey: r.thread_key,
    messageName: r.chat_message_name,
    queuedAt: r.queued_at,
    sentAt: r.sent_at,
    failedAt: r.failed_at,
    lastError: r.last_error,
    attemptedAt: r.attempted_at,
    noveraNotificationId: r.novera_notification_id
};
