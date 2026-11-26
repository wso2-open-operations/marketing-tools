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

// PostgreSQL implementation of `VerificationRepository` (V027). Writes only the scoring ledger: its settlement and
// verification columns (the V027 guard allows nothing else) and the system reversal of a row whose activity is gone,
// appended like any reversal (outbox event, audit row, recognition in the same transaction, B12).

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# `VerificationRepository` over PostgreSQL. The verification runs on the jobs' own single connection, under its lock.
public isolated class PgVerificationRepository {
    *VerificationRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;
    private final int topN;

    # + db - Client
    # + actor - Who the writes are for (audit); the verification runs as `system`
    # + topN - `leaderboard.top_n`, for the recognition update of a reversal
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM, int topN = 3) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
        self.topN = topN;
    }

    public isolated function dueForCheck(time:Utc staleBefore, int 'limit) returns VerifyCandidate[]|error {
        stream<record {|string reference; string employee_id; string source_id; string? action;|}, error?> rows =
            self.db->query(`
            SELECT l.reference, l.employee_id, l.source_id::text AS source_id, l.action
            FROM scoring_points_ledger l
            WHERE l.source_type = 'ENGAGEMENT' AND l.status = 'HELD' AND l.coin_reference IS NULL
              AND l.source_id IS NOT NULL
              AND (l.verification IS NULL
                   OR (l.verification = 'VERIFIED' AND l.verified_at < CAST(${store:ts(staleBefore)} AS timestamptz)))
              AND NOT EXISTS (SELECT 1 FROM scoring_points_ledger r WHERE r.reverses_reference = l.reference)
            ORDER BY l.verified_at NULLS FIRST, l.created_at, l.reference
            LIMIT ${'limit}`);
        return from var r in rows
            let string? action = r.action
            select {
                reference: r.reference,
                employeeId: r.employee_id,
                engagementId: r.source_id,
                action: action is () ? () : check action.ensureType()
            };
    }

    public isolated function markVerified(types:LedgerReference reference, time:Utc now) returns error? {
        final readonly & time:Utc at = now.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.markVerifiedTx(reference, at));
    }

    private isolated function markVerifiedTx(types:LedgerReference reference, time:Utc now) returns error? {
        transaction {
            var updated = check self.db->execute(`
                UPDATE scoring_points_ledger
                   SET verification = ${types:VERIFIED}, verified_at = CAST(${store:ts(now)} AS timestamptz),
                       verification_reason = NULL
                 WHERE reference = ${reference} AND status = 'HELD' AND coin_reference IS NULL`);
            if updated.affectedRowCount == 1 {
                check store:writeAudit(self.db, store:auditOf(self.actor, "PointsVerified", LEDGER_TABLE, reference,
                        {verification: types:VERIFIED}));
            }
            check commit;
        }
    }

    public isolated function markUnverifiable(types:LedgerReference reference, string reason, time:Utc now)
            returns error? {
        final readonly & time:Utc at = now.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.markUnverifiableTx(reference, reason, at));
    }

    private isolated function markUnverifiableTx(types:LedgerReference reference, string reason, time:Utc now)
            returns error? {
        transaction {
            var updated = check self.db->execute(`
                UPDATE scoring_points_ledger
                   SET status = NULL, status_changed_at = CAST(${store:ts(now)} AS timestamptz),
                       verification = ${types:UNVERIFIABLE}, verified_at = CAST(${store:ts(now)} AS timestamptz),
                       verification_reason = ${reason}
                 WHERE reference = ${reference} AND status = 'HELD' AND coin_reference IS NULL`);
            if updated.affectedRowCount == 1 {
                check store:writeAudit(self.db, store:auditOf(self.actor, "PointsSettlementChanged", LEDGER_TABLE,
                        reference, {status: (), verification: types:UNVERIFIABLE, verificationReason: reason},
                        "Could not be checked on LinkedIn", {status: types:HELD}));
            }
            check commit;
        }
    }

    public isolated function reverseRemoved(types:LedgerReference reference, string? correlationId, time:Utc now)
            returns boolean|error {
        final readonly & time:Utc at = now.cloneReadOnly();
        anydata|error result = store:inTransactionValue(isolated function () returns boolean|error =>
            self.reverseRemovedTx(reference, correlationId, at));
        if result is error {
            // A PO reversed the same row meanwhile (`points_ledger_reverses_uk`): nothing left to do.
            return store:isUniqueViolation(result, "points_ledger_reverses_uk") ? false : result;
        }
        return result.ensureType();
    }

    private isolated function reverseRemovedTx(types:LedgerReference reference, string? correlationId, time:Utc now)
            returns boolean|error {
        boolean reversed = false;
        transaction {
            LedgerRow|error row = self.db->queryRow(`
                SELECT reference, employee_id, campaign_id::text AS campaign_id, source_type, source_id::text AS source_id,
                       action, points, rule_id::text AS rule_id, reverses_reference, reason, actor_id, correlation_id,
                       created_at, status, status_changed_at, paid_at, coin_reference, verification, verified_at,
                       verification_reason
                FROM scoring_points_ledger WHERE reference = ${reference} FOR UPDATE`);
            types:LedgerEntry? original = check toEntry(row);
            if original is types:LedgerEntry && original.status == types:HELD && original.coinReference is () {
                int reversals = check self.db->queryRow(`
                    SELECT count(*)::int FROM scoring_points_ledger WHERE reverses_reference = ${reference}`);
                if reversals == 0 {
                    LedgerAppend append = check reversal(original, (), REASON_NO_LONGER_ON_LINKEDIN, types:SYSTEM_ACTOR,
                            types:newUuidV7(), correlationId, now);
                    _ = check self.db->execute(`
                        UPDATE scoring_points_ledger
                           SET verification = ${types:REMOVED}, verified_at = CAST(${store:ts(now)} AS timestamptz),
                               verification_reason = NULL
                         WHERE reference = ${reference}`);
                    reversed = check appendInTransaction(self.db, self.actor, append, self.topN);
                    if !reversed {
                        fail error("The reversal was not written");
                    }
                }
            }
            check commit;
        }
        return reversed;
    }
}
