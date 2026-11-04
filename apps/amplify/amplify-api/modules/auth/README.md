# amplify_api.auth

Verification of the gateway's backend JWT and the access matrix that decides which route each caller may use. Pure Ballerina over `ballerina/jwt`, `ballerina/crypto` and `ballerina/http` (for the JWKS fetch). No database access. Imported by the service and interceptors in the `amplify-api` root module.

This module has no `Module.md`. It has no tests in its own directory; the tests are in `amplify-api/tests/` (`auth_test.bal`, `auth_matrix_test.bal`, `jwt_support.bal` for local signing).

## Token verification

File: `modules/auth/token.bal`.

- `TokenVerifier(jwks, config, dev)` with `verify(token, now)`. It checks the RS256 signature against the JWKS first, then `iss`, `aud` (any configured value), `exp` and `nbf` with skew, then the identity claims. Nothing is trusted before the signature verifies. `MAX_TOKEN_LENGTH` is 8192 characters.
- `VerifierConfig`: `issuer`, `audiences`, `clockSkewSeconds` (60), `rolesClaim` (`groups`), `emailClaim`, `nameClaim`, and the `AccessGroups`.
- `Principal`: the verified caller (`employeeId`, `email`, `displayName`, `roles`, grants, `issuer`). `roles` holds only the groups the access configuration names; others are dropped.
- `AuthError` with stable `TOKEN_*` codes (`TOKEN_MISSING`, `TOKEN_MALFORMED`, `TOKEN_ALG_NOT_ALLOWED`, `TOKEN_SIGNATURE_INVALID`, `TOKEN_EXPIRED`, `TOKEN_NOT_YET_VALID`, `TOKEN_ISSUER_INVALID`, `TOKEN_AUDIENCE_INVALID`, `TOKEN_CLAIMS_INVALID`) and `KEYS_UNAVAILABLE`.
- `DevTrust` (`issuer`, `keys`): dev-only trust for locally signed tokens (ADR-023). Its issuer must differ from the gateway's.
- `knownGroups`, `WarningThrottle`, `fromBase64Url`, `toBase64Url`, `keysBreakerState()`.

## JWKS cache

File: `modules/auth/jwks.bal`. `JwksCache(JwksConfig)` holds the gateway keys behind a circuit breaker. Keys refresh on age or an unknown `kid`, at most once per `minRefreshIntervalSeconds`; the last good keys keep serving when the IdP is down. `keysFor(kid)`, `breakerState()`, `parseJwks(json)`, `Jwk`.

## Access and the matrix

Files: `modules/auth/access.bal`, `modules/auth/matrix.bal`.

- `Access` enum: `EMPLOYEE`, `CAN_CAMPAIGN`, `CAN_DASHBOARD`, `CAN_EXPORT`, `CAN_REVIEW_SHARES`, `CAN_POINT_RULES`, `CAN_ADJUST_POINTS`, `CAN_PO_DASHBOARD`, `CAN_REPORTS`, `CAN_ADMIN`. Capabilities, not role names, are what code checks.
- `AccessGroups`: the Asgardeo groups granted each capability (`canCampaign`, `canDashboard`, and so on). Empty means nobody holds it.
- `groupList`, `hasAny`, `grantsOf`, `configuredGroups`.
- `ACTIVITY_MATRIX` (`Rule[]`: `method`, `path`, `requires`, `capability`, `useCase`, `built`): first match wins and a route not listed is denied. `USE_CASE_CAPABILITIES` lists capabilities checked inside a use case (reported by `GET /me`). `PUBLIC_PATHS` is `/health` and `/ready`.
- `findRule`, `isAllowed`, `capabilities`, `isPublic`.

## Config

None in this module. The root module's `config.bal` supplies the values, for example `jwtHeader` (`x-jwt-assertion`), `gatewayJwksUrl`, `jwksRefreshSeconds`, `jwksMinRefreshIntervalSeconds`, `jwksTimeoutSeconds`, `jwksBreakerResetSeconds`, `devLocalJwtEnabled`, `devJwksFile`, `devIssuer`.

## Depends on

`amplify_common.types` (`EmployeeId`).

## Does not do

- No state or ownership checks. The use case checks those (`Rule.useCase` documents them).
- No gateway or proxy behavior and no database reads. Employee resolution (`identity`) happens after verification, in the root module.
- No trust in a token before its signature verifies.

## Tests

Run `bal test` from `amplify-api`. The matrix test walks every route against `ACTIVITY_MATRIX`.
