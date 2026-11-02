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

// Ports the run and its handlers depend on, so unit tests swap in in-memory fakes, plus the PostgreSQL
// implementations over `amplify_domain` (ADR-021). No SQL here except the run's advisory lock.

import amplify_common.crypto;
import amplify_common.events;
import amplify_common.googlechat;
import amplify_common.linkedin;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/lang.runtime;
import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

# Advisory lock key for "one run at a time" across replicas ("ampl").
const int RUN_LOCK_KEY = 1634561132;

# Advisory lock key for "one partition maintenance pass at a time" across replicas ("main").
const int MAINTENANCE_LOCK_KEY = 1835755886;

# Run settings from config.
type RunConfig record {|
    int batchSize;
    int maxRows;
    int maxSeconds;
    int leaseSeconds;
    int maxAttempts;
    decimal backoffBaseSeconds;
    decimal backoffMaxSeconds;
    decimal deferSeconds;
    int linkedinMaxPostsPerRun;
    int linkedinMaxPostsPerDay;
    string sharePageBaseUrl;
    string chatSpace;
    string? cardAvatarUrl = ();
    string? defaultImageUrl = ();
|};

# App settings a run reads once (`config.app_setting`).
type RunSettings record {|
    boolean sharingEnabled = true;
    boolean announcementsEnabled = true;
    int topN = 3;
    int reminderDays = connection:DEFAULT_REMINDER_DAYS;
|};

# Connection sweep counts (derived status, `member_connection_v`).
type ConnectionSweep record {|
    # Inside `connection.reminder_days` of expiry (One WSO2 shows the reconnect banner from `GET /me`)
    int expiring;
    # Expired, revoked or without a token
    int needsReconnect;
|};

# The outbox queue and the run-level reads.
type RunStore isolated object {
    isolated function claim(string runId, int batchSize, int leaseSeconds) returns store:OutboxRow[]|error;
    isolated function complete(int id, string runId) returns error?;
    isolated function requeue(int id, string runId, decimal delaySeconds, string? lastError, boolean countAttempt)
        returns error?;
    isolated function failRow(int id, string runId, string lastError) returns error?;
    isolated function releaseStale() returns int|error;
    isolated function settings() returns RunSettings|error;
    isolated function connectionSweep() returns ConnectionSweep|error;
    isolated function publishedToday(time:Utc now) returns int|error;
    # Store for one outbox row's writes, carrying its correlation id (audit and outbox rows).
    isolated function forRow(string correlationId, int topN) returns Store;
};

# Domain reads and writes the handlers need.
type Store isolated object {
    isolated function campaign(string id) returns campaign:Campaign|error?;
    isolated function announcement(string campaignId) returns announcements:Announcement|error?;
    isolated function insertAnnouncement(announcements:Announcement announcement) returns error?;
    isolated function saveAnnouncement(announcements:Announcement announcement, events:OutboxEvent[] outbox)
        returns error?;
    isolated function share(string campaignId, types:EmployeeId employeeId) returns sharing:ShareRequest|error?;
    isolated function recordPublish(sharing:PublishResult result, int expectedVersion) returns error?;
    # Settles a publish `recordPublish` refused with an engagement unique violation (domain review H-5).
    # True when settled on the existing engagement, false when none matches.
    isolated function recordDuplicatePublish(sharing:PublishResult result, int expectedVersion) returns boolean|error;
    isolated function updateShare(sharing:ShareRequest request, int expectedVersion, events:OutboxEvent[] outbox)
        returns error?;
    isolated function connection(types:EmployeeId employeeId) returns connection:LinkedInConnection|error?;
    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error?;
    # Re-seal on use (key rotation): true when updated, false when the row changed meanwhile.
    isolated function updateSeal(connection:StoredToken old, crypto:SealedToken resealed) returns boolean|error;
    isolated function saveConnection(connection:ConnectionChange change, int expectedVersion) returns error?;
    isolated function pointRules() returns scoring:PointRule[]|error;
    isolated function appendLedger(scoring:LedgerAppend append) returns boolean|error;
};

# One run at a time across replicas.
type RunLock isolated object {
    isolated function tryAcquire() returns boolean|error;
    isolated function release() returns error?;
};

# Port to the Club space.
type ChatPort isolated object {
    # Space label stored on the announcement
    isolated function space() returns string;
    isolated function post(json message, string threadKey, string? correlationId)
        returns googlechat:ChatMessage|googlechat:ChatError;
    isolated function breaker() returns string;
};

# Everything a run needs.
type Deps record {|
    RunStore runStore;
    RunLock runLock;
    ChatPort? chat;
    NoveraPort? novera = ();
    linkedin:ProviderAdapter? linkedIn;
    crypto:TokenCipher? cipher;
    RunConfig config;
    isolated function () returns map<string> breakers;
|};

// ---- PostgreSQL ------------------------------------------------------------------------------------

# `RunStore` over the `amplify_jobs` client.
isolated class PgRunStore {
    *RunStore;

    private final postgresql:Client db;

    isolated function init(postgresql:Client db) {
        self.db = db;
    }

    isolated function claim(string runId, int batchSize, int leaseSeconds) returns store:OutboxRow[]|error =>
        store:claimOutbox(self.db, runId, batchSize, leaseSeconds);

    isolated function complete(int id, string runId) returns error? => store:completeOutbox(self.db, id, runId);

    isolated function requeue(int id, string runId, decimal delaySeconds, string? lastError, boolean countAttempt)
            returns error? => store:retryOutbox(self.db, id, runId, delaySeconds, lastError, countAttempt);

    isolated function failRow(int id, string runId, string lastError) returns error? =>
        store:failOutbox(self.db, id, runId, lastError);

    isolated function releaseStale() returns int|error => store:releaseStaleLocks(self.db);

    isolated function settings() returns RunSettings|error => toRunSettings(check store:readSettings(self.db));

    isolated function connectionSweep() returns ConnectionSweep|error {
        connection:ConnectionCounts counts = check connection:connectionCounts(self.db);
        return {expiring: counts.expiring, needsReconnect: counts.needsReconnect};
    }

    isolated function publishedToday(time:Utc now) returns int|error {
        time:Utc dayStart = check time:utcFromString(time:utcToString(now).substring(0, 10) + "T00:00:00Z");
        return (check sharing:shareHealth(self.db, dayStart)).published;
    }

    isolated function forRow(string correlationId, int topN) returns Store =>
        new PgStore(self.db, {actorId: store:SYSTEM.actorId, roles: store:SYSTEM.roles, correlationId}, topN);
}

# `Store` over the context repositories, acting as `system` with the row's correlation id.
isolated class PgStore {
    *Store;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;
    private final int topN;

    isolated function init(postgresql:Client db, store:Actor actor, int topN) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
        self.topN = topN;
    }

    isolated function campaign(string id) returns campaign:Campaign|error? =>
        (new campaign:PgCampaignRepository(self.db, self.actor)).findById(id);

    isolated function announcement(string campaignId) returns announcements:Announcement|error? =>
        (new announcements:PgAnnouncementRepository(self.db, self.actor)).findByCampaign(campaignId);

    isolated function insertAnnouncement(announcements:Announcement announcement) returns error? =>
        (new announcements:PgAnnouncementWriter(self.db, self.actor)).insertQueued(announcement);

    isolated function saveAnnouncement(announcements:Announcement announcement, events:OutboxEvent[] outbox)
            returns error? => (new announcements:PgAnnouncementWriter(self.db, self.actor)).save(announcement, outbox);

    isolated function share(string campaignId, types:EmployeeId employeeId) returns sharing:ShareRequest|error? =>
        (new sharing:PgShareRepository(self.db, self.actor)).findByCampaignAndEmployee(campaignId, employeeId);

    isolated function recordPublish(sharing:PublishResult result, int expectedVersion) returns error? =>
        (new sharing:PgShareRepository(self.db, self.actor)).recordPublish(result, expectedVersion);

    isolated function recordDuplicatePublish(sharing:PublishResult result, int expectedVersion) returns boolean|error =>
        (new sharing:PgShareRepository(self.db, self.actor)).recordDuplicatePublish(result, expectedVersion);

    isolated function updateShare(sharing:ShareRequest request, int expectedVersion, events:OutboxEvent[] outbox)
            returns error? => (new sharing:PgShareRepository(self.db, self.actor)).update(request, expectedVersion, outbox);

    isolated function connection(types:EmployeeId employeeId) returns connection:LinkedInConnection|error? =>
        (new connection:PgConnectionRepository(self.db, self.actor)).findByEmployee(employeeId, types:LINKEDIN);

    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error? =>
        (new connection:PgTokenRepository(self.db)).find(ref);

    isolated function updateSeal(connection:StoredToken old, crypto:SealedToken resealed) returns boolean|error =>
        (new connection:PgTokenRepository(self.db)).updateSeal(old, resealed);

    isolated function saveConnection(connection:ConnectionChange change, int expectedVersion) returns error? =>
        (new connection:PgConnectionRepository(self.db, self.actor)).save(change, expectedVersion);

    isolated function pointRules() returns scoring:PointRule[]|error =>
        (new scoring:PgPointRuleRepository(self.db, self.actor)).all();

    isolated function appendLedger(scoring:LedgerAppend append) returns boolean|error =>
        (new scoring:PgLedgerRepository(self.db, self.actor, self.topN)).append(append);
}

# Session advisory lock on a dedicated single-connection client: lock and unlock run on the same
# PostgreSQL session. If that session dies the lock goes with it; `FOR UPDATE SKIP LOCKED` still keeps
# two runs off the same rows. The client must never retire its connection (`maxConnectionLifeTime = 0`),
# or a connection retired mid-run would silently drop the lock.
isolated class PgRunLock {
    *RunLock;

    private final postgresql:Client db;
    private final int lockKey;

    isolated function init(postgresql:Client db, int lockKey = RUN_LOCK_KEY) {
        self.db = db;
        self.lockKey = lockKey;
    }

    isolated function tryAcquire() returns boolean|error {
        boolean acquired = check self.db->queryRow(`SELECT pg_try_advisory_lock(CAST(${self.lockKey} AS bigint))`);
        return acquired;
    }

    isolated function release() returns error? {
        boolean released = check self.db->queryRow(`SELECT pg_advisory_unlock(CAST(${self.lockKey} AS bigint))`);
        if !released {
            // The lock is a session lock on a dedicated connection. `false` means this connection no longer
            // holds it (it was retired mid-run), so another replica may have started the same work meanwhile.
            log:printWarn("Advisory lock was no longer held when the work finished");
        }
    }
}

# `ChatPort` over the webhook client, throttled to one post per `minIntervalSeconds` (the space quota is
# shared by every webhook in the space).
isolated class WebhookChat {
    *ChatPort;

    private final googlechat:WebhookClient webhook;
    private final string spaceName;
    private final decimal minIntervalSeconds;
    private decimal lastPostAt = -1000;

    isolated function init(googlechat:WebhookClient webhook, string spaceName, decimal minIntervalSeconds) {
        self.webhook = webhook;
        self.spaceName = spaceName;
        self.minIntervalSeconds = minIntervalSeconds;
    }

    isolated function space() returns string => self.spaceName;

    isolated function post(json message, string threadKey, string? correlationId)
            returns googlechat:ChatMessage|googlechat:ChatError {
        lock {
            decimal waitSeconds = self.lastPostAt + self.minIntervalSeconds - time:monotonicNow();
            if waitSeconds > 0d {
                runtime:sleep(waitSeconds);
            }
            self.lastPostAt = time:monotonicNow();
        }
        return self.webhook.post(message.cloneReadOnly(), threadKey, correlationId);
    }

    isolated function breaker() returns string => self.webhook.breaker();
}

isolated function toRunSettings(store:Setting[] rows) returns RunSettings {
    RunSettings s = {};
    foreach store:Setting row in rows {
        json v = row.value;
        match row.key {
            "sharing.enabled" => {
                s.sharingEnabled = v != false;
            }
            "announcements.enabled" => {
                s.announcementsEnabled = v != false;
            }
            "leaderboard.top_n" => {
                s.topN = v is int && v > 0 ? v : s.topN;
            }
            "connection.reminder_days" => {
                s.reminderDays = v is int && v >= 0 ? v : s.reminderDays;
            }
        }
    }
    return s;
}

