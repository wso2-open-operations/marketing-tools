# CLAUDE.md — amplify-jobs

## Authentication
Every endpoint except `GET /health` and `GET /ready` needs the header `X-Amplify-Internal-Key`. Two keys, each a secret of at least 32 characters, different values; the worker refuses to start without both: `internalApiKey` opens every route (amplify-api, Save & Share Now); `schedulerApiKey` (put on the scheduler's jobs by amplify-api) opens only `POST /runs` and `POST /maintenance/partitions`, 403 elsewhere. ADR-039.

## Overview
Worker for the Run (sharing, announcements, scoring) and maintenance. No internal timer (ADR-003). Project visibility only.

## Commands
`bal build` · `bal test` (needs `amplify_common` then `amplify_domain` in the local repo). Port: configurable `port` (default 9091).

## Architecture
`service.bal`: `GET /health`, `POST /runs` (synchronous run, returns the run log; 202 `SKIPPED` while another run holds the lock), `POST /maintenance/partitions` (`messaging.run_partition_maintenance()` + expired `Idempotency-Key` purge + token key rotation, `token_rotation` in the report), `POST /maintenance/rebuild-recognition`. `run.bal`: the Run (in-process flag + session advisory lock, stale-lock release, sweep, claim batches `FOR UPDATE SKIP LOCKED`, settle DONE/RETRY/DEFER/FAIL, run log). `handlers.bal`: `CampaignRegistered` → Novera notification (the only announce channel, ADR-047; button URL from `noveraButtonUrl`, a template with `{campaignId}`, no default, empty defers; `attempted_at` saved before the call, so an ambiguous outcome or a row already attempted fails "Delivery unknown:" instead of sending again; only the admin retry resends), `RepostRequested` → LinkedIn, `EngagementRecorded` → points; approve/amplified are no-ops (scored in api, ADR-024). `outcome.bal`: outcomes + backoff with equal jitter. `ports.bal`: `RunStore`/`Store`/`RunLock` ports and their Pg implementations (tests use in-memory fakes, `tests/fakes.bal`). `novera.bal`: `NoveraPort` and `NoveraClient` (client-credentials token, built on first call; `notify` returns Novera's broadcast id when it sends one, `stats` reads its seen count). Seen counts (V023, off until `noveraSeenStatsEnabled`): each card carries `reference` = the post id, the sent announcement keeps the id, and every run ends by copying the counts of recent broadcasts (`refreshNoveraStats` in `run.bal`, oldest first, within the run's time budget; a count Novera hasn't checked yet, `lastCheckedAt` null, is not stored; never fails the run). `outbound.bal` + `config.bal`: LinkedIn adapter, Novera client, token cipher, run tuning; breakers and pools from `amplify_common.resilience`. `database.bal`: lazy `amplify_jobs` client plus a single-connection lock client (`dbHost = ""` → 503). Semantics: ADR-025.

## DB connections
DB: the one Amplify login user, no roles (ADR-043); calls the maintenance functions in its own schema (V009); configurables `dbHost`, `dbPort`, `dbName`, `dbUser`, `dbPassword` (secret), `dbSslMode` (default `VERIFY_FULL`), `dbSslRootCert`, `leaderboardTopN`. A token on an old key is re-sealed on use (best effort, never fails the share).

## Key patterns
`POST /runs` must be idempotent and safe to call concurrently: handlers re-read the aggregate before any external call. No HTTP-level retry on LinkedIn posts or Novera notifications (ADR-025); the outbox retries, and for Novera only when the failure proves nothing was delivered (ADR-047 outcome table). Never log tokens, commentary or the Novera client secret. Integration tests: `AMPLIFY_IT=true bal test --groups integration` with `mock_linkedin` (docs/migrations/README.md). Caller auth between components lands in M9/M10.
