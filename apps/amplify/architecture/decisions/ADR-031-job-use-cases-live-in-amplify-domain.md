# ADR-031: Job use cases live in `amplify_domain`, not in an api module or copied into amplify-jobs (B19, as built)

- **Status:** Accepted for phase 1 (as-built record; resolves B19)
- **Date:** 2026-10-17
- **Source:** plan M2 B19 follow-up, M3; audit B19
- **Amends/confirms:** [ADR-021](ADR-021-amplify-domain-shared-contexts.md)

## Context

B19 ("code layout vs ownership") flagged that shared modules sat in `amplify-api` while jobs used them. In M2 the bounded contexts first lived as modules inside `amplify-api`, but `amplify-jobs` runs half the transitions (`sharing:markPublished` / `markFailed`, `scoring:awardForEngagement`, `connection:revoke`, the announcement send, the recognition rebuild). Ballerina **cannot import a module from another deployable package**, so the M2 follow-up was to move the contexts jobs needs into `amplify_common`, or accept a thin copy, and to decide before M6. The plan is explicit that this must be decided from the code, not guessed.

## Decision (as actually built in M3)

A **second shared library, `wso2/amplify_domain`** (`apps/amplify/amplify-domain`), holds every bounded context — types, rules, use cases, events, repository port — and its PostgreSQL repository. Both services import it:

- **`amplify-api` keeps only the HTTP layer.** `amplify-api/modules/` holds just `auth`, `scheduler` and `utils`; there are no context modules. Handlers (`handlers.bal`, `reads.bal`) call the domain services.
- **`amplify-jobs` orchestrates a run through the same domain services.** `amplify-jobs/handlers.bal` imports `amplify_domain.{announcements, campaign, connection, scoring, sharing, store}` and calls `announcements:queueAnnouncement` / `markSent` / `markFailed`, `sharing:markPublished` / `markFailed`, `connection:revoke`, `scoring:awardForEngagement`, and `store:{claimOutbox, writeOutbox, writeAudit, runPartitionMaintenance}`. There is **no copy** of the rules in `amplify-jobs`.
- The contexts live at `amplify-domain/modules/` (`announcements`, `campaign`, `connection`, `external_sharing`, `identity`, `recognition`, `scoring`, `sharing`, `store`).

## Rejected alternatives (from ADR-021)

- **Copy the contexts jobs needs into `amplify-jobs`:** two copies of the scoring and sharing rules drift; the ledger reference and the "never post twice" guard must be identical in both services.
- **Move the contexts into `amplify_common`:** breaks ADR-020's rule that the common library holds no DB code and no domain logic, and pulls `ballerinax/postgresql` into a library the LinkedIn and Chat adapters do not need.

## Consequences

- One copy of every rule, used by both services; a change rebuilds both from the same commit.
- Build order is `amplify-common` → `amplify-domain` → the service (Dockerfiles do this inside the build stage; contexts per [ADR-027](ADR-027-per-component-docker-contexts.md)).
- Repository port methods are `public`, so services call them from another package; each repository is built with the shared client and a `store:Actor` (api: caller per request; jobs: `store:SYSTEM`).
- This supersedes the M2 layout ("shared modules in `amplify-api`"). B19 is resolved: the answer to "api module vs amplify-jobs" is **neither — a shared `amplify_domain` package**.

## Evidence (verified in the tree)

- `amplify-api/modules/` = `auth`, `scheduler`, `utils` only.
- `amplify-domain/modules/` = the nine contexts above, each with `service.bal` (use cases) and `repository.bal` (SQL).
- `amplify-jobs/handlers.bal` imports `amplify_domain.*` and calls the transitions listed above.
- `amplify-domain/tests/integration_test.bal` `testShareRequestRetryAndPublishByJobs`; `amplify-jobs/tests/` (`run_test.bal`, `integration_test.bal`) exercise the jobs-side transitions through the shared contexts.

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (B19)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M2 B19 follow-up, M3, M0c B19)
- [ADR-020](ADR-020-amplify-common-local-package.md), [ADR-021](ADR-021-amplify-domain-shared-contexts.md), [ADR-027](ADR-027-per-component-docker-contexts.md)
