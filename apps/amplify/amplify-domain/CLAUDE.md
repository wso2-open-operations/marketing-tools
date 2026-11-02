# CLAUDE.md — amplify-domain

## Overview
Shared library `wso2/amplify_domain` (ADR-021, resolves B19): the bounded contexts that both `amplify-api` and `amplify-jobs` run. Not deployed. The version and the `amplify_common` version it needs live in `Ballerina.toml` — that file is the source of truth; bump `version` there and the consumers' `[[dependency]]` together when the API changes.

## Commands
Publish `amplify_common` first, then `bal pack && bal push --repository=local` here, then rebuild consumers. `bal test` runs unit tests; the root-module `integration` group needs `AMPLIFY_IT=true` and a migrated Postgres 18 (`docs/migrations/README.md`).

## Architecture
One module per context (`identity`, `campaign`, `connection`, `sharing`, `external_sharing`, `scoring`, `recognition`, `announcements`, plus the read-only `reporting` for the dashboards, ADR-036): `types.bal` (aggregate, derived-status enum, repository port), `service.bal` (pure rules + use cases), `events.bal` (outbox builders), `repository.bal` (PostgreSQL, own schema only). `store`: `newClient`, `writeOutbox`, `writeAudit`, `Actor`, error mapping, `ts()`, `runPartitionMaintenance`.

## DB connections
Repositories take the shared `postgresql:Client` and a `store:Actor` (api: the caller per request; jobs: `store:SYSTEM`). Each write commits aggregate + outbox + audit in one transaction, run through `store:inTransaction` (`modules/store/tx_gate.bal`, R-13: one transaction at a time per process on 2201.13.x; pass `cloneReadOnly()` copies into the closure, and use `cloneWithType` where a `...Tx` body needs a mutable copy, since `clone()` of a read-only value stays read-only). A connect/reconnect inserts the sealed token in the connection's transaction (`ConnectionChange.tokenToInsert`). Key rotation: `connection:resealToken` / `resealStaleTokens`. `PgLedgerRepository.append` also calls `recognition.apply_ledger_entry` in that transaction (B12), after `store:lockRecognition` (every re-rank, and `recognition:rebuild`, takes that lock first). Lock order: app key 4242101 (`lockRecognition`, 2 s poll inside the gate) before the SQL key 1634561133 (V012 functions); `tests/lock_order_test.bal` guards it. Update audit rows carry `before` and `after` (PostgreSQL 18 `RETURNING old.*`). `DbConfig.sslMode` defaults to `VERIFY_FULL` with `sslRootCert`; local Docker passes `DISABLE`.

## Key patterns
Port methods are `public` so consumers in other packages can call them. In-memory test repositories live under `modules/<m>/tests/`. Never audit or log tokens or commentary.
