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

// Invalid activity (ADR-010 amendment 2026-11-26): a PO removed an engagement's points as not a valid activity, and C2
// wrote `ActivityRemoved` with the reversal. C1 flags the engagement here, in its own tables only: `invalidated_at` and
// `invalid_reason` on `sharing_engagement`. `sharing_engagement_v` then derives `INVALID`, so dashboards (status
// `ACTIVE`) leave it out. The sync never records it again (the reshare is already covered, a reaction or comment hits
// `engagement_once_uk`), so its award is never priced twice. Flagging is idempotent: amplify-api flags right after the
// reversal and amplify-jobs handles the outbox row as the backstop; the second one changes nothing.

import amplify_common.events;
import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Persistence port for the invalid-activity flag on `sharing_engagement`.
public type InvalidActivityRepository isolated object {
    # Flags an engagement invalid, once: a flagged engagement keeps its first reason and time.
    #
    # + engagementId - Engagement
    # + reason - Reason code
    # + reference - The reversal that removed its points (audit)
    # + at - When the PO removed it
    # + return - True when flagged now, false when already flagged, `NOT_FOUND`, or an error
    public isolated function markInvalid(string engagementId, types:RemovalReason reason, types:LedgerReference reference,
            time:Utc at) returns boolean|error;
};

# Flags the engagement of an `ActivityRemoved` event invalid. Safe to repeat.
#
# + repo - Repository
# + event - From the removal
# + return - True when flagged now, false when it already was, or an error
public isolated function markEngagementInvalid(InvalidActivityRepository repo, events:ActivityRemoved event)
        returns boolean|error {
    string engagementId = event.engagementId.trim().toLowerAscii();
    if !re `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`.isFullMatch(engagementId) {
        return types:domainError(types:ERR_INVALID_UUID, "Engagement id must be a UUID");
    }
    return repo.markInvalid(engagementId, event.removalReason, event.reference, check time:utcFromString(event.removedAt));
}

# `InvalidActivityRepository` over PostgreSQL.
public isolated class PgInvalidActivityRepository {
    *InvalidActivityRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client (`amplify_api` or `amplify_jobs`)
    # + actor - Who the write is for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function markInvalid(string engagementId, types:RemovalReason reason, types:LedgerReference reference,
            time:Utc at) returns boolean|error {
        final readonly & time:Utc when = at.cloneReadOnly();
        return (check store:inTransactionValue(() => self.markInvalidTx(engagementId, reason, reference, when)))
            .ensureType();
    }

    private isolated function markInvalidTx(string engagementId, types:RemovalReason reason,
            types:LedgerReference reference, time:Utc at) returns boolean|error {
        boolean flagged = false;
        transaction {
            var result = check self.db->execute(`
                UPDATE sharing_engagement
                SET invalidated_at = CAST(${store:ts(at)} AS timestamptz), invalid_reason = ${reason}
                WHERE id = CAST(${engagementId} AS uuid) AND invalidated_at IS NULL`);
            flagged = result.affectedRowCount == 1;
            if flagged {
                check store:writeAudit(self.db, store:auditOf(self.actor, "EngagementInvalidated", ENGAGEMENT_TABLE,
                        engagementId, {invalidReason: reason, reversal: reference}));
            } else {
                int|error exists = self.db->queryRow(`
                    SELECT 1 FROM sharing_engagement WHERE id = CAST(${engagementId} AS uuid)`);
                if exists is error {
                    fail store:isNoRows(exists) ? types:domainError(types:ERR_NOT_FOUND, "Engagement not found") : exists;
                }
            }
            check commit;
        }
        return flagged;
    }
}
