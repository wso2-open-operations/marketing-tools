# CLAUDE.md — amplify-scheduler

## Overview
Amplify Scheduler: the pinned `akorn/scheduler` image (github.com/akornatskyy/scheduler, MIT, v1.7.8) run as UID 10014. It calls `amplify-jobs POST /runs` and `POST /maintenance/partitions` on the schedules in `config.app_setting`. Replaces amplify-cron and the Choreo Scheduled Task (ADR-026). No code here, only the Dockerfile and descriptors.

## Rules
- **No API auth upstream.** Project visibility / internal network only; never published, never on the host in Compose, never behind the API proxy. Only amplify-api calls its API. The pinned image can't authenticate its callers, so anyone who can reach it can read and change jobs. A network policy was dropped for phase 1 (ADR-039, amended 2026-11-01); instead the jobs it fires into amplify-jobs carry the scoped scheduler key in `X-Amplify-Internal-Key`, which therefore also sits in the scheduler's own database but opens only `POST /runs` and `POST /maintenance/partitions`.
- Jobs are owned by amplify-api (`scheduler_sync.bal`): stable ids `amplify-run`, `amplify-maintenance-partitions` in collection `amplify`. A manual edit in the scheduler UI is overwritten by the next reconcile (startup or `POST /admin/scheduler/sync`).
- Own Postgres database and user via `DSN`; it auto-migrates its own tables. Never point it at Amplify's database or schemas.
- Version bump: tag + digest together in `Dockerfile`, `scripts/it-scheduler.sh` and `scripts/it-scheduler-history.sh`; run both ITs.
- `job_history` retention: `history-retention.sql` (30-day self-trimming trigger on its own DB). Compose applies it
  with the `scheduler-retention` one-shot; Choreo once from the scheduler DB console (operations runbook §7).
  Rerun it after a version bump.

## Research
`docs/research/2026-10-16-akornatskyy-scheduler.md`.
