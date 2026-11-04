# amplify_domain.connection

LinkedIn connection per employee: OAuth consent state, the encrypted token vault, expiry and removal. Tables: `connection_member_connection` (view `connection_member_connection_v`), `connection_provider_token` (daily partitions), `connection_oauth_state`, `connection_linkedin_consent`.

## Types and ports

File: `modules/connection/types.bal`.

- `LinkedInConnection`, `ConnectCommand`, `ConnectionChange` (carries `tokenToInsert` and the token row to delete), `TokenRef`, `StoredToken`, `ResealReport`.
- `ConnectionStatus`: `ACTIVE`, `EXPIRING`, `NEEDS_RECONNECT`, `REMOVED`. `TokenOwnerType`, `TokenKind`. `DEFAULT_REMINDER_DAYS`.
- Ports: `ConnectionRepository` (`findByEmployee`, `findByMember`, `save`), `TokenRepository` (`insert`, `find`), `TokenResealStore` (`sealedWithOtherKey`, `updateSeal`).

## Service and use cases

File: `modules/connection/service.bal`.

- Pure rules: `connectionStatus`, `canShare` (`ACTIVE` or `EXPIRING`), `connect` (connect or reconnect), `revoke`, `remove`.
- Use cases: `completeConnection` (one LinkedIn member can belong to one employee, `MEMBER_ALREADY_LINKED`), `removeConnection`.
- Token handling: `sealToken` (today's UTC partition, AAD `token_id|owner_id|provider`), `openToken`, `resealToken`, `resealStaleTokens` (key rotation, page by page), `tokenRef`. Uses `amplify_common.crypto:TokenCipher`.

## OAuth state

File: `modules/connection/oauth_state.bal`. `OAuthState`, `newOAuthState`, `nonceMatches`, `OAuthStateRepository` and `PgOAuthStateRepository` (`issue`, `consume`), `connectionCounts(db)`.

## Consent

File: `modules/connection/consent.bal`. `ConsentDecision` (`CONSENTED`, `DECLINED`), `isProfileUrl`, `PROFILE_URL_MAX_LENGTH`, `ConsentRepository` and `PgConsentRepository.save`.

## Events

File: `modules/connection/events.bal`: `connectionReadyEvent`, `connectionRevokedEvent`, `connectionRemovedEvent`.

## Repository and tables

File: `modules/connection/repository.bal`. `PgConnectionRepository(db, actor)` saves the connection, outbox and audit rows in one transaction, and inserts the sealed token in the same transaction. `PgTokenRepository` reads and updates `connection_provider_token`. `statusFromView(db, employeeId)` reads `connection_member_connection_v`.

## Config

`configurable int oauthStateTtlSeconds = 600` in `oauth_state.bal`.

## Depends on

`amplify_common.crypto`, `amplify_common.events`, `amplify_common.linkedin`, `amplify_common.types`, `amplify_domain.store`.

## Does not do

- No LinkedIn HTTP calls (the adapter in `amplify_common.linkedin` does that; `amplify-api` calls both).
- No token logging or auditing. Tokens and commentary never reach a log or audit row.
- No creation of token partitions (`store:runPartitionMaintenance`, run by `amplify-jobs`).

## Tests

`modules/connection/tests/connection_test.bal`, `modules/connection/tests/consent_test.bal`. Integration tests are in the package `tests/` directory (see the component README).
