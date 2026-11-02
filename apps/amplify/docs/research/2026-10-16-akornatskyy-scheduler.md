# akornatskyy/scheduler: research for M6b (2026-10-16)

Owner decision (2026-10-16): `akornatskyy/scheduler` is the cron tool for Amplify in every environment (local, Choreo, OpenChoreo), replacing amplify-cron and the Choreo Scheduled Task. This note records what the API and image actually do, read from the source at tag `v1.7.8` (commit `8e6b309`, 2026-09-28) and confirmed against the running image in `scripts/it-scheduler.sh`. Decision: [ADR-026](../../architecture/decisions/ADR-026-akornatskyy-scheduler.md).

## Sources

1. Repo and README: https://github.com/akornatskyy/scheduler
2. OpenAPI spec: https://github.com/akornatskyy/scheduler/blob/master/packages/api-spec/openapi.yaml (rendered: https://akornatskyy.github.io/scheduler)
3. Routes: https://github.com/akornatskyy/scheduler/blob/master/apps/api/internal/infrastructure/http/routes.go
4. Field limits: https://github.com/akornatskyy/scheduler/blob/master/apps/api/internal/shared/rule/validation.go
5. Models and retry defaults: https://github.com/akornatskyy/scheduler/blob/master/apps/api/internal/domain/models.go
6. Runner (retry/deadline loop): https://github.com/akornatskyy/scheduler/blob/master/apps/api/internal/core/runner.go
7. HTTP action runner: https://github.com/akornatskyy/scheduler/blob/master/apps/api/internal/infrastructure/http/runner.go
8. Cron engine (robfig/cron v3, UTC): https://github.com/akornatskyy/scheduler/blob/master/apps/api/internal/infrastructure/cron/scheduler.go and https://pkg.go.dev/github.com/robfig/cron/v3
9. Image: https://hub.docker.com/r/akorn/scheduler (tags API: https://hub.docker.com/v2/repositories/akorn/scheduler/tags)
10. Dockerfile: https://github.com/akornatskyy/scheduler/blob/master/deployments/docker/Dockerfile
11. Licence: MIT, https://github.com/akornatskyy/scheduler/blob/master/LICENSE

## Image and runtime

- **Latest stable: `1.7.8`** (Docker Hub, pushed 2026-09-28; `latest` was re-pushed 2026-10-11). Pinned as `akorn/scheduler:1.7.8@sha256:07462c0684245d5f8aaed8018e4594da3ba113d5b38bb6dffcc32403108d2cf6`.
- Scratch image, one static Go binary + the React UI under `/static`, `USER nobody`, `EXPOSE 8080`, `STOPSIGNAL SIGINT`. Runs fine as UID 10014 with a read-only root filesystem (checked in the IT), so a two-line wrapper Dockerfile makes it Choreo-compatible.
- Config: **one env var, `DSN`** (`postgres://user:pass@host:5432/db?sslmode=...`). Port is hard-coded **`:8080`**. It **auto-migrates** its own tables (`migration`, `collection`, `job`, `job_status`, `job_history`, `variable`) with unqualified names, so it gets its own database and user.
- `GET /health` → `{"status":"up"}` (503 when the DB is down).
- Scale-out: every instance loads all enabled jobs; Postgres `LISTEN/NOTIFY` spreads changes; a DB row lock (`AcquireJob`, held for the job's deadline) makes one instance run a job at a time.

## REST API (JSON, no authentication)

**There is no authentication or authorization on any route, including the UI.** Anyone who can reach port 8080 can create a job that calls any URL. It must stay on the internal network.

| Route | Notes |
| --- | --- |
| `GET/POST /collections`, `GET/PATCH/DELETE /collections/{id}` | A job must belong to a collection. `state`: `enabled`/`disabled` (a disabled collection stops its jobs). |
| `GET/POST /variables`, `GET/PATCH/DELETE /variables/{id}` | Per-collection values usable as Go templates in the request (`{{.Name}}`). Not used by Amplify. |
| `GET /jobs?collectionId=&fields=status,errorRate` | List. |
| `POST /jobs` | **Client-supplied `id` is accepted** (else a random one). 201 with the id; 409 on a duplicate id; 400 with field errors; 422 when the JSON can't be decoded. |
| `GET /jobs/{id}` | Returns the job and an `ETag`; `If-None-Match` → 304. |
| `PATCH /jobs/{id}` | Decodes the body **into the stored job** (a merge: omitted fields keep their values). `If-Match` → 412 on mismatch. 204. |
| `DELETE /jobs/{id}` | 204. |
| `GET/PATCH /jobs/{id}/status` | `{"running": true}` runs it now. |
| `GET/DELETE /jobs/{id}/history` | `started`, `finished`, `status`, `retryCount`, `message`. |

Job body:

```json
{
  "id": "amplify-run", "name": "Amplify Run", "collectionId": "amplify", "state": "enabled",
  "schedule": "@every 5m",
  "action": {
    "type": "HTTP",
    "request": {"method": "POST", "uri": "http://amplify-jobs:9091/runs", "headers": [], "body": ""},
    "retryPolicy": {"retryCount": 1, "retryInterval": "30s", "deadline": "300s"}
  }
}
```

Durations are Go durations; the API echoes them normalised (`"300s"` comes back as `"5m0s"`).

## Limits (validation.go)

| Field | Limit |
| --- | --- |
| `id`, `collectionId` | 3-36, `^[A-Za-z0-9][A-Za-z0-9_-]*$` |
| `name` | 3-64 |
| `schedule` | 6-64, must parse with robfig `ParseStandard` |
| `request.method` | HEAD, GET, POST, PUT, PATCH, DELETE |
| `request.uri` | **8-256**, http or https |
| `request.body` | **≤ 1024** |
| header name / value | 5-32 / ≤ 256 |
| `retryCount` | 0-10 |
| request body of create/patch | ≤ 4096 bytes |

## Schedules

robfig/cron v3 `ParseStandard`, scheduler location **UTC**:

- 5-field cron: minute, hour, day of month, month (`JAN`-`DEC`), day of week (`SUN`-`SAT`); `*`, `?`, ranges, lists, `/step`.
- Descriptors: `@yearly`/`@annually`, `@monthly`, `@weekly`, `@daily`/`@midnight`, `@hourly`.
- `@every <Go duration>` (for example `@every 10s`, `@every 1h30m`); sub-second rounds up to 1 s.
- `CRON_TZ=`/`TZ=` prefixes parse too; Amplify refuses them (UTC only).

## Retry and timeouts (the part that matters for `/runs`)

- Default retry policy when none is given: **3 retries, 5 s apart, 20 s deadline**.
- The **deadline is the whole budget**: one `context.WithTimeout(deadline)` wraps every attempt and wait. The HTTP client has no other timeout. So with the default, a synchronous `POST /runs` that takes 21 s is cancelled and recorded as failed.
- 2xx = success (so `202 SKIPPED` from amplify-jobs is fine). 400/401/403/404/422 are not retried; anything else is, until `retryCount` or the deadline.
- The job lock (`AcquireJob`) is held for the deadline too: a tick that comes while the previous call is still inside its deadline is skipped, so the scheduler itself never overlaps a job.
- Amplify sets `amplify-run` to deadline **300 s** (> amplify-jobs `runMaxSeconds` 240), 1 retry after 30 s; maintenance 180 s, 2 retries after 60 s.

## Gaps and risks

- **No API auth** (above): Project visibility / internal network only, never published, only amplify-api uses the API.
- **Single maintainer** (one author, project started in 2019, small user base). Mitigation: pinned tag + digest, MIT licence (forkable), Amplify's jobs endpoints are plain HTTP so any scheduler (a cron container, Choreo Scheduled Task, Kubernetes CronJob) can replace it without code changes in jobs.
- **No JSON seed file at startup**: jobs are created only through the API (or the UI). Amplify's startup reconcile creates them instead.
- No per-run correlation id: headers are static (templating only sees collection variables, `JobID`, `CollectionID`). amplify-jobs generates its own run id when `X-Correlation-ID` is absent.
- No history retention: `job_history` grows until `DELETE /jobs/{id}/history`. At `@every 5m` that's ~105k rows a year: fine for the pilot, add a purge before it matters.
