# ADR-023: Dev-only switch to accept locally signed JWTs

- **Status:** Accepted (local Docker only)
- **Date:** 2026-10-16
- **Source:** plan M4, M8a

## Context

Locally there is no Choreo API proxy to mint `x-jwt-assertion`. M8a plans a local APIM, but until it exists (or when working offline, or writing fixtures for the UI) the API can't be called at all. Options:

1. Wait for local APIM. Blocks M8a backend work.
2. Point the verifier at the non-prod Asgardeo JWKS and pass a real Asgardeo access token as `x-jwt-assertion`. No new code path; needs internet and a test user per role. **Preferred** (runbook, option A).
3. A switch that also trusts a local key, for offline runs and arbitrary role mixes.
4. A switch that skips verification. Rejected: it's a decode-only bypass, the exact thing M4 bans.

## Decision

Keep option 2 as the default way and add option 3 behind hard guards:

- `devLocalJwtEnabled` (default `false`) plus `devJwksFile` (local JWKS) and `devIssuer` (default `amplify-local-dev`).
- **Startup refuses** the switch unless `environment = "local"`, the database connection is unencrypted (`dbSslMode = DISABLE`) and `gatewayJwksUrl` starts with `http://localhost` (three signs of a local stack, so one stray variable on a deployed environment is not enough; amended 2026-11-01 after review); `environment` defaults to `prod`, so a missing setting fails closed. It also refuses a `devIssuer` that is empty or equal to `gatewayIssuer`.
- Dev keys only verify tokens whose `iss` is `devIssuer`; gateway tokens only verify against the gateway JWKS. Signature, `exp`, `aud` and claim checks still run; nothing is skipped.
- An ERROR line at startup says the switch is on.
- `local/dev-jwt/mint-dev-jwt.sh` creates the key and JWKS (both gitignored) and mints 30-minute tokens.

## Security caveats

- Anyone who can set config on a deployment and also set `environment = local` can enable it. Choreo configs are owner-controlled; never set `environment = local` in Choreo (M10 config review checks it).
- The dev private key gives every role locally. It must never leave the developer's machine or be committed (`.gitignore`), and it must never be added to any Choreo environment.
- Local DB rows created with dev tokens are fixtures, not real employees.

## Consequences

- M8a backend work and UI fixtures can run without APIM or internet.
- One more config surface to review before go-live: `environment`, `devLocalJwtEnabled` (tests pin the refusal).
- Remove the switch if local APIM (M8a) covers every use.

## Links

- [ADR-022](ADR-022-backend-jwt-verification-and-authz.md), [ADR-008](ADR-008-local-identity-asgardeo.md)
- [Identity setup runbook](../../docs/runbooks/identity-setup.md)
