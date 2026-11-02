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

// PostgreSQL implementation of `ShareRepository` (schema `sharing` only). Commentary is never audited.

import amplify_common.events;
import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

const string SHARE_TABLE = "sharing.share_request";

type ShareRow record {|
    string id;
    string campaign_id;
    string employee_id;
    string provider;
    string provider_api;
    string target_resource_urn;
    string kind;
    string? commentary;
    time:Utc requested_at;
    time:Utc? published_at;
    time:Utc? failed_at;
    string? failure_reason;
    int attempts;
    string? last_error_code;
    string? engagement_id;
    int version;
|};

# `ShareRepository` over PostgreSQL.
public isolated class PgShareRepository {
    *ShareRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client (`amplify_api` or `amplify_jobs`)
    # + actor - Who the writes are for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function findByCampaignAndEmployee(string campaignId, types:EmployeeId employeeId) returns ShareRequest|error? {
        ShareRow|error row = self.db->queryRow(`
            SELECT id::text AS id, campaign_id::text AS campaign_id, employee_id, provider, provider_api,
                   target_resource_urn, kind, commentary, requested_at, published_at, failed_at, failure_reason,
                   attempts, last_error_code, engagement_id::text AS engagement_id, version
            FROM sharing.share_request
            WHERE campaign_id = CAST(${campaignId} AS uuid) AND employee_id = ${employeeId}`);
        return toShare(row);
    }

    public isolated function insert(ShareRequest request, events:OutboxEvent[] outbox) returns error? {
        final readonly & ShareRequest r = request.cloneReadOnly();
        final readonly & events:OutboxEvent[] queued = outbox.cloneReadOnly();
        error? result = store:inTransaction(isolated function () returns error? => self.insertTx(r, queued));
        if result is error && store:isUniqueViolation(result, "share_request_campaign_employee_uk") {
            return existingShareError(self.db, r);
        }
        return result;
    }

    public isolated function update(ShareRequest request, int expectedVersion, events:OutboxEvent[] outbox) returns error? {
        final readonly & ShareRequest r = request.cloneReadOnly();
        final readonly & events:OutboxEvent[] queued = outbox.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.updateTx(r, expectedVersion, queued));
    }

    private isolated function updateTx(ShareRequest request, int expectedVersion, events:OutboxEvent[] outbox)
            returns error? {
        transaction {
            check self.updateRow(request, expectedVersion, outbox);
            check commit;
        }
    }

    # Stores a publish (jobs, `RepostRequested` handler): the engagement fact, then the published request
    # (commentary cleared) and `EngagementRecorded`, in one transaction. A second publish of the same
    # activity or resource hits the engagement unique keys and changes nothing.
    #
    # + result - From `markPublished`
    # + expectedVersion - Version read before the change
    # + return - `VERSION_CONFLICT`, or another error
    public isolated function recordPublish(PublishResult result, int expectedVersion) returns error? {
        final readonly & PublishResult r = result.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.recordPublishTx(r, expectedVersion));
    }

    private isolated function recordPublishTx(PublishResult result, int expectedVersion) returns error? {
        Engagement e = result.engagement;
        transaction {
            _ = check self.db->execute(`
                INSERT INTO sharing.engagement (id, provider, provider_api, origin, target_resource_urn, campaign_id,
                    actor_member_urn, employee_id, action, activity_urn, occurred_at, observed_at, last_verified_at,
                    deleted_at)
                VALUES (CAST(${e.id} AS uuid), ${e.provider}, ${e.providerApi}, ${e.origin}, ${e.targetResourceUrn},
                    CAST(${e.campaignId} AS uuid), ${e.actorMemberUrn}, ${e.employeeId}, ${e.action}, ${e.activityUrn},
                    CAST(${store:ts(e.occurredAt)} AS timestamptz), CAST(${store:ts(e.observedAt)} AS timestamptz), CAST(${store:ts(e.lastVerifiedAt)} AS timestamptz), CAST(${store:ts(e.deletedAt)} AS timestamptz))`);
            check self.updateRow(result.request, expectedVersion, result.outbox);
            check commit;
        }
    }

    # Settles a publish that `recordPublish` refused with an engagement unique violation: links the request to
    # this employee's engagement already stored (same target and action, or the same activity) and marks it
    # `PUBLISHED`, with no new engagement and no event (`asDuplicatePublish`). Without this the request
    # stayed `QUEUED` for good and the employee couldn't ask again (domain review H-5).
    #
    # + result - From `markPublished` (the attempt that hit the unique key)
    # + expectedVersion - Version read before the change
    # + return - True when settled, false when this employee has no matching engagement (an activity URN
    # held by someone else is never borrowed; the caller fails the request),
    # `VERSION_CONFLICT`, or another error
    public isolated function recordDuplicatePublish(PublishResult result, int expectedVersion) returns boolean|error {
        final readonly & PublishResult r = result.cloneReadOnly();
        return (check store:inTransactionValue(() => self.recordDuplicatePublishTx(r, expectedVersion))).ensureType();
    }

    private isolated function recordDuplicatePublishTx(PublishResult result, int expectedVersion) returns boolean|error {
        Engagement e = result.engagement;
        boolean settled = false;
        transaction {
            string|error existing = self.db->queryRow(`
                SELECT id::text FROM sharing.engagement
                WHERE provider = ${e.provider} AND employee_id = ${e.employeeId}
                  AND ((target_resource_urn = ${e.targetResourceUrn} AND action = ${e.action})
                       OR activity_urn = ${e.activityUrn})
                ORDER BY observed_at
                LIMIT 1`);
            if existing is error {
                if !store:isNoRows(existing) {
                    fail existing;
                }
            } else {
                check self.updateRow(check asDuplicatePublish(result, existing), expectedVersion, []);
                settled = true;
            }
            check commit;
        }
        return settled;
    }

    private isolated transactional function updateRow(ShareRequest r, int expectedVersion, events:OutboxEvent[] outbox)
            returns error? {
        record {|string kind; int attempts; time:Utc? published_at; time:Utc? failed_at;|}|error old = self.db->queryRow(`
            UPDATE sharing.share_request
            SET kind = ${r.kind}, commentary = ${r.commentary}, published_at = CAST(${store:ts(r.publishedAt)} AS timestamptz),
                failed_at = CAST(${store:ts(r.failedAt)} AS timestamptz), failure_reason = ${r.failureReason}, attempts = ${r.attempts},
                last_error_code = ${r.lastErrorCode}, engagement_id = CAST(${r.engagementId} AS uuid),
                version = ${r.version}
            WHERE id = CAST(${r.id} AS uuid) AND version = ${expectedVersion}
            RETURNING old.kind, old.attempts, old.published_at, old.failed_at`);
        if old is error {
            return store:isNoRows(old) ? store:versionConflict("share") : old;
        }
        _ = check store:writeOutbox(self.db, outbox, self.actor.correlationId);
        ShareStatus before = old.published_at !is () ? PUBLISHED : old.failed_at !is () ? FAILED : QUEUED;
        check store:writeAudit(self.db, store:auditOf(self.actor, auditAction(r, outbox), SHARE_TABLE, r.id,
                {kind: r.kind, attempts: r.attempts, status: shareStatus(r)}, (),
                {kind: old.kind, attempts: old.attempts, status: before}));
    }

    private isolated function insertTx(ShareRequest r, events:OutboxEvent[] outbox) returns error? {
        transaction {
            _ = check self.db->execute(`
                INSERT INTO sharing.share_request (id, campaign_id, employee_id, provider, provider_api,
                    target_resource_urn, kind, commentary, requested_at, published_at, failed_at, failure_reason,
                    attempts, last_error_code, engagement_id, version)
                VALUES (CAST(${r.id} AS uuid), CAST(${r.campaignId} AS uuid), ${r.employeeId}, ${r.provider},
                    ${r.providerApi}, ${r.targetResourceUrn}, ${r.kind}, ${r.commentary}, CAST(${store:ts(r.requestedAt)} AS timestamptz),
                    CAST(${store:ts(r.publishedAt)} AS timestamptz), CAST(${store:ts(r.failedAt)} AS timestamptz), ${r.failureReason}, ${r.attempts}, ${r.lastErrorCode},
                    CAST(${r.engagementId} AS uuid), ${r.version})`);
            _ = check store:writeOutbox(self.db, outbox, self.actor.correlationId);
            check store:writeAudit(self.db, store:auditOf(self.actor, events:REPOST_REQUESTED, SHARE_TABLE, r.id,
                    {campaignId: r.campaignId, kind: r.kind}));
            check commit;
        }
    }
}

isolated function auditAction(ShareRequest request, events:OutboxEvent[] outbox) returns string =>
    outbox.length() > 0 ? outbox[0].eventType : string `Share${shareStatus(request)}`;

# The error for the request already stored for this campaign and employee, chosen by its state and not by
# the insert conflict: a `PUBLISHED` row reports `SHARE_ALREADY_PUBLISHED`, anything else
# `SHARE_ALREADY_QUEUED`. A `FAILED` row is retried through `retryShare`, so a conflict on it is a
# concurrent request. If the state can't be read it reports `SHARE_ALREADY_QUEUED`: refusing the duplicate
# is right either way.
#
# + db - Client, after the insert transaction rolled back
# + request - The request whose insert conflicted
# + return - The domain error to report
isolated function existingShareError(postgresql:Client db, ShareRequest request) returns types:DomainError {
    string|error status = db->queryRow(`
        SELECT status FROM sharing.share_request_v
        WHERE campaign_id = CAST(${request.campaignId} AS uuid) AND employee_id = ${request.employeeId}`);
    if status is string && status == "PUBLISHED" {
        return types:domainError(types:ERR_SHARE_ALREADY_PUBLISHED, "You already shared this campaign");
    }
    return types:domainError(types:ERR_SHARE_ALREADY_QUEUED, "You already asked to share this campaign");
}

isolated function toShare(ShareRow|error row) returns ShareRequest|error? {
    if row is error {
        return store:isNoRows(row) ? () : row;
    }
    string? reason = row.failure_reason;
    return {
        id: row.id,
        campaignId: row.campaign_id,
        employeeId: row.employee_id,
        provider: check row.provider.ensureType(),
        providerApi: check row.provider_api.ensureType(),
        targetResourceUrn: row.target_resource_urn,
        kind: check row.kind.ensureType(),
        commentary: row.commentary,
        requestedAt: row.requested_at,
        publishedAt: row.published_at,
        failedAt: row.failed_at,
        failureReason: reason is () ? () : check reason.ensureType(),
        attempts: row.attempts,
        lastErrorCode: row.last_error_code,
        engagementId: row.engagement_id,
        version: row.version
    };
}
