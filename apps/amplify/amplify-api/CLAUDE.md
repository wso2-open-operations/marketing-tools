# CLAUDE.md — amplify-api

## Overview
Published Amplify API (Choreo "Amplify Backend"), reached only through the API proxy. M5: every phase 1 endpoint is in `openapi.yaml` — read the spec for the operations and their `x-access` grants.

## Commands
`bal build` · `bal test` (tests need `openssl` on PATH: they generate RSA keys and serve a test JWKS on :9591) (needs `amplify_common` then `amplify_domain` in the local repo, see root CLAUDE.md). Port: configurable `port` (default 9090).

## Architecture
`openapi.yaml` (the contract; lint with `scripts/lint-openapi-names.sh`), `service.bal` (resources only: auth → `handlers.bal` writes / `reads.bal` reads → `dto.bal`), `idempotency.bal` (`Idempotency-Key` on POSTs, ADR-024), `outbound.bal` (jobs trigger, people directory index of teams and business units with a 3-day cache, the employee count cached 7 days, LinkedIn + token cipher; breakers), `dashboards.bal` + `dashboard_data.bal` (the five amplify_* boards over one cached snapshot, ADR-036), `groups.bal` (open leaderboards by company / BU / team and the employee count, ADR-035), `settings.bal`, `scheduler_sync.bal` (SchedulerSync: push schedule settings to the scheduler after commit, startup reconcile, `POST /admin/scheduler/sync`; ADR-026), `interceptors.bal` (security headers + correlation id, `AuthInterceptor`, error mappers), `config.bal` (identity configurables, dev switch guard), `database.bal` (lazy client, repository factories and read functions = test seams), `problem.bal` (problem details + domain error → HTTP mapping), `constants.bal` (stable codes).
`modules/scheduler`: typed akornatskyy/scheduler client (breaker + timeout via `amplify_common.resilience`), schedule validation, payload limits.
`modules/auth`: backend JWT verifier + JWKS cache (ADR-022), the group-based access grants (`access.bal`, ADR-038) and the **activity matrix table** (`matrix.bal`, mirrors `architecture/solution/Phase 1/activity-matrix.md`; a new resource needs its row or it gets 403). Read the caller with `principalOf(ctx)`; never take an employee id from the request for "own" checks.
The bounded contexts (`campaign`, `connection`, `sharing`, `external_sharing`, `scoring`, `recognition`, `announcements`, `identity`) moved to the shared `amplify_domain` package in M3 (ADR-021, B19): pure domain, repository ports, PostgreSQL repositories, plus `amplify_domain.store` (client, outbox and audit writers). This package keeps only the HTTP layer and `utils`. Build a repository per request with the caller as `store:Actor` so every write audits who did it.

## DB connections
DB user `amplify_api`; writes own context schemas plus `recognition` for PO adjust/reverse (B12). `/ready` = `store:ping` + JWKS breaker not open (jobs/roster/LinkedIn breakers, including `linkedinIdTokenJwks`, reported only). `dbSslMode` defaults to `VERIFY_FULL` with `dbSslRootCert`. Connect: the sealed token is saved with the connection (`completeConnection(..., token)`); ID-token validation behind `linkedinIdTokenValidation` (no nonce, no PKCE).

## Key patterns
A new route needs: `openapi.yaml` (with `x-access`), the matrix row, the resource; `tests/contract_test.bal` fails otherwise. Full union return types on resources (POSTs return `http:Response` for idempotent replay, ADR-024); errors as problem details (`problem.bal`); no token/email in logs; typed HTTP errors; domain events written to the outbox in the same transaction.
