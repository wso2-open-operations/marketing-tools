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

// PostgreSQL implementation of `ExternalShareRepository` (schema `external_sharing` only).
// The (evidence_url, action) unique key is the C5 backstop under a race.

import amplify_common.events;
import amplify_common.types;
import amplify_domain.scoring;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

const string EXTERNAL_SHARE_TABLE = "external_sharing.external_share";

type ExternalShareRow record {|
    string id;
    string employee_id;
    string? campaign_id;
    string action;
    string evidence_url;
    string evidence_url_submitted;
    string evidence_host;
    string provider;
    string? resource_urn;
    time:Utc certified_at;
    string? decision;
    string? decided_by;
    time:Utc? decided_at;
    string? decision_reason;
    time:Utc? amplified_at;
    time:Utc created_at;
    int version;
|};

# `ExternalShareRepository` over PostgreSQL.
public isolated class PgExternalShareRepository {
    *ExternalShareRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;
    private final int topN;

    # + db - Shared client (`amplify_api`)
    # + actor - Who the writes are for (audit)
    # + topN - `leaderboard.top_n`, for awards written with a decision
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM, int topN = 3) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
        self.topN = topN;
    }

    public isolated function findById(string id) returns ExternalShare|error? {
        ExternalShareRow|error row = self.db->queryRow(`
            SELECT id::text AS id, employee_id, campaign_id::text AS campaign_id, action, evidence_url,
                   evidence_url_submitted, evidence_host, provider, resource_urn, certified_at, decision, decided_by,
                   decided_at, decision_reason, amplified_at, created_at, version
            FROM external_sharing.external_share WHERE id = CAST(${id} AS uuid)`);
        return toClaim(row);
    }

    public isolated function isClaimed(string normalizedUrl, types:ExternalAction action) returns boolean|error {
        boolean claimed = check self.db->queryRow(`
            SELECT EXISTS (SELECT 1 FROM external_sharing.external_share
                           WHERE evidence_url = ${normalizedUrl} AND action = ${action})`);
        return claimed;
    }

    public isolated function insert(ExternalShare claim, events:OutboxEvent[] outbox) returns error? {
        final readonly & ExternalShare c = claim.cloneReadOnly();
        final readonly & events:OutboxEvent[] queued = outbox.cloneReadOnly();
        error? result = store:inTransaction(isolated function () returns error? => self.insertTx(c, queued));
        if result is error && store:isUniqueViolation(result, "external_share_evidence_uk") {
            return evidenceAlreadyClaimed();
        }
        return result;
    }

    public isolated function update(ExternalShare claim, int expectedVersion, events:OutboxEvent[] outbox) returns error? {
        final readonly & ExternalShare c = claim.cloneReadOnly();
        final readonly & events:OutboxEvent[] queued = outbox.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.updateTx(c, expectedVersion, queued));
    }

    private isolated function updateTx(ExternalShare claim, int expectedVersion, events:OutboxEvent[] outbox)
            returns error? {
        transaction {
            check self.updateRow(claim, expectedVersion, outbox);
            check commit;
        }
    }

    public isolated function updateWithAward(ExternalShare claim, int expectedVersion, events:OutboxEvent[] outbox,
            scoring:LedgerAppend award) returns error? {
        final readonly & ExternalShare c = claim.cloneReadOnly();
        final readonly & events:OutboxEvent[] queued = outbox.cloneReadOnly();
        final readonly & scoring:LedgerAppend a = award.cloneReadOnly();
        return store:inTransaction(() => self.updateWithAwardTx(c, expectedVersion, queued, a));
    }

    private isolated function updateWithAwardTx(ExternalShare claim, int expectedVersion, events:OutboxEvent[] outbox,
            scoring:LedgerAppend award) returns error? {
        transaction {
            check self.updateRow(claim, expectedVersion, outbox);
            boolean awarded = check scoring:appendInTransaction(self.db, self.actor, award, self.topN);
            if !awarded {
                // The ledger reference already exists (ADR-029: a hash of provider, URL, employee and action).
                // Committing would record the decision with no ledger row, no PointsAwarded event and no
                // re-rank, and report success; roll the decision back instead.
                fail types:domainError(types:ERR_EVIDENCE_ALREADY_CLAIMED, "These points were already awarded for this post");
            }
            check commit;
        }
    }

    private isolated transactional function updateRow(ExternalShare c, int expectedVersion, events:OutboxEvent[] outbox)
            returns error? {
        // PostgreSQL 18 `RETURNING old.*`: the audit row records the state before the change too.
        record {|string? decision; time:Utc? amplified_at; int version;|}|error old = self.db->queryRow(`
            UPDATE external_sharing.external_share
            SET decision = ${c.decision}, decided_by = ${c.decidedBy}, decided_at = CAST(${store:ts(c.decidedAt)} AS timestamptz),
                decision_reason = ${c.decisionReason}, amplified_at = CAST(${store:ts(c.amplifiedAt)} AS timestamptz), version = ${c.version}
            WHERE id = CAST(${c.id} AS uuid) AND version = ${expectedVersion}
            RETURNING old.decision, old.amplified_at, old.version`);
        if old is error {
            return store:isNoRows(old) ? store:versionConflict("external share") : old;
        }
        _ = check store:writeOutbox(self.db, outbox, self.actor.correlationId);
        string action = outbox.length() > 0 ? outbox[0].eventType : "ExternalShareUpdated";
        string? oldDecision = old.decision;
        ExternalShareStatus before = oldDecision is () ? PENDING : old.amplified_at !is () ? AMPLIFIED
            : oldDecision == DECISION_APPROVED ? APPROVED : REJECTED;
        check store:writeAudit(self.db, store:auditOf(self.actor, action, EXTERNAL_SHARE_TABLE, c.id,
                {status: externalShareStatus(c), version: c.version}, c.decisionReason,
                {status: before, version: old.version}));
    }

    private isolated function insertTx(ExternalShare c, events:OutboxEvent[] outbox) returns error? {
        transaction {
            _ = check self.db->execute(`
                INSERT INTO external_sharing.external_share (id, employee_id, campaign_id, action, evidence_url,
                    evidence_url_submitted, evidence_host, provider, resource_urn, certified_at, decision, decided_by,
                    decided_at, decision_reason, amplified_at, created_at, version)
                VALUES (CAST(${c.id} AS uuid), ${c.employeeId}, CAST(${c.campaignId} AS uuid), ${c.action},
                    ${c.evidence.normalized}, ${c.evidence.submitted}, ${c.evidence.host}, ${c.evidence.provider},
                    ${c.evidence.resourceUrn}, CAST(${store:ts(c.certifiedAt)} AS timestamptz), ${c.decision}, ${c.decidedBy}, CAST(${store:ts(c.decidedAt)} AS timestamptz),
                    ${c.decisionReason}, CAST(${store:ts(c.amplifiedAt)} AS timestamptz), CAST(${store:ts(c.createdAt)} AS timestamptz), ${c.version})`);
            _ = check store:writeOutbox(self.db, outbox, self.actor.correlationId);
            check store:writeAudit(self.db, store:auditOf(self.actor, events:EXTERNAL_SHARE_SUBMITTED,
                    EXTERNAL_SHARE_TABLE, c.id, {evidenceHost: c.evidence.host}));
            check commit;
        }
    }
}

isolated function toClaim(ExternalShareRow|error row) returns ExternalShare|error? {
    if row is error {
        return store:isNoRows(row) ? () : row;
    }
    string? decision = row.decision;
    return {
        id: row.id,
        employeeId: row.employee_id,
        campaignId: row.campaign_id,
        action: check row.action.ensureType(),
        evidence: {
            normalized: row.evidence_url,
            submitted: row.evidence_url_submitted,
            host: row.evidence_host,
            provider: row.provider,
            resourceUrn: row.resource_urn
        },
        certifiedAt: row.certified_at,
        decision: decision is () ? () : check decision.ensureType(),
        decidedBy: row.decided_by,
        decidedAt: row.decided_at,
        decisionReason: row.decision_reason,
        amplifiedAt: row.amplified_at,
        createdAt: row.created_at,
        version: row.version
    };
}
