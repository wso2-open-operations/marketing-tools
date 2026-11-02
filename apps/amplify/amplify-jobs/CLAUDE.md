# CLAUDE.md — amplify-jobs

## Authentication
Every endpoint except `GET /health` and `GET /ready` needs the header `X-Amplify-Internal-Key`. Two keys, each a secret of at least 32 characters, different values; the worker refuses to start without both: `internalApiKey` opens every route (amplify-api, Save & Share Now); `schedulerApiKey` (put on the scheduler's jobs by amplify-api) opens only `POST /runs` and `POST /maintenance/partitions`, 403 elsewhere. ADR-039.

## Overview
Worker for the Run (sharing, announcements, scoring) and maintenance. No internal timer (ADR-003). Project visibility only.

## Commands
`bal build` · `bal test` (needs `amplify_common` then `amplify_domain` in the local repo). Port: configurable `port` (default 9091).

## Architecture
`service.bal`: `GET /health`, `POST /runs` (synchronous run, returns the run log; 202 `SKIPPED` while another run holds the lock), `POST /maintenance/partitions` (`messaging.run_partition_maintenance()` + expired `Idempotency-Key` purge + token key rotation, `token_rotation` in the report), `POST /maintenance/rebuild-recognition`. `run.bal`: the Run (in-process flag + session advisory lock, stale-lock release, sweep, claim batches `FOR UPDATE SKIP LOCKED`, settle DONE/RETRY/DEFER/FAIL, run log). `handlers.bal`: `CampaignRegistered` → Novera notification (primary, `AMPLIFY_ON_NOVERA`) and/or Chat card (`AMPLIFY_ON_WEBHOOK`; best effort when Novera is on), `RepostRequested` → LinkedIn, `EngagementRecorded` → points; approve/amplified are no-ops (scored in api, ADR-024). `outcome.bal`: outcomes + backoff with equal jitter. `ports.bal`: `RunStore`/`Store`/`RunLock`/`ChatPort` ports and their Pg/webhook implementations (tests use in-memory fakes, `tests/fakes.bal`). `outbound.bal` + `config.bal`: LinkedIn adapter, Chat webhook (1 rps throttle), token cipher, run tuning; breakers and pools from `amplify_common.resilience`. `database.bal`: lazy `amplify_jobs` client plus a single-connection lock client (`dbHost = ""` → 503). Semantics: ADR-025.

## DB connections
DB user `amplify_jobs`; calls the `SECURITY DEFINER` partition functions owned by `amplify_migrate` (V009); configurables `dbHost`, `dbPort`, `dbName`, `dbUser`, `dbPassword` (secret), `dbSslMode` (default `VERIFY_FULL`), `dbSslRootCert`, `leaderboardTopN`. A token on an old key is re-sealed on use (best effort, never fails the share).

## Key patterns
`POST /runs` must be idempotent and safe to call concurrently: handlers re-read the aggregate before any external call. No HTTP-level retry on LinkedIn posts or the Chat webhook (ADR-025); the outbox retries. Never log tokens, commentary or the webhook URL. Integration tests: `AMPLIFY_IT=true bal test --groups integration` with `mock_linkedin` (docs/migrations/README.md). Caller auth between components lands in M9/M10.
