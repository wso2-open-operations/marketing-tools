# amplify-scheduler

The pinned `akorn/scheduler` image (v1.7.8, github.com/akornatskyy/scheduler, MIT) that triggers Amplify's background work (ADR-026). It has no code of its own: this folder holds the Dockerfile, the deploy descriptors and one SQL file. See [CLAUDE.md](CLAUDE.md) for the rules.

## What it is and how it is triggered

The image runs as UID 10014 and listens on port 8080 (`Dockerfile`, `workload.yaml`, `.choreo/component.yaml`). It keeps its jobs and their history in its own Postgres database, reached through the `DSN` secret, and creates its own tables. It replaces amplify-cron and the Choreo Scheduled Task.

It starts no work on its own. amplify-api owns the jobs (`amplify-api/scheduler_sync.bal`) and pushes them into the scheduler collection `amplify`:

- at start-up,
- after an admin saves a schedule setting,
- on `POST /admin/scheduler/sync` in amplify-api.

The schedules come from `config_app_setting` (seeded by `amplify-database/seed/S004__scheduler_settings.sql`). A manual edit in the scheduler UI is overwritten by the next sync, so change the setting instead.

## Jobs

| Job id | Name | Schedule (default) | Calls | Retry | Deadline |
| --- | --- | --- | --- | --- | --- |
| `amplify-run` | Amplify Run | `@every 5m` (`run.schedule`, minimum 60 s; `run.enabled` switches it off) | `amplify-jobs POST /runs` | 1 retry, 30 s apart | 300 s (`runDeadlineSeconds`) |
| `amplify-maintenance-partitions` | Amplify partition maintenance | `0 2 * * *`, daily 02:00 UTC (`maintenance.schedule`) | `amplify-jobs POST /maintenance/partitions` | 2 retries, 60 s apart | 180 s (`maintenanceDeadlineSeconds`) |

Both jobs send the scheduler key in `X-Amplify-Internal-Key`. That key opens only these two routes on amplify-jobs (ADR-039).

### amplify-run

The main worker pass. Each call does one synchronous Run: it releases stale locks, claims a batch of outbox events (`FOR UPDATE SKIP LOCKED`) and settles each one as done, retry, defer or failed. It returns the run log. The events handled:

- `CampaignRegistered` announces the campaign through Novera (ADR-047).
- `RepostRequested` makes the LinkedIn repost.
- `EngagementRecorded` awards points.

Only one Run holds the lock at a time. A call made while one is going returns `202 SKIPPED`, which the scheduler counts as success. The deadline must stay above amplify-jobs `runMaxSeconds` (240), or the scheduler cancels a healthy run. Set `run.enabled` to `false` to stop sharing, announcements and scoring.

### amplify-maintenance-partitions

The nightly housekeeping call. It:

- keeps the daily token partitions and the audit partitions rolling forward, and drops expired ones,
- purges finished outbox rows, expired OAuth states and expired `Idempotency-Key` records,
- re-seals tokens written under an older key,
- runs the leaver sweep (mode `OFF` by default, ADR-040).

The response carries a report, including `token_rotation` and `leaver_sweep`. A missed night is safe: the next call picks up what is left. Details: `amplify-jobs/README.md`.

## Settings

| Setting | Where | What |
| --- | --- | --- |
| `DSN` | Scheduler container (secret) | Postgres connection string for the scheduler's own database and user. Never Amplify's database |
| `run.schedule`, `run.enabled`, `maintenance.schedule` | `config_app_setting` | Schedules and the run switch, read by amplify-api |
| `schedulerUrl`, `schedulerJobsUrl`, `schedulerCollection`, `runDeadlineSeconds`, `maintenanceDeadlineSeconds` | amplify-api | How amplify-api reaches the scheduler and what it tells it |
| `AMPLIFY_SCHEDULER_API_KEY` | Compose (`local/.env`) | The scoped key the jobs carry. In Choreo it is `schedulerApiKey` on amplify-jobs and amplify-api |

## Files

| File | What |
| --- | --- |
| `Dockerfile` | The pinned image (tag and digest), UID 10014, port 8080 |
| `workload.yaml` | OpenChoreo descriptor: HTTP endpoint on 8080, project visibility, `DSN` secret |
| `.choreo/component.yaml` | Choreo descriptor for the same |
| `history-retention.sql` | A trigger on the scheduler's own database that trims `job_history` to 30 days after every insert |
| `.dockerignore` | Build context filter |
| `CLAUDE.md` | Rules for agents and maintainers |

## Run and test

- Local: `make up` from `apps/amplify` starts `scheduler`, `scheduler-db` and the `scheduler-retention` one-shot (`compose.yaml`). The scheduler has no host port: `docker compose exec amplify-api wget -qO- http://scheduler:8080/jobs`.
- Test: `scripts/it-scheduler.sh` runs the pinned image on a throwaway network and checks that amplify-api creates both jobs, that a schedule change updates a job, and that the scheduler fires `POST /runs`. `scripts/it-scheduler-history.sh` checks the retention trigger. `make test-all` runs both.
- Version bump: change tag and digest together in `Dockerfile`, `scripts/it-scheduler.sh` and `scripts/it-scheduler-history.sh`, run both tests, redeploy, then rerun `history-retention.sql` (operations runbook section 7).
- Choreo: run `history-retention.sql` once from the scheduler database console, after the scheduler's first start (it creates `job_history`).
- Research notes: `docs/research/2026-10-16-akornatskyy-scheduler.md`.

## What it does not do

- It has no API authentication. Anyone who can reach it can read and change jobs, so it is never published, never on a host port, and never behind the API proxy. Only amplify-api calls its API.
- It does not hold Amplify data. Never point it at Amplify's database or schema.
- It does not trim `job_history` by itself. `history-retention.sql` does.
- It does not own the schedules. amplify-api does.

## Sample history

The scheduler records each call in its own database, table `job_history`. These are the five newest `amplify-run` rows from the local stack on 2026-10-21 (times in UTC):

| Started | Job | Status | Secs | Retries | Message |
|---|---|---|---|---|---|
| 10-21 19:32:57 | amplify-run | completed | 0.87 | 0 | |
| 10-21 19:27:57 | amplify-run | completed | 2.80 | 0 | |
| 10-21 19:22:57 | amplify-run | completed | 0.27 | 0 | |
| 10-21 19:17:57 | amplify-run | completed | 0.22 | 0 | |
| 10-21 19:12:57 | amplify-run | completed | 0.15 | 0 | |

Look at it yourself (local Compose):

```sh
docker compose --env-file local/.env exec -T scheduler-db psql -U scheduler -d scheduler -c \
  "select h.started, h.job_id, s.name as status, h.finished - h.started as took, h.retry_count, h.message
     from job_history h join job_history_status s on s.id = h.status_id
    order by h.started desc limit 25"
```

`history-retention.sql` trims `job_history` to 30 days. Compose applies it with the `scheduler-retention` one-shot. Choreo needs it run once by hand (operations runbook §7).
