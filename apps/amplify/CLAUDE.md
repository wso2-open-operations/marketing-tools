# CLAUDE.md — Amplify backend (marketing-tools `apps/amplify`)

## Overview
Ballerina backend for WSO2 Amplify phase 1. Three Ballerina deployables, the scheduler image and two shared libraries in this folder. Lives in the marketing-tools repo at `apps/amplify` (ADR-033). UI lives in One WSO2, `webapp/src/features/amplify` (workspace submodule `projects/one-wso2`); change it there, not from here.

## Commands
- Publish shared libs first, in order: `cd amplify-common && bal pack && bal push --repository=local`, then the same in `amplify-domain`
- Per component: `bal build`, `bal test` (run inside `<component>`)
- Images: one Docker context per component (ADR-027): api `-f amplify-api/Dockerfile .`, jobs `-f amplify-jobs/Dockerfile ..` (context `apps`, filtered by `apps/.dockerignore`), database/scheduler their own folder. Shared packages are packed inside the build stage (clean checkout)
- Local stack: `make up`, `make e2e`, `make seed`, `make down` (removes volumes). Only amplify-api (:9090), the mock OAuth page (:19091) and people-stub (:19092, local One WSO2 photos) reach the host
- Checks: `make check` = `scripts/check-descriptors.sh` + `scripts/check-logs-pii.sh` + `scripts/check-transaction-gate.sh` (R-13)
- Descriptors: `scripts/check-descriptors.sh` (Choreo `.choreo/component.yaml` vs `workload.yaml` vs Dockerfile vs compose). api's descriptor is `./.choreo/`, jobs' is `../.choreo/component.yaml` (`apps/.choreo/`, the Docker context is `apps`)

## Architecture
- `amplify-api`: published API, fronted by the Choreo API proxy at the cell edge (ADR-004). Only the proxy is published; the backend has Project visibility.
- `amplify-jobs`: HTTP-triggered worker, no internal timer (ADR-003).
- `amplify-scheduler`: pinned `akorn/scheduler` image (ADR-026, replaces amplify-cron). Calls `amplify-jobs POST /runs` and `/maintenance/partitions`; amplify-api pushes the schedules from `config.app_setting`. Its API has no auth: internal only, own Postgres database/user. Scheduler IT: `scripts/it-scheduler.sh`.
- `amplify-database`: Amplify DB Migrate (Manual Task / Compose one-shot), forward-only `V###__name.sql`.
- `amplify-common`: shared types, events, crypto and adapters (ADR-020).
- `amplify-domain`: bounded contexts (domain + repository ports + PostgreSQL repositories) and `store` (client, outbox/audit writers), used by api and jobs (ADR-021).

## DB connections
PostgreSQL 18, one schema per bounded context, one DB user per component (`amplify_migrate`, `amplify_api`, `amplify_jobs`, `amplify_readonly`). A context reads and writes only its own schema; no cross-context FKs (ADR-005). Exception by design: the ledger append applies the row to `recognition` in the same transaction (B12). Details: `architecture/solution/Phase 1/phase1-data-model.md`. Integration tests against Postgres 18: `docs/migrations/README.md`.

## Key patterns
- Apache-2.0 WSO2 header on every `.bal`, `.sql`, `Dockerfile`.
- `@display {label, id: "amplify/<component>"}` on services and `main()`.
- Config only through `configurable` + `Config.toml` / `BAL_CONFIG_VAR_*`; never commit `Config.toml` or secrets.
- `sql:ParameterizedQuery` only (the migrate runner executing trusted script files is the one exception). Bind times as `CAST(${store:ts(t)} AS timestamptz)` and uuids as `CAST(${id} AS uuid)`; use `call` for DDL (`execute` makes the driver append `RETURNING`). Log errors with `log:printError(msg, err)`; never return raw errors to callers.
- Commit `Dependencies.toml`; never commit `target/`.
- Every `transaction {}` block runs through `store:inTransaction` / `inTransactionValue` (one process-wide gate: Ballerina 2201.13.x races concurrent transactions, ballerina-lang #44737, `docs/reviews/2026-10-17-r13-transaction-race.md`). Put the block in a non-public `...Tx` function and call it only on a line that calls the gate; never `retry transaction`. Remove the gate after upgrading to 2201.14.1+.

## Cell rules
- Ingress only through the API proxy; `amplify-jobs`, the scheduler and the DBs are never published.
- Egress only to the declared endpoints, set per environment as config or secrets: LinkedIn (API and OAuth base URLs), Novera (its notifications URL and a client-credentials application, secret as a secret) and Google Chat (webhook URL as a secret; in prod it points at the WSO2 Club group chat space, in dev at a test space), people-app directory for team rosters.
- Containers run as `USER 10014`.
