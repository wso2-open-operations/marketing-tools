# amplify_common.coins

Client of the WSO2 Coins transaction service (wso2-coin `operations/transaction-service`), used by the automatic Coins conversion in amplify-jobs and the wallet capture in amplify-api (ADR-048).

## Port and types

File: `modules/coins/types.bal`.

- `CoinsPort`: `transfer(toAddress, amount)` (`POST /wallets/master/transfer`, whole Coins, sent as a decimal string), `walletsOf(userAssertion)` (`GET /wallets/me`, the user's token forwarded as `X-User-Assertion`, default wallet first), `masterBalance()` (`GET /wallets/master/balance`), `transactionByReference(reference)` (`GET /transactions/{reference}`, `()` on 404), `searchTransfers(filter)` (`POST /transactions/search`), `breaker()`.
- `CoinsConfig`: base URL, token URL, client id and secret of the client-credentials application (its client id maps to Amplify's master wallet at the service), scopes, timeout, `HttpResilience`.
- `CoinsError` carries `code`, `httpStatus` and `delivered`: `NO` when nothing moved (token fetch, open breaker, refused connection, any 4xx: `UNAUTHORIZED`, `RATE_LIMITED`, `INSUFFICIENT_FUNDS`, `RECIPIENT_NOT_FOUND`, `REJECTED`, `NOT_FOUND`), `UNKNOWN` when a transfer may have happened (`OUTCOME_UNKNOWN`: timeout, reset, 5xx; `BAD_RESPONSE` on an unreadable 201). The service takes no caller reference, so an `UNKNOWN` transfer is reconciled with `searchTransfers` before anything is sent again.

## Client

File: `modules/coins/client.bal`. `CoinsClient(config)` checks the settings and contacts nothing. The HTTP client (with the OAuth2 client-credentials grant) is built on the first call; it keeps the token and fetches a new one when it expires. A failed build is `UNAVAILABLE` and is tried again on the next call. No HTTP retry. Base and token URLs must be https (plain http to localhost only, for tests). Tokens, secrets and response bodies are never logged.

## Tests

`modules/coins/tests/client_test.bal`: a local stub of the service and its token endpoint on port 18215 (18298 stays closed for the refused-connection case).
