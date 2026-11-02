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

// In-memory fakes for the run's ports: an outbox queue with the same claim/lease/attempt rules as
// `amplify_domain.store`, a store whose writes feed that queue, and scripted Chat and LinkedIn.

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
import ballerina/sql;
import ballerina/time;

type MemRow record {|
    int id;
    string eventType;
    json payload;
    string? correlationId;
    int attempts;
    string status;
    string? lockedBy;
    time:Utc dueAt;
    string? lastError;
|};

isolated class MemRunStore {
    *RunStore;

    private final map<MemRow> rows = {};
    private int nextId = 1;
    private MemStore? domain = ();

    isolated function attach(MemStore domain) {
        lock {
            self.domain = domain;
        }
    }

    isolated function memStore() returns MemStore {
        lock {
            return <MemStore>self.domain;
        }
    }

    isolated function enqueue(string eventType, json payload, string? correlationId = ()) returns int {
        lock {
            int id = self.nextId;
            self.nextId += 1;
            self.rows[id.toString()] = {
                id,
                eventType,
                payload: payload.clone(),
                correlationId,
                attempts: 0,
                status: "PENDING",
                lockedBy: (),
                dueAt: time:utcNow(),
                lastError: ()
            };
            return id;
        }
    }

    isolated function enqueueEvents(events:OutboxEvent[] outbox, string? correlationId) {
        foreach events:OutboxEvent e in outbox {
            _ = self.enqueue(e.eventType, e.payload.toJson(), correlationId);
        }
    }

    isolated function statusOf(int id) returns [string, int, string?] {
        lock {
            MemRow r = <MemRow>self.rows[id.toString()];
            return [r.status, r.attempts, r.lastError];
        }
    }

    isolated function countByType(string eventType) returns int {
        lock {
            int n = 0;
            foreach MemRow r in self.rows {
                if r.eventType == eventType {
                    n += 1;
                }
            }
            return n;
        }
    }

    # Makes every pending row due now (fast-forward past backoff).
    isolated function makeAllDue() {
        lock {
            foreach MemRow r in self.rows {
                r.dueAt = time:utcNow();
            }
        }
    }

    # Puts a finished row back in the queue (a duplicate delivery / admin retry).
    isolated function redeliver(int id) {
        lock {
            MemRow r = <MemRow>self.rows[id.toString()];
            r.status = "PENDING";
            r.dueAt = time:utcNow();
        }
    }

    isolated function claim(string runId, int batchSize, int leaseSeconds) returns store:OutboxRow[]|error {
        lock {
            time:Utc now = time:utcNow();
            int[] ids = [];
            foreach MemRow r in self.rows {
                if r.status == "PENDING" && time:utcDiffSeconds(r.dueAt, now) <= 0d {
                    ids.push(r.id);
                }
            }
            int[] sorted = ids.sort();
            store:OutboxRow[] claimed = [];
            foreach int id in sorted {
                if claimed.length() >= batchSize {
                    break;
                }
                MemRow r = <MemRow>self.rows[id.toString()];
                r.status = "IN_PROGRESS";
                r.lockedBy = runId;
                r.attempts = r.attempts + 1;
                claimed.push({id: r.id, aggregateType: "test", aggregateId: r.id.toString(), eventType: r.eventType,
                    payload: r.payload.clone(), idempotencyKey: string `${r.eventType}:${r.id}`, attempts: r.attempts,
                    correlationId: r.correlationId});
            }
            return claimed.clone();
        }
    }

    isolated function complete(int id, string runId) returns error? {
        lock {
            MemRow r = <MemRow>self.rows[id.toString()];
            if r.lockedBy == runId {
                r.status = "DONE";
                r.lockedBy = ();
            }
        }
    }

    isolated function requeue(int id, string runId, decimal delaySeconds, string? lastError, boolean countAttempt)
            returns error? {
        lock {
            MemRow r = <MemRow>self.rows[id.toString()];
            if r.lockedBy == runId {
                r.status = "PENDING";
                r.lockedBy = ();
                r.dueAt = time:utcAddSeconds(time:utcNow(), delaySeconds);
                r.lastError = lastError;
                if !countAttempt && r.attempts > 0 {
                    r.attempts = r.attempts - 1;
                }
            }
        }
    }

    isolated function failRow(int id, string runId, string lastError) returns error? {
        lock {
            MemRow r = <MemRow>self.rows[id.toString()];
            if r.lockedBy == runId {
                r.status = "FAILED";
                r.lockedBy = ();
                r.lastError = lastError;
            }
        }
    }

    isolated function releaseStale() returns int|error => 0;

    isolated function settings() returns RunSettings|error => self.memStore().runSettings();

    isolated function connectionSweep() returns ConnectionSweep|error => {expiring: 0, needsReconnect: 0};

    isolated function publishedToday(time:Utc now) returns int|error => 0;

    isolated function forRow(string correlationId, int topN) returns Store => self.memStore();
}

isolated class MemStore {
    *Store;

    private final MemRunStore queue;
    private final map<campaign:Campaign> campaigns = {};
    private final map<announcements:Announcement> announcementRows = {};
    private final map<sharing:ShareRequest> shares = {};
    private final map<sharing:Engagement> engagements = {};
    private final map<connection:LinkedInConnection> connections = {};
    private final map<connection:StoredToken> tokens = {};
    private final map<types:LedgerEntry> ledger = {};
    private scoring:PointRule[] rules = [];
    private RunSettings settingsValue = {};
    private boolean duplicateNext = false;
    private boolean publishWriteFails = false;
    private int reseals = 0;

    isolated function init(MemRunStore queue) {
        self.queue = queue;
    }

    isolated function runSettings() returns RunSettings {
        lock {
            return self.settingsValue.clone();
        }
    }

    isolated function setSettings(RunSettings s) {
        lock {
            self.settingsValue = s.clone();
        }
    }

    isolated function putCampaign(campaign:Campaign c) {
        lock {
            self.campaigns[c.id] = c.clone();
        }
    }

    isolated function putShare(sharing:ShareRequest s) {
        lock {
            self.shares[s.campaignId + "|" + s.employeeId] = s.clone();
        }
    }

    isolated function putConnection(connection:LinkedInConnection c, connection:StoredToken t) {
        lock {
            self.connections[c.employeeId] = c.clone();
            self.tokens[t.tokenId] = t.clone();
        }
    }

    # Deletes every token row (a dropped partition or a Remove Connection), keeping the connections.
    isolated function dropTokens() {
        lock {
            self.tokens.removeAll();
        }
    }

    isolated function putRules(scoring:PointRule[] rules) {
        lock {
            self.rules = rules.clone();
        }
    }

    isolated function ledgerSize() returns int {
        lock {
            return self.ledger.length();
        }
    }

    isolated function ledgerPoints() returns int {
        lock {
            int total = 0;
            foreach types:LedgerEntry e in self.ledger {
                total += e.points;
            }
            return total;
        }
    }

    isolated function engagementCount() returns int {
        lock {
            return self.engagements.length();
        }
    }

    isolated function campaign(string id) returns campaign:Campaign|error? {
        lock {
            return self.campaigns[id].clone();
        }
    }

    isolated function announcement(string campaignId) returns announcements:Announcement|error? {
        lock {
            return self.announcementRows[campaignId].clone();
        }
    }

    isolated function insertAnnouncement(announcements:Announcement announcement) returns error? {
        lock {
            if !self.announcementRows.hasKey(announcement.campaignId) {
                self.announcementRows[announcement.campaignId] = announcement.clone();
            }
        }
    }

    isolated function saveAnnouncement(announcements:Announcement announcement, events:OutboxEvent[] outbox)
            returns error? {
        lock {
            self.announcementRows[announcement.campaignId] = announcement.clone();
        }
        self.queue.enqueueEvents(outbox, ());
    }

    isolated function share(string campaignId, types:EmployeeId employeeId) returns sharing:ShareRequest|error? {
        lock {
            return self.shares[campaignId + "|" + employeeId].clone();
        }
    }

    isolated function recordPublish(sharing:PublishResult result, int expectedVersion) returns error? {
        sharing:Engagement & readonly e = result.engagement.cloneReadOnly();
        sharing:ShareRequest & readonly published = result.request.cloneReadOnly();
        lock {
            string key = string `${e.provider}|${e.targetResourceUrn}|${e.employeeId}|${e.action}`;
            if self.engagements.hasKey(key) || self.duplicateNext {
                self.duplicateNext = false;
                return error sql:DatabaseError("duplicate key value violates unique constraint \"engagement_once_uk\"",
                    errorCode = 0, sqlState = "23505");
            }
            if self.publishWriteFails {
                self.publishWriteFails = false;
                return error sql:DatabaseError("Connection reset", errorCode = 0, sqlState = "08006");
            }
            check self.updateLocked(published, expectedVersion);
            self.engagements[key] = e;
        }
        self.queue.enqueueEvents(result.outbox, ());
    }

    # Test switch: make `recordPublish` fail like PostgreSQL's engagement unique key does.
    isolated function failNextPublishAsDuplicate() {
        lock {
            self.duplicateNext = true;
        }
    }

    # Test switch: make `recordPublish` fail like a database blip (no unique violation) after a post.
    isolated function failNextPublishWrite() {
        lock {
            self.publishWriteFails = true;
        }
    }

    isolated function recordDuplicatePublish(sharing:PublishResult result, int expectedVersion) returns boolean|error {
        sharing:Engagement & readonly e = result.engagement.cloneReadOnly();
        sharing:PublishResult & readonly r = result.cloneReadOnly();
        lock {
            string key = string `${e.provider}|${e.targetResourceUrn}|${e.employeeId}|${e.action}`;
            sharing:Engagement? existing = self.engagements[key];
            if existing is () {
                return false;
            }
            check self.updateLocked(check sharing:asDuplicatePublish(r, existing.id).cloneReadOnly(), expectedVersion);
            return true;
        }
    }

    isolated function updateSeal(connection:StoredToken old, crypto:SealedToken resealed) returns boolean|error {
        lock {
            connection:StoredToken? current = self.tokens[old.tokenId];
            if current is () || current.keyId != old.keyId {
                return false;
            }
            current.ciphertext = resealed.ciphertext.clone();
            current.nonce = resealed.nonce.clone();
            current.keyId = resealed.keyId;
            self.reseals += 1;
            return true;
        }
    }

    isolated function resealCount() returns int {
        lock {
            return self.reseals;
        }
    }

    isolated function storedToken(string tokenId) returns connection:StoredToken? {
        lock {
            return self.tokens[tokenId].clone();
        }
    }

    isolated function putEngagement(sharing:Engagement e) {
        lock {
            self.engagements[string `${e.provider}|${e.targetResourceUrn}|${e.employeeId}|${e.action}`] = e.clone();
        }
    }

    isolated function updateShare(sharing:ShareRequest request, int expectedVersion, events:OutboxEvent[] outbox)
            returns error? {
        sharing:ShareRequest & readonly changed = request.cloneReadOnly();
        lock {
            check self.updateLocked(changed, expectedVersion);
        }
        self.queue.enqueueEvents(outbox, ());
    }

    private isolated function updateLocked(sharing:ShareRequest & readonly request, int expectedVersion)
            returns error? {
        lock {
            string key = request.campaignId + "|" + request.employeeId;
            sharing:ShareRequest? current = self.shares[key];
            if current is () || current.version != expectedVersion {
                return store:versionConflict("share");
            }
            self.shares[key] = request;
        }
    }

    isolated function connection(types:EmployeeId employeeId) returns connection:LinkedInConnection|error? {
        lock {
            return self.connections[employeeId].clone();
        }
    }

    isolated function token(connection:TokenRef ref) returns connection:StoredToken|error? {
        lock {
            return self.tokens[ref.tokenId].clone();
        }
    }

    isolated function saveConnection(connection:ConnectionChange change, int expectedVersion) returns error? {
        connection:LinkedInConnection & readonly c = change.connection.cloneReadOnly();
        lock {
            self.connections[c.employeeId] = c;
        }
        self.queue.enqueueEvents(change.outbox, ());
    }

    isolated function pointRules() returns scoring:PointRule[]|error {
        lock {
            return self.rules.clone();
        }
    }

    isolated function appendLedger(scoring:LedgerAppend append) returns boolean|error {
        types:LedgerEntry & readonly entry = append.entry.cloneReadOnly();
        lock {
            if self.ledger.hasKey(entry.reference) {
                return false;
            }
            self.ledger[entry.reference] = entry;
        }
        self.queue.enqueueEvents([append.event], ());
        return true;
    }
}

isolated class MemLock {
    *RunLock;

    private final boolean free;

    isolated function init(boolean free = true) {
        self.free = free;
    }

    isolated function tryAcquire() returns boolean|error => self.free;

    isolated function release() returns error? {
    }
}

isolated class FakeChat {
    *ChatPort;

    private string mode = "ok";
    private int posts = 0;
    private decimal delaySeconds = 0;
    private string? lastCorrelationId = ();

    isolated function setMode(string mode, decimal delaySeconds = 0) {
        lock {
            self.mode = mode;
            self.delaySeconds = delaySeconds;
        }
    }

    isolated function postCount() returns int {
        lock {
            return self.posts;
        }
    }

    isolated function correlation() returns string? {
        lock {
            return self.lastCorrelationId;
        }
    }

    isolated function space() returns string => "dev-test";

    isolated function post(json message, string threadKey, string? correlationId)
            returns googlechat:ChatMessage|googlechat:ChatError {
        string mode;
        decimal delay;
        lock {
            mode = self.mode;
            delay = self.delaySeconds;
            self.lastCorrelationId = correlationId;
        }
        if delay > 0d {
            runtime:sleep(delay);
        }
        if mode == "429" {
            return error googlechat:ChatError("rate limited", code = "RATE_LIMITED", httpStatus = 429, retryable = true);
        }
        if mode == "400" {
            return error googlechat:ChatError("bad card", code = "REJECTED", httpStatus = 400, retryable = false);
        }
        lock {
            self.posts += 1;
            return {name: string `spaces/dev/messages/m${self.posts}`, threadName: "spaces/dev/threads/" + threadKey};
        }
    }

    isolated function breaker() returns string => "CLOSED";
}

isolated class FakeLinkedIn {
    *linkedin:ProviderAdapter;

    private string mode = "ok";
    private int posts = 0;
    private string? lastBearer = ();
    private string? lastCommentary = ();
    private string? lastCorrelationId = ();
    private string? lastTitle = ();

    isolated function setMode(string mode) {
        lock {
            self.mode = mode;
        }
    }

    isolated function postCount() returns int {
        lock {
            return self.posts;
        }
    }

    isolated function last() returns [string?, string?, string?] {
        lock {
            return [self.lastBearer, self.lastCommentary, self.lastCorrelationId];
        }
    }

    isolated function lastTargetTitle() returns string? {
        lock {
            return self.lastTitle;
        }
    }

    public isolated function authorizationUrl(string state) returns string|linkedin:ProviderError => "http://mock";

    public isolated function authorizationUrlWithNonce(string state, string? nonce) returns string|linkedin:ProviderError =>
        "http://mock";

    public isolated function exchangeCode(string code) returns linkedin:TokenGrant|linkedin:ProviderError =>
        {accessToken: "x", expiresInSeconds: 60, scopes: []};

    public isolated function userInfo(string accessToken) returns linkedin:MemberProfile|linkedin:ProviderError =>
        {sub: "s", memberUrn: "urn:li:person:s", name: (), email: ()};

    public isolated function revokeToken(string accessToken) returns linkedin:ProviderError? => ();

    public isolated function publishShare(string accessToken, linkedin:ShareCommand command)
            returns types:PostUrn|linkedin:ProviderError {
        lock {
            self.lastBearer = accessToken;
            self.lastCommentary = command.commentary;
            self.lastCorrelationId = command.correlationId;
            self.lastTitle = command.targetTitle;
            match self.mode {
                "401" => {
                    return providerError(linkedin:UNAUTHORIZED, 401, false);
                }
                "429" => {
                    return providerError(linkedin:RATE_LIMITED, 429, true);
                }
                "422" => {
                    return providerError(linkedin:REJECTED, 422, false);
                }
                "503" => {
                    return providerError(linkedin:UNAVAILABLE, 503, true);
                }
                "timeout" => {
                    // The call timed out before LinkedIn took anything (adapter: OUTCOME_UNKNOWN).
                    return providerError(linkedin:OUTCOME_UNKNOWN, 0, false);
                }
                "timeout-after-post" => {
                    // LinkedIn took the post but the answer never came back (the adapter's OUTCOME_UNKNOWN).
                    self.posts += 1;
                    return providerError(linkedin:OUTCOME_UNKNOWN, 0, false);
                }
            }
            self.posts += 1;
            return string `urn:li:share:70000000000000000${self.posts}`;
        }
    }
}

isolated function providerError(linkedin:ProviderErrorCode code, int status, boolean retryable)
        returns linkedin:ProviderError =>
    error linkedin:ProviderError("LinkedIn failed", code = code, httpStatus = status, serviceErrorCode = (),
        retryable = retryable);

isolated function noBreakers() returns map<string> => {};

final RunConfig & readonly TEST_CONFIG = {
    batchSize: 10,
    maxRows: 100,
    maxSeconds: 60,
    leaseSeconds: 300,
    maxAttempts: 3,
    backoffBaseSeconds: 30,
    backoffMaxSeconds: 3600,
    deferSeconds: 900,
    linkedinMaxPostsPerRun: 50,
    linkedinMaxPostsPerDay: 1000,
    sharePageBaseUrl: "https://one.wso2.com/amplify/celebrate",
    chatSpace: "dev-test"
};

function testCipher() returns crypto:TokenCipher|error {
    byte[] key = [];
    foreach int i in 0 ..< 32 {
        key.push(<byte>(i + 7));
    }
    return new ([{keyId: "k1", key}], "k1");
}

function openCampaign(string id, time:Utc now, decimal opensInSeconds = -3600) returns campaign:Campaign => {
    id,
    provider: types:LINKEDIN,
    resourceUrn: "urn:li:share:1000000000000000001",
    resourceType: types:SHARE,
    ownerUrn: "urn:li:organization:1477",
    resourceUrl: "https://www.linkedin.com/feed/update/urn:li:share:1000000000000000001/",
    title: "Ballerina 2201.13 is out",
    summary: "What is new",
    imageUrl: "https://example.com/i.png",
    categoryCode: "PRODUCT",
    isPriority: false,
    tags: ["ballerina"],
    opensAt: time:utcAddSeconds(now, opensInSeconds),
    closesAt: time:utcAddSeconds(now, 30 * 86400),
    archivedAt: (),
    createdBy: "po-1",
    createdAt: now,
    updatedAt: now,
    version: 1
};

function queuedShare(string campaignId, string employeeId, time:Utc now) returns sharing:ShareRequest => {
    id: types:newUuidV7(),
    campaignId,
    employeeId,
    provider: types:LINKEDIN,
    providerApi: types:SHARE_ON_LINKEDIN,
    targetResourceUrn: "urn:li:share:1000000000000000001",
    kind: types:REPOST_COMMENTARY,
    commentary: "Proud of the team",
    requestedAt: now,
    publishedAt: (),
    failedAt: (),
    failureReason: (),
    attempts: 1,
    lastErrorCode: (),
    engagementId: (),
    version: 1
};

function connectedEmployee(MemStore mem, crypto:TokenCipher cipher, string employeeId, time:Utc now) returns error? {
    connection:StoredToken token = check connection:sealToken(cipher, "bearer-" + employeeId, employeeId,
            time:utcAddSeconds(now, 50 * 86400), now);
    mem.putConnection({
        employeeId,
        provider: types:LINKEDIN,
        memberUrn: "urn:li:person:" + employeeId,
        providerApi: types:SHARE_ON_LINKEDIN,
        scopes: ["openid", "profile", "w_member_social"],
        currentToken: connection:tokenRef(token),
        accessExpiresAt: time:utcAddSeconds(now, 50 * 86400),
        connectedAt: time:utcAddSeconds(now, -86400),
        revokedAt: (),
        removedAt: (),
        lastRemindedAt: (),
        version: 1
    }, token);
}

function repostRule(time:Utc now) returns scoring:PointRule[] => [
    {id: "r1", action: types:REPOST_COMMENTARY, points: 20, effectiveFrom: time:utcAddSeconds(now, -86400 * 365),
        createdBy: "po-1", createdAt: now}
];

# Delegates to a `MemRunStore` but panics on the first claim (a bug deep in a handler or a repository).
isolated class PanickingRunStore {
    *RunStore;

    private final MemRunStore inner;

    isolated function init(MemRunStore inner) {
        self.inner = inner;
    }

    isolated function claim(string runId, int batchSize, int leaseSeconds) returns store:OutboxRow[]|error {
        int[] empty = [];
        int boom = empty[batchSize]; // index out of range: a panic, not an error
        return error(boom.toString());
    }

    isolated function complete(int id, string runId) returns error? => self.inner.complete(id, runId);

    isolated function requeue(int id, string runId, decimal delaySeconds, string? lastError, boolean countAttempt)
            returns error? => self.inner.requeue(id, runId, delaySeconds, lastError, countAttempt);

    isolated function failRow(int id, string runId, string lastError) returns error? =>
        self.inner.failRow(id, runId, lastError);

    isolated function releaseStale() returns int|error => self.inner.releaseStale();

    isolated function settings() returns RunSettings|error => self.inner.settings();

    isolated function connectionSweep() returns ConnectionSweep|error => self.inner.connectionSweep();

    isolated function publishedToday(time:Utc now) returns int|error => self.inner.publishedToday(now);

    isolated function forRow(string correlationId, int topN) returns Store => self.inner.forRow(correlationId, topN);
}

# Counts lock releases, so a test can see the run gave the advisory lock back.
isolated class CountingLock {
    *RunLock;

    private int acquired = 0;
    private int released = 0;

    isolated function tryAcquire() returns boolean|error {
        lock {
            self.acquired += 1;
            return true;
        }
    }

    isolated function release() returns error? {
        lock {
            self.released += 1;
        }
    }

    isolated function counts() returns [int, int] {
        lock {
            return [self.acquired, self.released];
        }
    }
}

# Reports a fixed number of LinkedIn posts already published today.
isolated class PublishedTodayRunStore {
    *RunStore;

    private final MemRunStore inner;
    private final int published;

    isolated function init(MemRunStore inner, int published) {
        self.inner = inner;
        self.published = published;
    }

    isolated function claim(string runId, int batchSize, int leaseSeconds) returns store:OutboxRow[]|error =>
        self.inner.claim(runId, batchSize, leaseSeconds);

    isolated function complete(int id, string runId) returns error? => self.inner.complete(id, runId);

    isolated function requeue(int id, string runId, decimal delaySeconds, string? lastError, boolean countAttempt)
            returns error? => self.inner.requeue(id, runId, delaySeconds, lastError, countAttempt);

    isolated function failRow(int id, string runId, string lastError) returns error? =>
        self.inner.failRow(id, runId, lastError);

    isolated function releaseStale() returns int|error => self.inner.releaseStale();

    isolated function settings() returns RunSettings|error => self.inner.settings();

    isolated function connectionSweep() returns ConnectionSweep|error => self.inner.connectionSweep();

    isolated function publishedToday(time:Utc now) returns int|error => self.published;

    isolated function forRow(string correlationId, int topN) returns Store => self.inner.forRow(correlationId, topN);
}

isolated class FakeNovera {
    *NoveraPort;

    private string mode = "ok";
    private int count = 0;

    isolated function setMode(string mode) {
        lock {
            self.mode = mode;
        }
    }

    isolated function sent() returns int {
        lock {
            return self.count;
        }
    }

    isolated function notify(announcements:NoveraNotification notification, string? correlationId)
            returns NoveraError? {
        lock {
            if self.mode == "503" {
                return noveraError("UNAVAILABLE", "down", 503, true);
            }
            if self.mode == "400" {
                return noveraError("REJECTED", "bad", 400, false);
            }
            self.count += 1;
        }
    }

    isolated function breaker() returns string => "CLOSED";
}
