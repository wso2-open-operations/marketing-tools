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

// PostgreSQL implementations of `CoinRepository` and `CoinWalletRepository` (V026, ADR-048). Reads and writes only the
// scoring context's tables: `scoring_coin_*` and the ledger's settlement columns (`status`, `status_changed_at`,
// `paid_at`, `coin_reference`; the V021 guard refuses anything else, and V026 makes a PAID row final).

import amplify_common.types;
import amplify_domain.store;

import ballerina/sql;
import ballerina/time;
import ballerinax/postgresql;

const string ISSUE_TABLE = "scoring_coin_issue";

type IssueRow record {|
    string id;
    string run_id;
    string employee_id;
    int points_in;
    int carry_in;
    int coins;
    int carry_out;
    string? wallet_address;
    string reference;
    string? transfer_reference;
    string status;
    int attempts;
    string? last_error_code;
    time:Utc? next_attempt_at;
    time:Utc? attempted_at;
|};

type WalletRow record {|
    string employee_id;
    string wallet_address;
    time:Utc captured_at;
|};

# `CoinRepository` over PostgreSQL. The conversion runs on the jobs' own single connection, under its advisory lock.
public isolated class PgCoinRepository {
    *CoinRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Client
    # + actor - Who the writes are for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function openRun(string period, time:Utc now) returns CoinRun|error {
        CoinRun run = check self.db->queryRow(`
            INSERT INTO scoring_coin_run (period, status, started_at)
            VALUES (${period}, 'RUNNING', CAST(${store:ts(now)} AS timestamptz))
            ON CONFLICT (period) DO UPDATE
                SET status = 'RUNNING', stop_reason = NULL, started_at = EXCLUDED.started_at, finished_at = NULL
            RETURNING id::text AS id, period`);
        return run;
    }

    public isolated function openIssues() returns CoinIssue[]|error =>
        self.issues(sql:queryConcat(`SELECT `, issueColumns(), ` FROM scoring_coin_issue
                     WHERE status IN ('PENDING', 'UNKNOWN') ORDER BY attempted_at NULLS FIRST, id`));

    public isolated function issuesOf(string runId) returns map<CoinIssue>|error {
        CoinIssue[] rows = check self.issues(sql:queryConcat(`SELECT `, issueColumns(), ` FROM scoring_coin_issue
                                              WHERE run_id = CAST(${runId} AS uuid)`));
        return map from CoinIssue i in rows select [i.employeeId, i];
    }

    public isolated function candidates() returns CoinCandidate[]|error {
        // Oldest waiting first: the run cap, when it bites, serves the people who have waited longest.
        stream<record {|string employee_id; string reference; int points;|}, error?> rows = self.db->query(`
            SELECT employee_id, reference, points FROM scoring_points_ledger
            WHERE status = 'HELD' AND coin_reference IS NULL
            ORDER BY created_at, reference`);
        map<CoinCandidate> byEmployee = {};
        string[] arrival = [];
        check from var r in rows
            do {
                CoinCandidate? c = byEmployee[r.employee_id];
                if c is () {
                    byEmployee[r.employee_id] = {employeeId: r.employee_id, carryIn: 0,
                        rows: [{reference: r.reference, points: r.points}], walletAddress: ()};
                    arrival.push(r.employee_id);
                } else {
                    c.rows.push({reference: r.reference, points: r.points});
                }
            };
        stream<record {|string employee_id; int carry_out;|}, error?> carries = self.db->query(`
            SELECT DISTINCT ON (employee_id) employee_id, carry_out FROM scoring_coin_issue
            WHERE status = 'SENT' ORDER BY employee_id, sent_at DESC, created_at DESC`);
        string[] carryOnly = [];
        check from var r in carries
            do {
                CoinCandidate? c = byEmployee[r.employee_id];
                if c is CoinCandidate {
                    c.carryIn = r.carry_out;
                } else if r.carry_out > 0 {
                    byEmployee[r.employee_id] = {employeeId: r.employee_id, carryIn: r.carry_out, rows: [],
                        walletAddress: ()};
                    carryOnly.push(r.employee_id);
                }
            };
        stream<record {|string employee_id; string wallet_address;|}, error?> wallets = self.db->query(`
            SELECT employee_id, wallet_address FROM scoring_coin_wallet`);
        check from var w in wallets
            do {
                CoinCandidate? c = byEmployee[w.employee_id];
                if c is CoinCandidate {
                    c.walletAddress = w.wallet_address;
                }
            };
        // A carry with no new rows waited since a past run: before anyone with rows from this period.
        return from string id in [...carryOnly, ...arrival] select <CoinCandidate>byEmployee[id];
    }

    public isolated function committedCoins(string runId) returns int|error {
        int coins = check self.db->queryRow(`
            SELECT coalesce(sum(coins), 0)::int FROM scoring_coin_issue
            WHERE run_id = CAST(${runId} AS uuid) AND status IN ('SENT', 'PENDING', 'UNKNOWN')`);
        return coins;
    }

    public isolated function transferTaken(string transferReference) returns boolean|error {
        boolean taken = check self.db->queryRow(`
            SELECT EXISTS (SELECT 1 FROM scoring_coin_issue WHERE transfer_reference = ${transferReference})`);
        return taken;
    }

    public isolated function begin(CoinPlan plan, string runId, time:Utc now) returns CoinIssue|error {
        final readonly & CoinPlan p = plan.cloneReadOnly();
        final readonly & time:Utc at = now.cloneReadOnly();
        anydata|error issue = store:inTransactionValue(isolated function () returns CoinIssue|error =>
                self.beginTx(p, runId, at));
        return issue is error ? issue : issue.cloneWithType();
    }

    private isolated function beginTx(CoinPlan plan, string runId, time:Utc now) returns CoinIssue|error {
        CoinIssue? started = ();
        transaction {
            string? wallet = plan.walletAddress;
            if wallet is () {
                fail error("A transfer needs a wallet");
            }
            // A FAILED or skipped issue of this run is the same conversion tried again (attempts + 1, same reference);
            // a SENT, PENDING or UNKNOWN one is never overwritten (no row comes back).
            IssueRow|error row = self.db->queryRow(sql:queryConcat(`
                INSERT INTO scoring_coin_issue (run_id, employee_id, points_in, carry_in, coins, carry_out, block_points,
                    block_coins, wallet_address, reference, status, attempts, attempted_at, created_at, updated_at)
                VALUES (CAST(${runId} AS uuid), ${plan.employeeId}, ${plan.pointsIn}, ${plan.carryIn}, ${plan.coins},
                    ${plan.carryOut}, ${plan.blockPoints}, ${plan.blockCoins}, ${wallet}, ${newCoinReference()},
                    'PENDING', 1, CAST(${store:ts(now)} AS timestamptz), CAST(${store:ts(now)} AS timestamptz),
                    CAST(${store:ts(now)} AS timestamptz))
                ON CONFLICT (run_id, employee_id) DO UPDATE
                    SET points_in = EXCLUDED.points_in, carry_in = EXCLUDED.carry_in, coins = EXCLUDED.coins,
                        carry_out = EXCLUDED.carry_out, block_points = EXCLUDED.block_points,
                        block_coins = EXCLUDED.block_coins, wallet_address = EXCLUDED.wallet_address, status = 'PENDING',
                        attempts = scoring_coin_issue.attempts + 1, last_error_code = NULL, next_attempt_at = NULL,
                        attempted_at = EXCLUDED.attempted_at, updated_at = EXCLUDED.updated_at
                    WHERE scoring_coin_issue.status IN ('FAILED', 'SKIPPED_NO_WALLET')
                RETURNING `, issueColumns()));
            if row is error {
                fail store:isNoRows(row) ? error("The employee's issue in this run is not open to a retry") : row;
            }
            if plan.references.length() > 0 {
                sql:ExecutionResult tagged = check self.db->execute(sql:queryConcat(`
                    UPDATE scoring_points_ledger SET coin_reference = ${row.reference}
                    WHERE employee_id = ${plan.employeeId} AND status = 'HELD' AND coin_reference IS NULL
                      AND reference IN (`, sql:arrayFlattenQuery(plan.references), `)`));
                if tagged.affectedRowCount != plan.references.length() {
                    fail error("The ledger rows changed since the plan");
                }
            }
            started = check toIssue(row);
            check commit;
        }
        return <CoinIssue>started;
    }

    public isolated function skipNoWallet(CoinPlan plan, string runId, time:Utc now) returns error? {
        _ = check self.db->execute(`
            INSERT INTO scoring_coin_issue (run_id, employee_id, points_in, carry_in, coins, carry_out, block_points,
                block_coins, wallet_address, reference, status, attempts, created_at, updated_at)
            VALUES (CAST(${runId} AS uuid), ${plan.employeeId}, ${plan.pointsIn}, ${plan.carryIn}, ${plan.coins},
                ${plan.carryOut}, ${plan.blockPoints}, ${plan.blockCoins}, NULL, ${newCoinReference()},
                'SKIPPED_NO_WALLET', 0, CAST(${store:ts(now)} AS timestamptz), CAST(${store:ts(now)} AS timestamptz))
            ON CONFLICT (run_id, employee_id) DO UPDATE
                SET points_in = EXCLUDED.points_in, carry_in = EXCLUDED.carry_in, coins = EXCLUDED.coins,
                    carry_out = EXCLUDED.carry_out, block_points = EXCLUDED.block_points,
                    block_coins = EXCLUDED.block_coins, wallet_address = NULL, status = 'SKIPPED_NO_WALLET',
                    updated_at = EXCLUDED.updated_at
                WHERE scoring_coin_issue.status IN ('FAILED', 'SKIPPED_NO_WALLET')`);
    }

    public isolated function markSent(CoinIssue issue, string transferReference, time:Utc now) returns error? {
        final readonly & CoinIssue i = issue.cloneReadOnly();
        final readonly & time:Utc at = now.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.markSentTx(i, transferReference, at));
    }

    private isolated function markSentTx(CoinIssue issue, string transferReference, time:Utc now) returns error? {
        transaction {
            // Settlement columns only; the rows are final from here (V026 guard).
            _ = check self.db->execute(`
                UPDATE scoring_points_ledger
                   SET status = 'PAID', paid_at = CAST(${store:ts(now)} AS timestamptz),
                       status_changed_at = CAST(${store:ts(now)} AS timestamptz)
                 WHERE coin_reference = ${issue.reference} AND status = 'HELD'`);
            sql:ExecutionResult sent = check self.db->execute(`
                UPDATE scoring_coin_issue
                   SET status = 'SENT', transfer_reference = ${transferReference},
                       sent_at = CAST(${store:ts(now)} AS timestamptz), last_error_code = NULL, next_attempt_at = NULL,
                       updated_at = CAST(${store:ts(now)} AS timestamptz)
                 WHERE id = CAST(${issue.id} AS uuid) AND status IN ('PENDING', 'UNKNOWN')`);
            if sent.affectedRowCount != 1 {
                fail error("The issue is no longer open");
            }
            check store:writeAudit(self.db, store:auditOf(self.actor, "CoinsIssued", ISSUE_TABLE, issue.id,
                    {employeeId: issue.employeeId, coins: issue.coins, reference: issue.reference, transferReference}));
            check commit;
        }
    }

    public isolated function markFailed(CoinIssue issue, string errorCode, time:Utc nextAttemptAt, time:Utc now)
            returns error? {
        final readonly & CoinIssue i = issue.cloneReadOnly();
        final readonly & time:Utc next = nextAttemptAt.cloneReadOnly();
        final readonly & time:Utc at = now.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.markFailedTx(i, errorCode, next, at));
    }

    private isolated function markFailedTx(CoinIssue issue, string errorCode, time:Utc nextAttemptAt, time:Utc now)
            returns error? {
        transaction {
            // Nothing moved: the rows go back to the pool the next run takes from.
            _ = check self.db->execute(`
                UPDATE scoring_points_ledger SET coin_reference = NULL
                 WHERE coin_reference = ${issue.reference} AND status = 'HELD'`);
            sql:ExecutionResult failed = check self.db->execute(`
                UPDATE scoring_coin_issue
                   SET status = 'FAILED', last_error_code = ${errorCode},
                       next_attempt_at = CAST(${store:ts(nextAttemptAt)} AS timestamptz),
                       updated_at = CAST(${store:ts(now)} AS timestamptz)
                 WHERE id = CAST(${issue.id} AS uuid) AND status IN ('PENDING', 'UNKNOWN')`);
            if failed.affectedRowCount != 1 {
                fail error("The issue is no longer open");
            }
            check store:writeAudit(self.db, store:auditOf(self.actor, "CoinIssueFailed", ISSUE_TABLE, issue.id,
                    {employeeId: issue.employeeId, coins: issue.coins, reference: issue.reference, errorCode}));
            check commit;
        }
    }

    public isolated function markUnknown(CoinIssue issue, string errorCode, time:Utc now) returns error? {
        final readonly & CoinIssue i = issue.cloneReadOnly();
        final readonly & time:Utc at = now.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? => self.markUnknownTx(i, errorCode, at));
    }

    private isolated function markUnknownTx(CoinIssue issue, string errorCode, time:Utc now) returns error? {
        transaction {
            sql:ExecutionResult unknown = check self.db->execute(`
                UPDATE scoring_coin_issue
                   SET status = 'UNKNOWN', last_error_code = ${errorCode},
                       updated_at = CAST(${store:ts(now)} AS timestamptz)
                 WHERE id = CAST(${issue.id} AS uuid) AND status IN ('PENDING', 'UNKNOWN')`);
            if unknown.affectedRowCount != 1 {
                fail error("The issue is no longer open");
            }
            check store:writeAudit(self.db, store:auditOf(self.actor, "CoinIssueUnknown", ISSUE_TABLE, issue.id,
                    {employeeId: issue.employeeId, coins: issue.coins, reference: issue.reference, errorCode}));
            check commit;
        }
    }

    public isolated function finishRun(string runId, string status, string? stopReason, time:Utc now)
            returns CoinRunTotals|error {
        CoinRunTotals totals = check self.db->queryRow(`
            UPDATE scoring_coin_run r
               SET status = ${status}, stop_reason = ${stopReason}, finished_at = CAST(${store:ts(now)} AS timestamptz),
                   issues_sent = t.sent, coins_sent = t.coins, issues_failed = t.failed, issues_unknown = t.unknown,
                   issues_skipped = t.skipped
              FROM (SELECT (count(*) FILTER (WHERE status = 'SENT'))::int AS sent,
                           coalesce(sum(coins) FILTER (WHERE status = 'SENT'), 0)::int AS coins,
                           (count(*) FILTER (WHERE status = 'FAILED'))::int AS failed,
                           (count(*) FILTER (WHERE status IN ('PENDING', 'UNKNOWN')))::int AS unknown,
                           (count(*) FILTER (WHERE status = 'SKIPPED_NO_WALLET'))::int AS skipped
                      FROM scoring_coin_issue WHERE run_id = CAST(${runId} AS uuid)) t
             WHERE r.id = CAST(${runId} AS uuid)
            RETURNING r.issues_sent AS "issuesSent", r.coins_sent::int AS "coinsSent", r.issues_failed AS "issuesFailed",
                      r.issues_unknown AS "issuesUnknown", r.issues_skipped AS "issuesSkipped"`);
        return totals;
    }

    isolated function issues(sql:ParameterizedQuery q) returns CoinIssue[]|error {
        stream<IssueRow, error?> rows = self.db->query(q);
        return from IssueRow r in rows select check toIssue(r);
    }
}

# `CoinWalletRepository` over PostgreSQL.
public isolated class PgCoinWalletRepository {
    *CoinWalletRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Client
    # + actor - Who the writes are for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function walletOf(types:EmployeeId employeeId) returns CoinWallet|error? {
        WalletRow|error row = self.db->queryRow(`
            SELECT employee_id, wallet_address, captured_at FROM scoring_coin_wallet WHERE employee_id = ${employeeId}`);
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        return {employeeId: row.employee_id, walletAddress: row.wallet_address, capturedAt: row.captured_at};
    }

    public isolated function saveWallet(types:EmployeeId employeeId, string walletAddress, time:Utc now)
            returns CoinWallet|error {
        final readonly & time:Utc at = now.cloneReadOnly();
        anydata|error saved = store:inTransactionValue(isolated function () returns CoinWallet|error =>
                self.saveWalletTx(employeeId, walletAddress, at));
        return saved is error ? saved : saved.cloneWithType();
    }

    private isolated function saveWalletTx(types:EmployeeId employeeId, string walletAddress, time:Utc now)
            returns CoinWallet|error {
        CoinWallet? stored = ();
        transaction {
            WalletRow row = check self.db->queryRow(`
                INSERT INTO scoring_coin_wallet (employee_id, wallet_address, captured_at, updated_at)
                VALUES (${employeeId}, ${walletAddress}, CAST(${store:ts(now)} AS timestamptz),
                        CAST(${store:ts(now)} AS timestamptz))
                ON CONFLICT (employee_id) DO UPDATE
                    SET wallet_address = EXCLUDED.wallet_address, updated_at = EXCLUDED.updated_at,
                        captured_at = CASE WHEN scoring_coin_wallet.wallet_address = EXCLUDED.wallet_address
                                           THEN scoring_coin_wallet.captured_at ELSE EXCLUDED.captured_at END
                RETURNING employee_id, wallet_address, captured_at`);
            // The audit keeps the masked address only.
            check store:writeAudit(self.db, store:auditOf(self.actor, "CoinWalletCaptured", "scoring_coin_wallet",
                    employeeId, {walletAddress: maskWallet(walletAddress)}));
            stored = {employeeId: row.employee_id, walletAddress: row.wallet_address, capturedAt: row.captured_at};
            check commit;
        }
        return <CoinWallet>stored;
    }
}

# The issue columns every read selects, in `IssueRow` order.
#
# + return - The select list
isolated function issueColumns() returns sql:ParameterizedQuery =>
    `id::text AS id, run_id::text AS run_id, employee_id, points_in, carry_in, coins, carry_out, wallet_address,
     reference, transfer_reference, status, attempts, last_error_code, next_attempt_at, attempted_at`;

isolated function toIssue(IssueRow r) returns CoinIssue|error => {
    id: r.id,
    runId: r.run_id,
    employeeId: r.employee_id,
    pointsIn: r.points_in,
    carryIn: r.carry_in,
    coins: r.coins,
    carryOut: r.carry_out,
    walletAddress: r.wallet_address,
    reference: r.reference,
    transferReference: r.transfer_reference,
    status: check r.status.ensureType(),
    attempts: r.attempts,
    lastErrorCode: r.last_error_code,
    nextAttemptAt: r.next_attempt_at,
    attemptedAt: r.attempted_at
};
