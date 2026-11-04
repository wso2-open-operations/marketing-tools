# amplify_domain.store

Shared plumbing for every context: the database client, transaction gate, outbox and audit writers, idempotency keys, app settings, SQL error mapping and partition upkeep. It owns no business rules. Tables: `messaging_outbox`, `messaging_idempotency_key`, `audit_log`, `config_app_setting`.

## Client and connection

File: `modules/store/store.bal`.

- `DbConfig`: `host`, `port`, `database`, `user`, `password`, `schema` (first on the `search_path`, then `public`), `idleInTransactionTimeoutMs`, `sslMode` (default `VERIFY_FULL`; local Docker passes `DISABLE`), `sslRootCert`, pool and timeout settings.
- `newClient(config)`, `databaseOf`, `secureSocketOf`, `verifiesServer`, `tlsWarning`, `isLocalHost`, `ping`, `probe`, `pageWindow`.
- Recognition lock: `lockRecognition` (polls `pg_try_advisory_xact_lock`, gives up after `RECOGNITION_LOCK_WAIT_SECONDS`), `RECOGNITION_LOCK_KEY` (4242101), `RECOGNITION_SQL_LOCK_KEY` (1634561133), `RECOGNITION_IDLE_TIMEOUT_MS`. Take the app key before the SQL key.

## Transaction gate

File: `modules/store/tx_gate.bal`. `inTransaction` and `inTransactionValue` run one transaction at a time per process (R-13). `gatedTransactions()` counts them (tests).

## Outbox

File: `modules/store/outbox.bal`.

- Write: `writeOutbox(db, outbox, ...)` inserts `events:OutboxEvent` rows in the caller's transaction.
- Dispatch (used by `amplify-jobs`): `claimOutbox`, `completeOutbox`, `retryOutbox`, `failOutbox`, `releaseStaleLocks`, `purgeExpiredIdempotencyKeys`, `outboxBacklog`, `tokenPartitionDaysAhead`. Types `OutboxRow`, `OutboxBacklog`.

## Audit

File: `modules/store/audit.bal`. `Actor` (`actorId`, `roles`), `SYSTEM` (the jobs actor), `AuditEntry`, `AuditOutcome` (`SUCCESS`, `DENIED`, `FAILED`), `auditOf`, `writeAudit`, `arrayLiteral`. Update rows carry `before` and `after`. Never put tokens or commentary in an audit row.

## Settings and idempotency

File: `modules/store/settings.bal`. `readSettings`, `updateSettings` (`config_app_setting`), and the `Idempotency-Key` helpers `claimIdempotencyKey`, `completeIdempotencyKey`, `releaseIdempotencyKey` (`IdempotencyRecord`).

## Errors and maintenance

- `modules/store/errors.bal`: `isUniqueViolation`, `isNoRows`, `versionConflict`, `ts`, `UNIQUE_VIOLATION`, `CHECK_VIOLATION`.
- `modules/store/maintenance.bal`: `runPartitionMaintenance(db)` calls the SQL function `messaging_run_partition_maintenance` (`amplify_jobs` only) and returns a `MaintenanceResult` (partitions created and dropped, outbox rows purged, OAuth states swept).

## Config

No `configurable` values. Components fill `DbConfig` from their own `configurable` values.

## Depends on

`amplify_common.events`, `amplify_common.types`, `ballerinax/postgresql`.

## Does not do

- No context rules and no context tables.
- No migrations (`amplify-database` owns the schema).
- No dispatch scheduling (`amplify-jobs` runs the outbox loop).

## Tests

`modules/store/tests/store_test.bal`. The package `tests/lock_order_test.bal` checks the recognition lock order.
