# ADR-021: Bounded contexts and repositories live in a shared `amplify_domain` package

- **Status:** Accepted for phase 1
- **Date:** 2026-10-16
- **Source:** plan M0c B19, M2 follow-up, M3
- **Amends:** [ADR-020](ADR-020-amplify-common-local-package.md) (B19 review)

## Context

M2 built each bounded context (types, rules, use cases, events, repository port) as a module inside `amplify-api`. But `amplify-jobs` runs half of those transitions: `sharing:markPublished` / `markFailed`, `scoring:awardForEngagement`, `connection:revoke`, the announcement send, the recognition rebuild. In M3 each context also gets its PostgreSQL repository, which jobs needs too. Ballerina can't import a module from another deployable package, so the options were:

1. Copy the contexts jobs needs into `amplify-jobs`. Two copies of the scoring and sharing rules drift; the ledger reference and the "never post twice" guard must be identical in both.
2. Move the contexts and repositories into `amplify_common`. One package to publish, but it breaks ADR-020's rule that the common library holds no DB access and no domain logic, and it pulls `ballerinax/postgresql` into a library the LinkedIn and Chat adapters don't need.
3. A second library package, `wso2/amplify_domain`, that depends on `amplify_common` and holds the contexts, their repositories and a small `store` module (client, outbox writer, audit writer, error mapping, partition upkeep call).

## Decision

Option 3. `apps/amplify/amplify-domain` is published to the local repository like `amplify_common` (ADR-020), after it. Its modules: `identity`, `campaign`, `connection`, `sharing`, `external_sharing`, `scoring`, `recognition`, `announcements`, `store`. `amplify-api` keeps only the HTTP layer; `amplify-jobs` gets the same use cases and repositories.

- Repository port methods are `public`, so the services can call them from another package.
- A repository is built with the shared client and a `store:Actor` (api: the caller per request; jobs: `store:SYSTEM`). Every write commits aggregate row + outbox row + audit row in one transaction.
- The ledger append also applies the row to `recognition` in that transaction (B12), through the SQL function `recognition.apply_ledger_entry`. That's the one cross-schema write, and it is by design: recognition is a projection of the ledger.
- Dependency direction: services → `amplify_domain` → `amplify_common`. `amplify_common` stays free of DB code.

## Consequences

- One copy of every rule, used by both services; a change rebuilds both from the same commit.
- Build order is `amplify-common`, then `amplify-domain`, then the service (Dockerfiles do this inside the build stage, from a clean checkout; contexts per [ADR-027](ADR-027-per-component-docker-contexts.md)).
- Each context still reads and writes only its own schema; moving a context out later means moving its module.
- If the repo moves (D12) or Central is adopted, both libraries switch the same way (drop `repository = "local"`).

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0c B19, M2, M3)
- [ADR-020](ADR-020-amplify-common-local-package.md), [ADR-005](ADR-005-data-model-conventions.md)
