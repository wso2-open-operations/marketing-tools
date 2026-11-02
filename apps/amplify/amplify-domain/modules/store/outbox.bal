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

// Outbox writer: every domain event becomes a `messaging.outbox` row in the producer's transaction
// (phase1-data-model › Domain events). Call only inside a `transaction` block, with the same client as
// the aggregate write, so aggregate + outbox + audit commit together.

import amplify_common.events;

import ballerinax/postgresql;

# Writes events to the outbox. A repeated idempotency key is skipped (`ON CONFLICT DO NOTHING`), so a
# retried producer never queues an event twice.
#
# + db - Client, inside the caller's transaction
# + outbox - Events
# + correlationId - Request or run correlation id
# + return - Number of rows written, or an error
public isolated transactional function writeOutbox(postgresql:Client db, events:OutboxEvent[] outbox,
        string? correlationId = ()) returns int|error {
    int written = 0;
    foreach events:OutboxEvent event in outbox {
        string payload = event.payload.toJsonString();
        var result = check db->execute(`
            INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload, idempotency_key,
                                          correlation_id)
            VALUES (${event.aggregateType}, ${event.aggregateId}, ${event.eventType}, CAST(${payload} AS jsonb),
                    ${event.idempotencyKey}, ${correlationId})
            ON CONFLICT (idempotency_key) DO NOTHING`);
        written += result.affectedRowCount ?: 0;
    }
    return written;
}

// ---- Consumer side (amplify-jobs, M6) -------------------------------------------------------------

# One claimed outbox row.
public type OutboxRow record {|
    # Outbox id (queue order)
    int id;
    # `aggregate_type`
    string aggregateType;
    # `aggregate_id`
    string aggregateId;
    # `event_type`
    string eventType;
    # Event payload
    json payload;
    # `idempotency_key`
    string idempotencyKey;
    # Attempts including this one
    int attempts;
    # Correlation id written by the producer
    string? correlationId;
|};

type OutboxDbRow record {|
    int id;
    string aggregate_type;
    string aggregate_id;
    string event_type;
    string payload;
    string idempotency_key;
    int attempts;
    string? correlation_id;
|};

# Claims up to `batchSize` due `PENDING` rows for one run: `FOR UPDATE SKIP LOCKED`, so two runs never
# claim the same row; each claimed row is `IN_PROGRESS`, `locked_by` = run, `locked_until` = now + lease,
# and its `attempts` goes up by one.
#
# + db - Client (`amplify_jobs`)
# + runId - Run id
# + batchSize - Most rows
# + leaseSeconds - Lock lease; a row still locked after it is released by the next run
# + return - Claimed rows in queue order, or an error
public isolated function claimOutbox(postgresql:Client db, string runId, int batchSize, int leaseSeconds)
        returns OutboxRow[]|error {
    stream<OutboxDbRow, error?> rows = db->query(`
        UPDATE messaging.outbox o
        SET status = 'IN_PROGRESS', locked_by = ${runId},
            locked_until = now() + make_interval(secs => ${leaseSeconds}), attempts = o.attempts + 1
        WHERE o.id IN (SELECT id FROM messaging.outbox
                       WHERE status = 'PENDING' AND next_attempt_at <= now()
                       ORDER BY id LIMIT ${batchSize}
                       FOR UPDATE SKIP LOCKED)
        RETURNING o.id, o.aggregate_type, o.aggregate_id, o.event_type, o.payload::text AS payload, o.idempotency_key,
                  o.attempts, o.correlation_id`);
    OutboxRow[] claimed = check from OutboxDbRow r in rows
        select {
            id: r.id,
            aggregateType: r.aggregate_type,
            aggregateId: r.aggregate_id,
            eventType: r.event_type,
            payload: check r.payload.fromJsonString(),
            idempotencyKey: r.idempotency_key,
            attempts: r.attempts,
            correlationId: r.correlation_id
        };
    return claimed.sort("ascending", r => r.id);
}

# Marks a claimed row `DONE`. Only the run that holds the lock can finish it.
#
# + db - Client
# + id - Outbox id
# + runId - Run holding the lock
# + return - An error
public isolated function completeOutbox(postgresql:Client db, int id, string runId) returns error? {
    _ = check db->execute(`
        UPDATE messaging.outbox
        SET status = 'DONE', processed_at = now(), locked_by = NULL, locked_until = NULL, last_error = NULL
        WHERE id = ${id} AND locked_by = ${runId}`);
}

# Puts a claimed row back to `PENDING`, due after `delaySeconds`.
#
# + db - Client
# + id - Outbox id
# + runId - Run holding the lock
# + delaySeconds - Wait before the next attempt
# + lastError - Safe error text (never tokens, URLs or commentary)
# + countAttempt - False for a deferral (kill switch, rate ceiling, not yet open): the claim's attempt is
# given back
# + return - An error
public isolated function retryOutbox(postgresql:Client db, int id, string runId, decimal delaySeconds,
        string? lastError, boolean countAttempt = true) returns error? {
    int giveBack = countAttempt ? 0 : 1;
    _ = check db->execute(`
        UPDATE messaging.outbox
        SET status = 'PENDING', next_attempt_at = now() + make_interval(secs => ${delaySeconds}),
            attempts = greatest(attempts - ${giveBack}, 0), locked_by = NULL, locked_until = NULL,
            last_error = ${truncate(lastError)}
        WHERE id = ${id} AND locked_by = ${runId}`);
}

# Marks a claimed row `FAILED` (retries ran out, or a permanent error). The admin retry re-queues it.
#
# + db - Client
# + id - Outbox id
# + runId - Run holding the lock
# + lastError - Safe error text
# + return - An error
public isolated function failOutbox(postgresql:Client db, int id, string runId, string lastError) returns error? {
    _ = check db->execute(`
        UPDATE messaging.outbox
        SET status = 'FAILED', locked_by = NULL, locked_until = NULL, last_error = ${truncate(lastError)}
        WHERE id = ${id} AND locked_by = ${runId}`);
}

# Releases rows whose lock lease ran out (a crashed or killed run) back to `PENDING`, due now. The
# attempt the dead run counted stays counted, so a row that keeps killing runs still reaches `FAILED`.
#
# + db - Client
# + return - Rows released, or an error
public isolated function releaseStaleLocks(postgresql:Client db) returns int|error {
    var result = check db->execute(`
        UPDATE messaging.outbox
        SET status = 'PENDING', locked_by = NULL, locked_until = NULL, next_attempt_at = now()
        WHERE status = 'IN_PROGRESS' AND locked_until < now()`);
    return result.affectedRowCount ?: 0;
}

# Deletes expired `Idempotency-Key` records (ADR-024 item 3, 24 h lifetime).
#
# + db - Client
# + return - Rows deleted, or an error
public isolated function purgeExpiredIdempotencyKeys(postgresql:Client db) returns int|error {
    var result = check db->execute(`DELETE FROM messaging.idempotency_key WHERE expires_at < now()`);
    return result.affectedRowCount ?: 0;
}

isolated function truncate(string? text) returns string? =>
    text is () ? () : text.length() > 1000 ? text.substring(0, 1000) : text;

# What is waiting in the outbox.
public type OutboxBacklog record {|
    # Rows waiting, including those deferred because a dependency is down or unconfigured
    int pending;
    # Rows a run is handling right now
    int inProgress;
    # Rows that used every attempt and need an operator
    int failed;
    # Age in seconds of the oldest pending row, `()` when none is pending
    int? oldestPendingSeconds;
|};

# Counts what is waiting in the outbox. Deferred rows are pending with a later `next_attempt_at`, so the age is
# measured from `created_at`: a row that has been waiting for hours is stuck, however often it is retried.
#
# + db - Client
# + return - The backlog, or an error
public isolated function outboxBacklog(postgresql:Client db) returns OutboxBacklog|error {
    record {|int pending; int in_progress; int failed; int? oldest;|} row = check db->queryRow(`
        SELECT count(*) FILTER (WHERE status = 'PENDING')::int AS pending,
               count(*) FILTER (WHERE status = 'IN_PROGRESS')::int AS in_progress,
               count(*) FILTER (WHERE status = 'FAILED')::int AS failed,
               (EXTRACT(EPOCH FROM (now() - min(created_at) FILTER (WHERE status = 'PENDING'))))::bigint::int AS oldest
        FROM messaging.outbox WHERE status <> 'DONE'`);
    return {pending: row.pending, inProgress: row.in_progress, failed: row.failed, oldestPendingSeconds: row.oldest};
}

# How many days past today (UTC) have a `connection.provider_token` partition. The partitions are named
# `provider_token_pYYYYMMDD`; the newest one decides the runway.
#
# + db - Client
# + return - Days ahead (0 when the newest partition is today, negative when it is behind), `()` when there is none, or an error
public isolated function tokenPartitionDaysAhead(postgresql:Client db) returns int?|error {
    record {|int? ahead;|} row = check db->queryRow(`
        SELECT (max(to_date(substr(c.relname, 17), 'YYYYMMDD')) - (now() AT TIME ZONE 'UTC')::date)::int AS ahead
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'connection.provider_token'::regclass AND c.relname ~ '^provider_token_p[0-9]{8}$'`);
    return row.ahead;
}
