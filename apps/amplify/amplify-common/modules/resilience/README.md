# amplify_common.resilience

Resilience settings for outbound calls and the database, plus the gauges that report them (M6, M9; ADR-025, ADR-028).

## HTTP client resilience

File: `modules/resilience/resilience.bal`.

- `HttpResilience` is one dependency's settings: rolling window, bucket size, request volume threshold, failure ratio, reset time, breaker status codes (default 429, 500, 502, 503, 504), retry count and interval, and `maxActiveConnections` (a private pool per dependency, so a slow LinkedIn cannot starve Novera).
- `clientConfig(settings, timeoutSeconds)` returns an `http:ClientConfiguration` with the timeout, circuit breaker, retry and pool.
- `breakerState(client)` returns `BreakerState` (`CLOSED`, `HALF_OPEN`, `OPEN`).
- `correlationHeaders(correlationId)` and `CORRELATION_HEADER` (`X-Correlation-ID`).
- `retryCount` stays 0 for calls that are not idempotent (`POST /rest/posts`, the Novera notification). Those retry through the outbox.

## Database breaker and retry

File: `modules/resilience/db_breaker.bal`.

- `DbBreaker` (isolated class, config `DbBreakerConfig`): `admit()` returns `DbAdmission` (`PASS`, `TRIAL`, `REJECT`), then `onSuccess()`, `onFailure(err)`, `onTrialFailure()`, `reset()`, `state()`, `openCount()`. A fake `Clock` can be passed for tests.
- `isTransientDbError(err)` is the retry predicate (connection, pool, shutdown, serialization failure, deadlock). The breaker uses a narrower private check.
- `TransientDbRetry` is a retry manager for `retry<resilience:TransientDbRetry> (n) { ... }`. Use it for reads. Writes retry through the outbox or the caller's `Idempotency-Key`.
- `loggable(err)` cuts PostgreSQL `Detail:` and `Where:` lines (they can carry row values) and keeps the SQLSTATE.

## Metrics

File: `modules/resilience/metrics.bal`. Gauges are published through `ballerina/observe`.

- `BREAKER_METRIC` (`amplify_breaker_state`: 0 closed, 1 half-open, 2 open, -1 not configured), `breakerStateValue`, `exportBreakerStates(component, states)`, `exportedBreakerValue`.
- `OUTBOX_PENDING_METRIC`, `OUTBOX_FAILED_METRIC`, `OUTBOX_OLDEST_METRIC` and `exportOutboxBacklog(component, pending, failed, oldestPendingSeconds)`, `exportedOutboxValue`.
- `TOKEN_PARTITION_METRIC` (`amplify_token_partition_days_ahead`) and `exportTokenPartitionDaysAhead`.
- Export functions never fail the caller.

## Depends on

Nothing in this package. Uses `ballerina/http`, `ballerina/sql`, `ballerina/time`, `ballerina/observe`.

## Does not do

- No config reading. Callers pass settings in (the values come from each component's Config.toml).
- No wiring to a specific dependency. `linkedin` and the Novera client in `amplify-jobs` use these types.
- No alert rules.

## Tests

`modules/resilience/tests/resilience_test.bal`, `modules/resilience/tests/db_breaker_test.bal`. Run `bal test` from `amplify-common`.
