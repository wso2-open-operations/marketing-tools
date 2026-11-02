# CLAUDE.md — amplify-common

## Overview
Shared Ballerina library (`wso2/amplify_common`) for `amplify-api` and `amplify-jobs` (ADR-020). Not deployed.

## Commands
`bal pack && bal push --repository=local` after any change, then rebuild consumers. Bump `version` when the API changes.

## Architecture
Default module (`PRODUCT`) plus exported modules:
- `types`: health types, shared enums (const unions, since contexts reuse member names), `DomainError` + codes, value objects (`EmployeeId`, `MemberUrn`, `PostUrn`, `EvidenceUrl` with C5 normalization), `LedgerEntry` and `LedgerReference`, `newUuidV7()`.
- `events`: one payload record + builder per domain-event catalogue row; outbox key `<event_type>:<parts>`.
- `linkedin`: `ProviderAdapter` port + `LinkedInAdapter` (OAuth code exchange, userinfo, `POST /rest/posts`), base URLs configurable for `mock_linkedin`. `IdTokenValidator`: OIDC ID-token check (RS256 against the cached LinkedIn JWKS, `iss` `https://www.linkedin.com/oauth`, `aud`, `exp`/`nbf`/`iat` with skew, optional `nonce`). LinkedIn has no PKCE for web apps (native clients only).
- `googlechat`: cardsV2 Club card builder + incoming-webhook client.
- `crypto`: `TokenCipher` (AES-256-GCM via javax.crypto, random 96-bit nonce, AAD `token_id|owner_id|provider`, key ring by `key_id`; `reseal` moves an old-key row to `activeKeyId()`).
- `resilience`: `HttpResilience` (breaker, retry, private pool per dependency), `clientConfig`, `breakerState`, `correlationHeaders` (M6/M9, ADR-025); `DbBreaker`, `isTransientDbError`, `TransientDbRetry`, `exportBreakerStates` gauge (M9, ADR-028).
The outbox writer lives in `amplify_domain.store` (ADR-021). New modules need a `[[package.modules]]` entry with `export = true`. Current version 0.6.0 (consumers pin it in their `[[dependency]]`; bump both together). Tests use stub ports 18210-18213 (keep test ports in 18200-18299).

## Key patterns
No DB access to context schemas and no service code here. Domain logic stays in the owning context module. Never log tokens, commentary or the webhook URL; provider errors carry only status and codes.
