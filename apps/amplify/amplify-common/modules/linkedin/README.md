# amplify_common.linkedin

The LinkedIn provider port, its adapter and the OIDC ID-token check. This is the anti-corruption layer between Amplify and LinkedIn (OAuth, userinfo, `POST /rest/posts`).

## Port and types

File: `modules/linkedin/types.bal`.

- `ProviderAdapter` is the port: `authorizationUrl`, `authorizationUrlWithNonce`, `exchangeCode`, `userInfo`, `revokeToken`, `publishShare`.
- `LinkedInConfig`: `apiBaseUrl`, `authBaseUrl`, `authorizeBaseUrl` (browser-facing base, empty means `authBaseUrl`), `clientId`, `clientSecret`, `redirectUri`, `apiVersion`, `timeoutSeconds`, `apiResilience`, `authResilience`. Base URLs are configurable so the adapter runs against `mock_linkedin` locally.
- `TokenGrant`, `MemberProfile`, `ShareCommand` (`authorUrn`, `kind`, `targetUrn`, `targetUrl`, `targetTitle`, `commentary`, `correlationId`).
- `ProviderError` with `ProviderErrorCode`: `UNAUTHORIZED`, `FORBIDDEN`, `RATE_LIMITED`, `REJECTED`, `UNAVAILABLE`, `OUTCOME_UNKNOWN`, `BAD_RESPONSE`.
- Constants: `LINKEDIN_VERSION`, `RESTLI_PROTOCOL_VERSION`, `REQUIRED_SCOPES`, `SCOPE_W_MEMBER_SOCIAL`, `DEFAULT_ARTICLE_TITLE`, `ARTICLE_TITLE_MAX_LENGTH`.

## Adapter

File: `modules/linkedin/adapter.bal`.

- `LinkedInAdapter` implements the port with two HTTP clients (API and OAuth), each with its own pool and breaker, so an OAuth outage does not block posting. `breakers()` returns `{api, auth}`.
- `publishShare` posts to `/rest/posts` and returns the post URN from the `x-restli-id` header.
- `buildPostPayload(command)` builds the body. `REPOST*` kinds reshare through `reshareContext.parent`. `SHARE*` kinds create a post with an article link and a title (`targetTitle`, else the default).
- `escapeLittleText` escapes an employee's commentary for LinkedIn little text format. `postUrl(urn)` returns the public feed URL.
- Retry stays 0 on both clients (a repeated post would post twice, an auth code is single use).

## ID-token validator

File: `modules/linkedin/id_token.bal`.

- `IdTokenValidator` validates the OIDC ID token from the code exchange: RS256 against the cached LinkedIn JWKS, `iss`, `aud` (the client id), `exp`/`nbf`/`iat` with skew, optional `nonce`. `validate(idToken, expectedNonce, now)` returns `IdTokenClaims`. `breaker()` returns the JWKS client state.
- `IdTokenConfig`: `clientId`, `issuer`, `jwksUrl`, `clockSkewSeconds`, `maxAgeSeconds`, `jwksRefreshSeconds`, `jwksMinRefreshIntervalSeconds`, `timeoutSeconds`, `resilience`. Defaults: `LINKEDIN_OIDC_ISSUER`, `LINKEDIN_JWKS_URL`.
- Keys refresh on a timer; the last good keys keep serving if a refresh fails; an unknown `kid` triggers at most one refresh per interval.
- LinkedIn has no PKCE for web apps (native clients only).

## Depends on

`amplify_common.types` (`PostUrn`, `MemberUrn`, `ShareKind`), `amplify_common.resilience` (`clientConfig`, `breakerState`).

## Does not do

- No token storage or encryption (see `crypto` and `amplify_domain.connection`).
- No retry or scheduling of failed shares (the outbox and the jobs do that).
- No engagement reads (Community Management API is a later phase).
- Never logs tokens or commentary. Errors carry status and codes only.

## Tests

`modules/linkedin/tests/adapter_test.bal`, `modules/linkedin/tests/id_token_test.bal`. They start local stub servers (ports 18210 to 18213 are shared across this package). Run `bal test` from `amplify-common`.
