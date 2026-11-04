# amplify-api

The published Amplify API (Ballerina, Choreo "Amplify Backend"). It is reached only through the Choreo API proxy at the cell edge, which forwards the caller as a signed backend JWT in `x-jwt-assertion` ([ADR-004](../architecture/decisions/ADR-004-api-proxy-cell-edge.md), ADR-022). It serves the One WSO2 Amplify UI. Port 9090 (`port`), project visibility only ([workload.yaml](workload.yaml)).

**Contract: [openapi.yaml](openapi.yaml).** Every phase 1 operation, its `x-access` grant, its errors and its cache headers are defined there. A new route needs its entry in `openapi.yaml`, a row in `modules/auth/matrix.bal`, and the resource in `service.bal`; `tests/contract_test.bal` fails otherwise. Lint names with `../scripts/lint-openapi-names.sh`.

Request flow: `service.bal` (resources only) runs the auth interceptor, then calls `handlers.bal` (writes) or `reads.bal`, `groups.bal`, `dashboards.bal`, `topboard.bal`, `settings.bal` (reads), and maps the result to the types in `dto.bal`.

## Start-up and config

Files: `config.bal`, `service.bal`, `constants.bal`.

`config.bal` holds the identity and gateway configurables, builds the JWKS cache and refuses unsafe dev switches outside `local`. `service.bal` declares the listener and every resource, plus `/health` and `/ready`. `constants.bal` holds the stable error and status codes. Settings are Ballerina `configurable` values set through `BAL_CONFIG_VAR_<NAME>`; the table is in the [top README](../README.md#configuration).

## Auth

Files: `modules/auth/` (`token.bal`, `jwks.bal`, `access.bal`, `matrix.bal`), `interceptors.bal`.

`token.bal` verifies the backend JWT and `jwks.bal` caches the gateway signing keys behind a circuit breaker (ADR-022). `access.bal` maps Asgardeo groups to capabilities such as `CAN_CAMPAIGN` or `CAN_ADMIN` (ADR-038). `matrix.bal` is the activity matrix, one row per route; a route without a row gets 403. `interceptors.bal` adds security headers and the correlation id, runs `AuthInterceptor`, maps errors, and throttles denial audit rows. Read the caller with `principalOf(ctx)`; never take an employee id from the request for an "own" check.

## Identity resolution

File: `identity_resolution.bal`.

The token `sub` is turned into the canonical employee id through `amplify_domain.identity`, and the result is cached for 5 minutes (see the [cache table](../README.md#caches)). A clash is returned as `EMAIL_CONFLICT` and is never cached.

## Routes

Route groups follow the tags in `openapi.yaml`. `EMPLOYEE` means any signed-in employee; `CAN_*` is a capability given to the Asgardeo groups configured for it (`workload.yaml`, `modules/auth/access.bal`).

| Group (tag) | Paths | What it does | Who may call | Implemented in |
|---|---|---|---|---|
| Probes | `GET /health`, `GET /ready` | Liveness; readiness (database ping and JWKS breaker) | Public | `service.bal` |
| Identity | `GET /me` | The caller's profile | `EMPLOYEE` | `service.bal`, `identity_resolution.bal` |
| S1 Campaign | `/campaigns`, `/campaigns/{id}`, `/tags`, `/categories` | List and read campaigns; create, edit and archive them | Read `EMPLOYEE`; write `CAN_CAMPAIGN` | `handlers.bal` (writes), `reads.bal` (reads) |
| S2 Connection | `/connections/linkedin/start`, `/complete`, `/decline`, `DELETE /connections/linkedin` | Connect or disconnect the caller's LinkedIn account | `EMPLOYEE` | `handlers.bal`, `outbound.bal` (LinkedIn) |
| C1 Sharing | `POST /campaigns/{id}/shares`, `GET /me/shares` | Record a share of a campaign; list the caller's | `EMPLOYEE` | `handlers.bal`, `reads.bal` |
| S3 External Sharing | `/external-shares`, `/me/external-shares` | Employees claim a share made outside Amplify and list their claims | `EMPLOYEE` | `handlers.bal`, `reads.bal` |
| | `/po/external-shares` and its `approve`, `reject`, `amplified` actions | Review those claims | `CAN_REVIEW_SHARES` | `handlers.bal`, `reads.bal` |
| C2 Scoring | `/po/point-rules` | List and add point rules | `CAN_POINT_RULES` | `handlers.bal`, `reads.bal` |
| | `POST /po/points/adjustments`, `POST /po/points/{reference}/reverse` | Adjust points; reverse a ledger entry | `CAN_ADJUST_POINTS` | `handlers.bal` |
| S4 Recognition | `/leaderboard`, `/leaderboard/people`, `/leaderboard/groups`, `/headcount`, `/me/points`, `/team`, `/team/{employeeId}/history` | Leaderboards, the viewer's points, My Team and the employee count | `EMPLOYEE` | `reads.bal`, `groups.bal` |
| | `/leaderboard/top` | Celebrate top three and the caller's position (ADR-037) | `EMPLOYEE` | `topboard.bal` |
| | `GET /po/dashboard` | Program owner dashboard for a month | `CAN_PO_DASHBOARD` | `reads.bal` |
| S6 Dashboards | `/dashboards/operations`, `/campaigns`, `/participation`, `/glance`, `/scorecard`, `/people/{employeeId}` | The `amplify_*` boards over one cached snapshot (ADR-036) | `CAN_DASHBOARD` | `dashboards.bal`, `dashboard_data.bal` |
| | `GET /dashboards/export` | CSV export | `CAN_EXPORT` | `dashboards.bal` |
| S5 Admin | `/admin/announcements`, `/admin/announcements/{id}/retry`, `/admin/settings` (GET, PUT) | Failed announcements and retry; read and change settings | `CAN_ADMIN` | `reads.bal`, `handlers.bal`, `settings.bal` |
| | `POST /admin/scheduler/sync` | Push the schedule settings to the scheduler | `CAN_ADMIN` | `scheduler_sync.bal` |

Every POST accepts `Idempotency-Key` (`idempotency.bal`, ADR-024): a repeat with the same key and body returns the stored response.

## Outbound calls

File: `outbound.bal`.

Calls to amplify-jobs (trigger a run), the HR Entity GraphQL directory (teams, business units, names, headcount, and house name and id; OAuth2 client credentials, ADR-045) and LinkedIn (OAuth, ID-token check, token cipher, revoke). Each client has a timeout and a circuit breaker. The breaker states show on `/ready`.

## Scheduler sync

Files: `scheduler_sync.bal`, `modules/scheduler/` (`client.bal`, `schedule.bal`).

After a settings change is committed, `SchedulerSync` pushes the schedule to the scheduler (ADR-026). It reconciles once at start-up, and `POST /admin/scheduler/sync` forces it. With no `schedulerUrl` the change is saved and reported as `NOT_CONFIGURED`. The module holds the typed scheduler client (breaker, timeout) and the schedule validation.

## Caches

Directory index, headcount, settings, monthly totals, dashboards, resolved subs and gateway keys are cached in memory in this component. The house cache (`house_cache.bal`, `house_service.bal`, `house_types.bal`, ADR-046) is here too but nothing loads it yet. Lifetimes, invalidation and failure behavior are in the [cache table](../README.md#caches).

## Error handling

Files: `problem.bal`, `json_body.bal`.

Every error is `application/problem+json` with a stable `code`; bodies carry no stack trace, SQL or upstream response. `problem.bal` builds the problem details and maps domain errors to HTTP statuses. `json_body.bal` writes JSON bodies and sets `Cache-Control` (`no-store` unless the operation says otherwise). Logs carry no token or email.

## Database access

File: `database.bal`.

A lazy PostgreSQL client with a circuit breaker, and the repository factories and read functions the tests replace. The api connects as the single `amplify_api` login and schema (ADR-042, ADR-043). Domain logic and repositories live in `amplify-domain`; build a repository per request with the caller as `store:Actor` so every write audits who did it. Domain events go to the outbox in the same transaction.

## Tests

Folder: `tests/`. Run from this folder:

```
bal build
bal test
```

Publish `amplify-common` then `amplify-domain` to the local Ballerina repository first (see the [top README](../README.md#build)). The tests need `openssl` on PATH: they generate RSA keys and serve a test JWKS on port 9591. `contract_test.bal` and `contract_drift_test.bal` check the code against `openapi.yaml`; `auth_matrix_test.bal` checks the matrix; `fakes.bal` and `read_fakes.bal` replace the database. `../scripts/test-all.sh` runs every component.
