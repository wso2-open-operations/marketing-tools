# amplify_api.scheduler

Typed client for the scheduler REST API (akornatskyy/scheduler, ADR-026) and the checks that keep a job spec inside the scheduler's limits. `amplify-api` is its only API caller. The scheduler API has no authentication and is reachable on the internal network only.

This module has no `Module.md`. It has no database access.

## Job spec and validation

File: `modules/scheduler/schedule.bal`.

- `JobSpec`: `id`, `name`, `schedule`, `enabled`, `uri`, `body`, headers (`Header`), `retryCount` (0-10), `retryIntervalSeconds`, `deadlineSeconds` (also how long the scheduler's job lock is held, so it must exceed the slowest successful call).
- `checkSchedule(schedule, minEverySeconds)` checks a 5-field cron (UTC), a descriptor such as `@daily`, or `@every <Go duration>`. Time-zone prefixes are refused. It returns `()` when valid, else a message.
- `parseGoDuration`, `goDuration`.
- `jobPayload(collectionId, spec)` builds the JSON for `POST /jobs` and `PATCH /jobs/{id}` after checking every field against the scheduler's length limits, so a bad value fails here before any call.
- `sameJob(existing, desired)` compares the stored job with the desired one, so an unchanged job is not rewritten.

## Client

File: `modules/scheduler/client.bal`.

- `Api` is the port: `ensureCollection`, `upsertJob`, `breakerState`. Unit tests pass a fake.
- `Client(url, timeoutSeconds, settings)` implements it behind a timeout and a circuit breaker (`resilience:HttpResilience`).
- `upsertJob` returns `UpsertResult` (`CREATED`, `UPDATED`, `UNCHANGED`). Jobs are upserted by stable id, so every call is safe to repeat.

## Config

None in this module. The root module reads `schedulerUrl` (in `scheduler_sync.bal`); the database settings are the source of truth and the sync (at startup, after a settings save, and on `POST /admin/scheduler/sync`) pushes them here.

## Depends on

`amplify_common.resilience`. Uses `ballerina/http`.

## Does not do

- No settings storage. A scheduler outage never fails a settings save.
- No authentication to the scheduler (none exists).
- No job execution. The scheduler calls the `amplify-jobs` endpoint.

## Tests

`modules/scheduler/tests/scheduler_test.bal`. Run `bal test` from `amplify-api`. The root-module sync is covered by `amplify-api/tests/scheduler_sync_test.bal`.
