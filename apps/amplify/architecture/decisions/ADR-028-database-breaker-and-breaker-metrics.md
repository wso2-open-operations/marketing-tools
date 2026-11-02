# ADR-028: Database circuit breaker, read-only retry and breaker metrics

- **Status:** Accepted
- **Date:** 2026-10-17
- **Source:** plan M9 (Database breaker, export breaker state, no PII in logs); extends ADR-025

## Context

Every outbound HTTP dependency already has a Ballerina `http:Client` breaker, timeout and private pool (M6, ADR-025). `ballerinax/postgresql` has none: when Postgres stalls, every request waits on the pool and the connect timeout, threads pile up, and `/ready` keeps saying UP until the probe itself times out. The plan asks for a small breaker around repository calls, tight pool settings, retries only on transient errors, a stable 503 while open, and breaker state exported as metrics.

## Decision

1. **`amplify_common.resilience.DbBreaker`** (isolated class): `CLOSED` → `OPEN` after `failureThreshold` *transient* failures inside `windowSeconds`; `OPEN` refuses calls for `resetTimeSeconds`; then exactly one caller gets `TRIAL` (half-open). A successful trial closes it, any failed trial opens it again, and a trial nobody reports on expires after the reset time. The clock is injectable, so the state machine is unit-tested without sleeping.
2. **Where it sits.** Each component's `db()` (the one door to its pool) asks `admit()`. `REJECT` → `DependencyError` → **503 `DEPENDENCY_UNAVAILABLE`** (stable code, no pool touched). `TRIAL` → `SELECT 1` (`store:probe`) before the client is handed out, so the trial never depends on what the request does. Failures are recorded where errors already converge: `problem.bal failure()` in amplify-api, the run / maintenance / rebuild handlers in amplify-jobs. Successes aren't reported per call: closed-state failures age out of the window, which keeps the hot path free of extra bookkeeping.
3. **Transient only** (`isTransientDbError`): SQLSTATE classes `08` (connection), `53` (resources), `57` (shutdown/cancel), `58`, `40001`, `40P01`, and driver/pool errors that mention a connection or timeout. Unique/check violations, no-rows and type errors never count, and never retry. Wrapped errors are judged by their cause.
4. **Retry reads only.** amplify-api reads (leaderboards, `/me/points`, `/team`, lists) run inside `retry<resilience:TransientDbRetry> (dbReadRetries)` (default 1, 100 ms then doubling). Writes don't retry in-process: a lost commit acknowledgement could apply twice; they retry through the outbox (jobs) or the caller's `Idempotency-Key` (api).
5. **Tight pool.** `DbConfig` gains `poolAcquireTimeoutSeconds` (HikariCP `connectionTimeout`, default 3 s, `dbPoolAcquireTimeoutSeconds`; Hikari's own 30 s default held each request for a minute with the read retry), `connectTimeoutSeconds` and `loginTimeoutSeconds` (default 5, `dbConnectTimeoutSeconds`); socket timeout stays 30 s for maintenance and the recognition rebuild. Pool size stays `dbMaxOpenConnections` (10).
6. **Readiness.** amplify-api `/ready` fails while the DB breaker is `OPEN` (no query is sent) and lists every breaker: `database`, `jwks`, `jobs`, `roster`, `linkedinOAuth`, `linkedinApi`. amplify-jobs adds `database` to the run log's `breakers`.
7. **Metrics.** Gauge `amplify_breaker_state{component, dependency}` (0 closed, 1 half-open, 2 open, -1 not configured) through `ballerina/observe`, refreshed on every `/ready` probe (api) and at the end of every run (jobs). Both packages build with `observabilityIncluded = true`; Choreo's observability (or a Prometheus reporter where one is configured) scrapes it. Alert rule to add with M12 monitoring: `amplify_breaker_state == 2` for more than 2 minutes.
8. **Log hygiene.** `resilience:loggable(err)` cuts PostgreSQL `Detail:`/`Where:` lines (they carry row values such as emails) before an error is logged or written to `outbox.last_error`. `scripts/check-logs-pii.sh` (in `make check`) fails any `log:print*` call that passes a sensitive field (`email`, `token`, `commentary`, `code`, …) or interpolates one; reviewed exceptions carry `// log-pii: ok <why>`.

Defaults: api threshold 5 / window 30 s / reset 15 s; jobs threshold 3 / window 60 s / reset 30 s (a run is the only caller, so fewer failures say more).

## Verified on local Compose

`docker compose stop postgres` with `GET /leaderboard` in a loop: the first five calls answer 503 `DEPENDENCY_UNAVAILABLE` in ~6 s (3 s acquire, one retry), then the breaker opens and calls answer 503 in 15–40 ms; `/ready` is 503 with `breakers.database = OPEN`. After `start postgres` the half-open trial closes it and calls answer 200 without restarting the api.

## Consequences

- A dead database costs one connect timeout per request until the breaker opens, then nothing; `/ready` goes DOWN so Choreo stops routing to the replica, and the half-open trial brings it back without a restart.
- The breaker is per replica (in-process state), like the HTTP breakers. Good enough at one or two replicas.
- Metrics depend on a reporter being enabled at runtime; with none (local, unit tests) the gauge is a no-op and the same states are in `/ready` and the run log.
- `amplify_common` is 0.5.0.

## Amendment (2026-10-17)

From deep review rounds 1-2.

- **Pool exhaustion fails readiness.** HikariCP's "Connection is not available" is a transient DB error under item 3, so repeated pool timeouts open the DB breaker and `/ready` answers 503 in both api and jobs; the platform then restarts or stops routing to a replica whose pool has leaked (the R-13 failure mode, [ADR-032](ADR-032-transaction-gate-ballerina-2201-13.md)). Tests: api `testPoolExhaustionFailsReady`, jobs `poolExhaustionFailsReadiness`, jobs IT `realPoolExhaustionTripsTheBreaker` (a real one-connection pool held by `pg_sleep`).
- **`linkedinIdTokenJwks` is reported, not gating.** amplify-api `/ready` lists the ID-token validator's JWKS breaker next to the others (`NOT_CONFIGURED` while `linkedinIdTokenValidation` is off); only the connect flow needs it, so like `linkedinOAuth` it doesn't fail readiness. amplify-jobs has its own `GET /ready` gated on `database` (ADR-026 amendment).
