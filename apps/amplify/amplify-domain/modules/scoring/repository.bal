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

// PostgreSQL implementations of `LedgerRepository` and `PointRuleRepository` (schema `scoring`).
// `append` also applies the row to the S4 read models in the same transaction (B12) through
// `recognition.apply_ledger_entry` (V010): recognition is a projection of this ledger, never a source.

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

const string LEDGER_TABLE = "scoring.points_ledger";

type LedgerRow record {|
    string reference;
    string employee_id;
    string? campaign_id;
    string source_type;
    string? source_id;
    string? action;
    int points;
    string? rule_id;
    string? reverses_reference;
    string? reason;
    string actor_id;
    string? correlation_id;
    time:Utc created_at;
    string? status;
    time:Utc? status_changed_at;
    time:Utc? paid_at;
    string? coin_reference;
|};

type RuleRow record {|
    string id;
    string action;
    int points;
    time:Utc effective_from;
    string created_by;
    time:Utc created_at;
|};

# `LedgerRepository` over PostgreSQL.
public isolated class PgLedgerRepository {
    *LedgerRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;
    private final int topN;

    # + db - Shared client (`amplify_api` or `amplify_jobs`)
    # + actor - Who the writes are for (audit)
    # + topN - `leaderboard.top_n`, for `points_to_top_n`
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM, int topN = 3) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
        self.topN = topN;
    }

    public isolated function append(LedgerAppend append) returns boolean|error {
        final readonly & LedgerAppend a = append.cloneReadOnly();
        anydata|error result = store:inTransactionValue(isolated function () returns boolean|error => self.appendTx(a));
        if result is error {
            // The other expected conflict: a second reversal of the same row (`points_ledger_reverses_uk`).
            // The re-run is a no-op, not a failure; the transaction has already rolled back here.
            return store:isUniqueViolation(result, "points_ledger_reverses_uk") ? false : result;
        }
        return result.ensureType();
    }

    private isolated function appendTx(LedgerAppend append) returns boolean|error {
        boolean inserted = false;
        transaction {
            inserted = check appendInTransaction(self.db, self.actor, append, self.topN);
            check commit;
        }
        return inserted;
    }

    public isolated function findByReference(types:LedgerReference reference) returns types:LedgerEntry|error? {
        LedgerRow|error row = self.db->queryRow(`
            SELECT reference, employee_id, campaign_id::text AS campaign_id, source_type, source_id::text AS source_id,
                   action, points, rule_id::text AS rule_id, reverses_reference, reason, actor_id, correlation_id,
                   created_at, status, status_changed_at, paid_at, coin_reference
            FROM scoring.points_ledger WHERE reference = ${reference}`);
        return toEntry(row);
    }

    public isolated function findReversalOf(types:LedgerReference reference) returns types:LedgerEntry|error? {
        LedgerRow|error row = self.db->queryRow(`
            SELECT reference, employee_id, campaign_id::text AS campaign_id, source_type, source_id::text AS source_id,
                   action, points, rule_id::text AS rule_id, reverses_reference, reason, actor_id, correlation_id,
                   created_at, status, status_changed_at, paid_at, coin_reference
            FROM scoring.points_ledger WHERE reverses_reference = ${reference}`);
        return toEntry(row);
    }

    public isolated function updateSettlement(types:LedgerReference reference, types:LedgerStatus? status, time:Utc changedAt)
            returns error? {
        final readonly & time:Utc at = changedAt.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.updateSettlementTx(reference, status, at));
    }

    private isolated function updateSettlementTx(types:LedgerReference reference, types:LedgerStatus? status,
            time:Utc changedAt) returns error? {
        transaction {
            // Only the settlement columns: the column-level grant refuses anything else.
            record {|string? status;|}|error before = self.db->queryRow(`
                UPDATE scoring.points_ledger SET status = ${status}, status_changed_at = CAST(${store:ts(changedAt)} AS timestamptz)
                WHERE reference = ${reference}
                RETURNING old.status`);
            if before is error {
                fail store:isNoRows(before) ? types:domainError(types:ERR_NOT_FOUND, "Ledger entry not found") : before;
            }
            check store:writeAudit(self.db, store:auditOf(self.actor, "PointsSettlementChanged", LEDGER_TABLE,
                    reference, {status}, (), {status: before.status}));
            check commit;
        }
    }
}

# `PointRuleRepository` over PostgreSQL.
public isolated class PgPointRuleRepository {
    *PointRuleRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client (`amplify_api` writes, `amplify_jobs` reads)
    # + actor - Who the writes are for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function all() returns PointRule[]|error {
        stream<RuleRow, error?> rows = self.db->query(`
            SELECT id::text AS id, action, points, effective_from, created_by, created_at
            FROM scoring.point_rule ORDER BY action, effective_from`);
        return from RuleRow r in rows
            select {
                id: r.id,
                action: check r.action.ensureType(),
                points: r.points,
                effectiveFrom: r.effective_from,
                createdBy: r.created_by,
                createdAt: r.created_at
            };
    }

    public isolated function insert(PointRule rule) returns error? {
        final readonly & PointRule r = rule.cloneReadOnly();
        error? result = store:inTransaction(isolated function () returns error? => self.insertTx(r));
        if result is error && store:isUniqueViolation(result, "point_rule_version_uk") {
            return types:domainError(types:ERR_RULE_VERSION_EXISTS, "A version already starts at that time");
        }
        return result;
    }

    private isolated function insertTx(PointRule rule) returns error? {
        transaction {
            _ = check self.db->execute(`
                INSERT INTO scoring.point_rule (id, action, points, effective_from, created_by, created_at)
                VALUES (CAST(${rule.id} AS uuid), ${rule.action}, ${rule.points}, CAST(${store:ts(rule.effectiveFrom)} AS timestamptz),
                        ${rule.createdBy}, CAST(${store:ts(rule.createdAt)} AS timestamptz))`);
            check store:writeAudit(self.db, store:auditOf(self.actor, "PointRuleVersionAdded", "scoring.point_rule",
                    rule.id, {action: rule.action, points: rule.points}));
            check commit;
        }
    }
}

isolated function toEntry(LedgerRow|error row) returns types:LedgerEntry|error? {
    if row is error {
        return store:isNoRows(row) ? () : row;
    }
    string? action = row.action;
    string? status = row.status;
    return {
        reference: row.reference,
        employeeId: row.employee_id,
        campaignId: row.campaign_id,
        sourceType: check row.source_type.ensureType(),
        sourceId: row.source_id,
        action: action is () ? () : check action.ensureType(),
        points: row.points,
        ruleId: row.rule_id,
        reversesReference: row.reverses_reference,
        reason: row.reason,
        actorId: row.actor_id,
        correlationId: row.correlation_id,
        createdAt: row.created_at,
        status: status is () ? () : check status.ensureType(),
        statusChangedAt: row.status_changed_at,
        paidAt: row.paid_at,
        coinReference: row.coin_reference
    };
}

# Inserts a ledger row with its outbox event, audit row and the recognition update (B12), inside the
# caller's transaction. Lets another context's write and the award commit together (S3 → C2 approve /
# amplified, ADR-024).
#
# + db - Client, inside the caller's transaction
# + actor - Who (audit)
# + append - Row and event
# + topN - `leaderboard.top_n`
# + return - True if inserted; false when the reference already exists (an idempotent repeat, not a
#            failure), or an error
public isolated transactional function appendInTransaction(postgresql:Client db, store:Actor actor, LedgerAppend append,
        int topN = 3) returns boolean|error {
    types:LedgerEntry e = append.entry;
    // Only the documented conflict target: a repeated reference (re-run) inserts nothing. Any other unique
    // violation - a new constraint, a bad reference - is a real error and surfaces as one. The other
    // expected conflict, a second reversal of the same row, is caught in `append`, outside the transaction.
    var result = check db->execute(`
        INSERT INTO scoring.points_ledger (reference, employee_id, campaign_id, source_type, source_id, action,
            points, rule_id, reverses_reference, reason, actor_id, correlation_id, created_at, status,
            status_changed_at, paid_at, coin_reference)
        VALUES (${e.reference}, ${e.employeeId}, CAST(${e.campaignId} AS uuid), ${e.sourceType},
            CAST(${e.sourceId} AS uuid), ${e.action}, ${e.points}, CAST(${e.ruleId} AS uuid),
            ${e.reversesReference}, ${e.reason}, ${e.actorId}, ${e.correlationId}, CAST(${store:ts(e.createdAt)} AS timestamptz), ${e.status},
            CAST(${store:ts(e.statusChangedAt)} AS timestamptz), CAST(${store:ts(e.paidAt)} AS timestamptz), ${e.coinReference})
        ON CONFLICT (reference) DO NOTHING`);
    boolean inserted = result.affectedRowCount == 1;
    if inserted {
        _ = check store:writeOutbox(db, [append.event], e.correlationId ?: actor.correlationId);
        check store:writeAudit(db, store:auditOf(actor, append.event.eventType, LEDGER_TABLE,
                e.reference, {employeeId: e.employeeId, points: e.points, action: e.action}, e.reason));
        // Serialize the re-rank (R-01): without the lock two appends deadlock in the period-wide UPDATE,
        // or store ranks computed without each other's row. Lock order: this app-level lock (4242101)
        // first, then apply_ledger_entry takes the SQL-level one (1634561133). Called inside the transaction
        // gate (R-13), so the poll gives up after 2 s instead of stalling every other write.
        check store:lockRecognition(db);
        _ = check db->queryRow(`SELECT recognition.apply_ledger_entry(${e.reference}, CAST(${topN} AS int))`, int);
    }
    return inserted;
}
