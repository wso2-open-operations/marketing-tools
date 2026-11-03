# amplify_common

Shared Ballerina library (`wso2/amplify_common`, version in `Ballerina.toml`) for `amplify-api`, `amplify-domain` and `amplify-jobs` (ADR-020). It is not deployed. Bounded contexts and repositories live in `amplify_domain` (ADR-021).

## Contents

| Module | What it holds | README |
| --- | --- | --- |
| `types` | Domain error and codes, value objects, evidence URL parser, ledger types, shared enums, health types | [types](modules/types/README.md) |
| `events` | One payload record and one outbox builder per domain event | [events](modules/events/README.md) |
| `linkedin` | `ProviderAdapter` port, `LinkedInAdapter`, `IdTokenValidator` | [linkedin](modules/linkedin/README.md) |
| `googlechat` | Club card builder and incoming-webhook client | [googlechat](modules/googlechat/README.md) |
| `crypto` | `TokenCipher` (AES-256-GCM key ring), `constantTimeEquals` | [crypto](modules/crypto/README.md) |
| `resilience` | HTTP client resilience, database breaker, retry, metric gauges | [resilience](modules/resilience/README.md) |

The default module (`common.bal`) holds one thing: `PRODUCT`, the product name used in logs and health bodies.

Dependency order inside the package: `types` has no sibling dependency; `resilience` has none; `events` uses `types`; `linkedin` uses `types` and `resilience`; `googlechat` uses `types` and `resilience`; `crypto` has none.

## What is not here

- No database access and no service code. Domain logic stays in the owning context module in `amplify_domain`.
- The outbox writer is `amplify_domain.store`, not `events`. `events` only builds rows.
- No tokens, commentary or webhook URLs in logs or errors.

## Build and test

```sh
bal test                                  # unit tests of every module
bal pack && bal push --repository=local   # publish locally before building a consumer
```

Bump `version` in `Ballerina.toml` when the API changes, and bump the `[[dependency]]` entry in each consumer with it. A new module needs a `[[package.modules]]` entry with `export = true`.

Tests start stub HTTP servers on ports 18210 to 18213 (keep test ports inside 18200-18299). No database is needed.

Details for agents are in [CLAUDE.md](CLAUDE.md).
