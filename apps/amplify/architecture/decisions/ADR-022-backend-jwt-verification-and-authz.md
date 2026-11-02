# ADR-022: amplify-api verifies the backend JWT itself and enforces the activity matrix in code

- **Status:** Accepted for phase 1
- **Date:** 2026-10-16
- **Source:** plan M4, M9 (JWKS), [activity-matrix.md](../solution/Phase%201/activity-matrix.md)

## Context

The Choreo API proxy validates the Asgardeo access token and forwards a backend JWT in `x-jwt-assertion` (ADR-004). The backend has Project visibility, but the activity matrix says the backend is the real gate, so `amplify-api` can't trust the header just because it arrived. Decode-only interceptors are banned (plan M4). We also need: keys that survive an IdP blip (M9), a role × route table that matches the matrix doc, and an employee row with email and display name.

`ballerina/jwt` can validate against a JWKS URL, but its cache has no breaker and no "keep serving stale keys" behavior, and it hides why a key lookup failed.

## Decision

1. **Own verifier** (`amplify-api/modules/auth`): RS256 only (`none`/HS* rejected), signature checked against the gateway JWKS before any claim is trusted, then `exp`/`nbf` (60 s skew), `iss`, `aud` (any of a configured list), `sub` (EmployeeId) and `email`. Claim names for roles, email and name are configurable because the backend JWT may rename them.
2. **JWKS cache**: keys refreshed on age (1 h) or an unknown `kid`, at most once per 30 s once keys exist; HTTP client with a circuit breaker and 5 s timeout. A failed refresh keeps the last good keys. No keys at all → **503 `DEPENDENCY_UNAVAILABLE`**, not 401, so an IdP outage doesn't look like a sign-out.
3. **Activity matrix as one table** (`modules/auth/matrix.bal`), row for row with activity-matrix.md. The request interceptor enforces role × method × route; a route not in the table is denied (**default deny**, `ROUTE_NOT_PERMITTED`). State, ownership and kill-switch conditions (`PENDING` only, own claim, `employeeId` = caller, `sharing.enabled`, ...) stay in the use cases; the table carries them as a `useCase` note so reviewers see where each check lives.
4. **Roles** come only from the roles claim (default `groups`), filtered to the four `amplify_*` names. **A missing claim means a plain employee**, not a 401: employees have no group (Roles table).
5. **Identity from claims, not userinfo.** `email` and `name` must be in the backend JWT; `GET /me` upserts `identity.employee` from them. No userinfo call, so no extra dependency or token handling in the backend. A token without `email` is rejected (`TOKEN_CLAIMS_INVALID`).
6. **Denials**: 401/403 as problem details (`application/problem+json`, stable `code`), an `audit.audit_log` row with `outcome = DENIED` (actor `anonymous` for 401), and a log line with code, route template and correlation id only. No token, email or claim values in logs (iss/aud only at debug, for setup).
7. `GET /me` capabilities are derived from the same table plus two use-case capabilities (`campaigns.read_any_status`, `team.history.read_any`).

## Consequences

- One place to change access: edit matrix.bal and activity-matrix.md together. M5 resources must add their row or they answer 403.
- Unknown routes answer 403 instead of 404 for an authenticated caller (less route probing).
- Denial audit writes are synchronous. Behind the proxy, 401s are rare; if bypass traffic ever floods the backend, move denials to a sampled or async writer.
- An outage of both the IdP and our cache (cold start during an IdP outage) means 503 until the JWKS answers.
- If the proxy can't carry `email`/`groups` claims, revisit item 5 (userinfo once, cached in `identity.employee`).

## Links

- [Identity setup runbook](../../docs/runbooks/identity-setup.md)
- [ADR-004](ADR-004-api-proxy-cell-edge.md), [ADR-008](ADR-008-local-identity-asgardeo.md), [ADR-023](ADR-023-dev-local-jwt.md)
