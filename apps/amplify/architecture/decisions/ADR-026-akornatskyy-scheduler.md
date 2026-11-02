# ADR-026: akornatskyy/scheduler replaces amplify-cron and the Choreo Scheduled Task

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** owner decision 2026-10-16; plan M6b; supersedes the scheduler part of ADR-003
- **Research:** [2026-10-16-akornatskyy-scheduler.md](../../docs/research/2026-10-16-akornatskyy-scheduler.md)

## Context

ADR-003 had `amplify-cron` (a Ballerina `main()` run as a Choreo Scheduled Task) call `amplify-jobs POST /runs`. That ties the schedule to Choreo, needs a different mechanism in local Docker and OpenChoreo, and the admin "run interval" setting could only document the schedule, not change it. The owner chose [akornatskyy/scheduler](https://github.com/akornatskyy/scheduler) (MIT, Go, Postgres-backed, REST API + UI) as the one cron tool in every environment.

## Decision

1. **One scheduler everywhere.** Component `amplify-scheduler` = the upstream image `akorn/scheduler:1.7.8`, pinned by tag **and digest**, wrapped only to run as UID 10014 (`amplify-scheduler/Dockerfile`). Local: Compose service. Choreo: Service component (Dockerfile buildpack), endpoint port 8080. OpenChoreo: `deployment/service`. `apps/amplify-cron` and the Choreo Scheduled Task are removed.
2. **Two jobs with stable ids** in collection `amplify`: `amplify-run` → `POST {jobs}/runs` and `amplify-maintenance-partitions` → `POST {jobs}/maintenance/partitions`. The ids are the upsert key, so every push is idempotent.
3. **The database is the source of truth; amplify-api owns the jobs.** Settings `run.schedule` (default `@every 5m`), `run.enabled` (true) and `maintenance.schedule` (`0 2 * * *`, UTC) live in `config.app_setting` (seed S004). amplify-api validates a schedule server-side (same grammar as the scheduler: 5-field cron, descriptors, `@every`; no time-zone prefix; `@every` ≥ `minRunIntervalSeconds` (60) for runs, ≥ 1 h for maintenance) before saving.
4. **Push after commit.** `PUT /admin/settings` commits (audited `SettingChanged`), then `SchedulerSync` reads the committed settings and upserts both jobs (GET → POST or PATCH with `If-Match`; unchanged jobs are left alone). The push is serialised in-process so concurrent saves push in commit order. It's audited as `SchedulerSynced`. **If the scheduler is down, the save still succeeds** and the response says `schedulerSync: "PENDING"`.
5. **Reconcile converges.** At startup amplify-api retries the sync in the background (`reconcileAttempts` × `reconcileDelaySeconds`); `POST /admin/scheduler/sync` (`amplify_admin`, 503 `SCHEDULER_UNAVAILABLE` when it can't reach the scheduler) does it on demand. Both create missing jobs (the bootstrap: no seed file, the scheduler has no seed mechanism) and overwrite drift from manual UI edits.
6. **Client** (`amplify-api/modules/scheduler`, single consumer so not in `amplify_common`, per ADR-020/021): typed, timeout 5 s, breaker + private pool from `amplify_common.resilience`. Payloads are checked against the scheduler's limits (URI ≤ 256, body ≤ 1024, name 3-64, id pattern, retryCount ≤ 10, ≤ 4096-byte payload) before any call.
7. **Long synchronous `/runs` vs the scheduler deadline.** The scheduler's `retryPolicy.deadline` is the total budget for the call and its retries (default 20 s) and also how long it holds the job lock. `POST /runs` is synchronous for up to `runMaxSeconds` (240). So `amplify-run` gets **deadline 300 s** (`runDeadlineSeconds`), 1 retry after 30 s; maintenance 180 s, 2 retries after 60 s. Rule: **`runDeadlineSeconds` > amplify-jobs `runMaxSeconds`**; change them together. A tick inside a running deadline is skipped by the scheduler; one that reaches jobs mid-run gets `202 SKIPPED`, which counts as success.

## Security

- **The scheduler API and UI have no authentication.** Whoever reaches port 8080 can create a job that calls any URL, from inside the cell. So: **Project visibility only (Choreo), `project` visibility (OpenChoreo), internal Compose network with no host port. Never published, never behind the API proxy, no Organization visibility.**
- **Only amplify-api calls the scheduler API.** No UI or user path reaches it; admins change schedules through `PUT /admin/settings` (activity matrix, audited).
- **The scheduler calls amplify-jobs internally** over the Project network (jobs stays unpublished). Job bodies are empty; each job carries the scoped scheduler key as a header (ADR-039, amended 2026-11-01), which opens only `POST /runs` and `POST /maintenance/partitions`.
- **Own database and user** (`DSN` secret): its own Postgres database (Choreo: a separate database and user on the managed server, or its own instance; local: `scheduler-db`). Never Amplify's database or schemas; the scheduler auto-migrates unqualified table names.
- Threat model (M10) covers "no auth on the scheduler API" and the interaction "Run + maintenance (scheduler → jobs)". Residual risk: a compromised component in the same project could rewrite jobs (for example to call jobs in a loop: jobs' run lock and LinkedIn ceilings bound the damage) or read the job list (which holds the scheduler key, a scoped secret: ADR-039).

## Risks and mitigations

- **Single maintainer.** Pinned tag + digest (no silent updates), MIT so it can be forked, and the jobs endpoints stay plain HTTP: any scheduler (Compose cron container, Choreo Scheduled Task, Kubernetes CronJob) can replace it with no change to amplify-jobs.
- **Job history grows** (no retention upstream): purge `DELETE /jobs/{id}/history` before it matters (plan M12).
- **No per-run correlation id** from the scheduler (static headers): amplify-jobs generates a run id when `X-Correlation-ID` is absent.
- A manual edit in the scheduler UI is overwritten on the next reconcile, by design.

## Consequences

- Admin "run interval" is now live-applied (M7).
- New config on amplify-api: `schedulerUrl`, `schedulerJobsUrl`, `schedulerCollection`, `runDeadlineSeconds`, `maintenanceDeadlineSeconds`, `minRunIntervalSeconds`, `reconcileAttempts`, `reconcileDelaySeconds`, `schedulerTimeoutSeconds`, `schedulerResilience`. Empty `schedulerUrl` = `NOT_CONFIGURED` (unit tests, or a deployment that schedules jobs some other way).
- Version bumps: tag + digest together in the Dockerfile, `compose.yaml` (via the Dockerfile) and `scripts/it-scheduler.sh`, then run the IT.
- Kronos was not pursued (owner decision).

## Amendment (2026-10-17)

From deep review round 1 (jobs-db-infra I2, J1).

- **Scheduler history retention.** "Job history grows" above is now handled without a new caller: `amplify-scheduler/history-retention.sql` installs an `AFTER INSERT` statement trigger (plus an index on `started`) on the scheduler's **own** database that deletes `job_history` rows older than 30 days whenever the scheduler writes one. Compose applies it with the `scheduler-retention` one-shot (amplify-api waits for it); in Choreo it runs once from the scheduler DB console after the first start and after every version bump ([operations.md](../../docs/runbooks/operations.md) §7). `scripts/it-scheduler-history.sh` checks it against the pinned image in `test-all`.
- **amplify-jobs has `GET /ready`.** It gates on the database only (breaker not open and `SELECT 1` answers); the LinkedIn and Chat breakers and `runInProgress` are reported, not fatal. Compose's jobs healthcheck uses it; point the Choreo readiness probe at it.

## Amendment (2026-11-01): open question, can the Choreo Scheduled Task replace the scheduler 100%?

Not decided. Written down so the replacement conversation starts from the same list.

Lost if the Choreo Scheduled Task replaces `akornatskyy/scheduler`:

- **Admin-editable schedule.** Today `PUT /admin/settings` (`run.schedule`, `run.enabled`, `maintenance.schedule`) changes the job live through `SchedulerSync`. A Choreo task's schedule is set in Choreo. Whether Choreo has an API amplify-api could call to change it is **unverified**; without one the admin settings screen would lose those fields (or become read-only).
- **One tool everywhere.** Local Docker and OpenChoreo run the same scheduler as dev and prod; a Choreo task exists only in Choreo, so local runs would need a separate cron container and the e2e and `it-scheduler.sh` coverage would not match prod.
- **Interval.** The minimum interval of a Choreo task is unknown; today's run is `@every 5m` (and tests use seconds).

Gained:

- **No unauthenticated service or database** to keep behind Project visibility, and no job headers stored outside Choreo: the key would live only in Choreo secrets (or the task could use no static key at all if Choreo can authenticate the call itself).

Next step if anyone picks this up: confirm the task's API and minimum interval with Choreo, then decide whether the admin-editable schedule is worth keeping. Jobs stay plain HTTP either way (no change to amplify-jobs).
