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


// PostgreSQL reads of `announcement` for the admin screen and dashboard (M5), and the admin retry.
// `amplify_api` can only read `announcement.announcement`; the jobs worker owns its writes. A retry
// re-queues the card's `CampaignRegistered` outbox row instead (ADR-024): the worker sends it again and
// clears `failed_at` when the card goes out.

import amplify_common.events;
import amplify_common.types;
import amplify_domain.store;

import ballerina/sql;
import ballerina/time;
import ballerinax/postgresql;

const string ANNOUNCEMENT_TABLE = "announcement.announcement";

type AnnouncementRow record {|
    string campaign_id;
    int? outbox_id;
    string space;
    string thread_key;
    string? chat_message_name;
    string? chat_thread_name;
    time:Utc queued_at;
    time:Utc? sent_at;
    time:Utc? failed_at;
    string? last_error;
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

    # Puts the card's `CampaignRegistered` outbox row back in the queue.
    #
    # + campaignId - Campaign
    # + return - `NOT_FOUND` when there is no outbox row, or another error
    public isolated function requeue(string campaignId) returns error?;
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
                   chat_thread_name, queued_at, sent_at, failed_at, last_error
            FROM announcement.announcement WHERE campaign_id = CAST(${campaignId} AS uuid)`);
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        return toAnnouncement(row);
    }

    public isolated function list(AnnouncementStatus? status, int 'limit) returns Announcement[]|error {
        sql:ParameterizedQuery cond = status is () ? `` : `WHERE status = ${status}`;
        stream<AnnouncementRow, error?> rows = self.db->query(sql:queryConcat(`
            SELECT campaign_id::text AS campaign_id, outbox_id, space, thread_key, chat_message_name,
                   chat_thread_name, queued_at, sent_at, failed_at, last_error
            FROM announcement.announcement_v `, cond, ` ORDER BY queued_at DESC LIMIT ${'limit}`));
        return from AnnouncementRow r in rows
            select toAnnouncement(r);
    }

    public isolated function requeue(string campaignId) returns error? =>
        store:inTransaction(isolated function () returns error? => self.requeueTx(campaignId));

    private isolated function requeueTx(string campaignId) returns error? {
        string key = events:idempotencyKey(events:CAMPAIGN_REGISTERED, campaignId);
        transaction {
            var result = check self.db->execute(`
                UPDATE messaging.outbox
                SET status = 'PENDING', attempts = 0, next_attempt_at = now(), locked_by = NULL, locked_until = NULL,
                    last_error = NULL, processed_at = NULL
                WHERE idempotency_key = ${key} AND status = 'FAILED'`);
            if result.affectedRowCount != 1 {
                // Only a FAILED row is re-queued. An IN_PROGRESS row is held by a run right now (resetting its
                // lock would let a second run send the card again), and a DONE or PENDING row must stay as it
                // is: a second admin's Retry would otherwise send a card that already went out.
                string|sql:Error state = self.db->queryRow(`
                    SELECT status FROM messaging.outbox WHERE idempotency_key = ${key}`);
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
            check store:writeAudit(self.db, store:auditOf(self.actor, "AnnouncementRetried", ANNOUNCEMENT_TABLE,
                    campaignId));
            check commit;
        }
    }
}

# Jobs-side writes of `announcement.announcement` (`amplify_jobs` owns them, ADR-024). Kept off the
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
            INSERT INTO announcement.announcement (campaign_id, outbox_id, space, thread_key, queued_at)
            VALUES (CAST(${a.campaignId} AS uuid), ${a.outboxId}, ${a.space}, ${a.threadKey},
                    CAST(${store:ts(a.queuedAt)} AS timestamptz))
            ON CONFLICT (campaign_id) DO NOTHING`);
    }

    # Stores a sent or failed card with its events and an audit row, in one transaction.
    #
    # + announcement - From `markSent` / `markFailed` / `retryAnnouncement`
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
                UPDATE announcement.announcement
                SET chat_message_name = ${a.chatMessageName}, chat_thread_name = ${a.chatThreadName},
                    sent_at = CAST(${store:ts(a.sentAt)} AS timestamptz),
                    failed_at = CAST(${store:ts(a.failedAt)} AS timestamptz), last_error = ${a.lastError}
                WHERE campaign_id = CAST(${a.campaignId} AS uuid)`);
            _ = check store:writeOutbox(self.db, outbox, self.actor.correlationId);
            string action = outbox.length() > 0 ? outbox[0].eventType
                : a.failedAt is () ? "AnnouncementQueued" : "AnnouncementFailed";
            check store:writeAudit(self.db, store:auditOf(self.actor, action, ANNOUNCEMENT_TABLE, a.campaignId,
                    {status: announcementStatus(a), space: a.space}));
            check commit;
        }
    }
}

# Announcement status by campaign id, for the dashboard campaign tile.
#
# + db - Client
# + campaignIds - Campaigns
# + return - Status by campaign id (campaigns without a row are left out), or an error
public isolated function statusesOf(postgresql:Client db, string[] campaignIds) returns map<AnnouncementStatus>|error {
    string ids = store:arrayLiteral(campaignIds);
    stream<record {|string campaign_id; string status;|}, error?> rows = db->query(`
        SELECT campaign_id::text AS campaign_id, status FROM announcement.announcement_v
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
    threadKey: r.thread_key,
    chatMessageName: r.chat_message_name,
    chatThreadName: r.chat_thread_name,
    queuedAt: r.queued_at,
    sentAt: r.sent_at,
    failedAt: r.failed_at,
    lastError: r.last_error
};
