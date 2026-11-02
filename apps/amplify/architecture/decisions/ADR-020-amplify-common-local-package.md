# ADR-020: Shared code lives in an `amplify_common` package from the local Ballerina repository

- **Status:** Accepted for phase 1; B19 review done in [ADR-021](ADR-021-amplify-domain-shared-contexts.md) (contexts moved to `amplify_domain`)
- **Date:** 2026-10-16
- **Source:** plan M1 (shared code), B19

## Context

`amplify-api` and `amplify-jobs` both need the same domain types, the outbox client, token crypto, the LinkedIn adapter, the Google Chat client and the circuit breakers. Ballerina has no workspace or path dependency: a package can only depend on another package pulled from a repository (Central, an org on Central, or the local repository under `~/.ballerina/repositories/local`). The options were:

1. Copy the shared modules into each service. No build plumbing, but two copies of crypto and the LinkedIn adapter drift fast.
2. Publish `amplify_common` to Ballerina Central under a WSO2 org. Versioned and clean, but needs an org on Central, publish credentials in CI, and a release step for every shared change during a two-week build.
3. Keep `amplify_common` in this repo and publish it to the **local** repository during each build (`bal pack && bal push --repository=local`), with `repository = "local"` on the consumer's dependency.

## Decision

Option 3. `apps/amplify/amplify-common` is a library package (`wso2/amplify_common`). `amplify-api` and `amplify-jobs` declare it in `Ballerina.toml`:

```toml
[[dependency]]
org = "wso2"
name = "amplify_common"
version = "0.1.0"
repository = "local"
```

Their Dockerfiles build from `apps/amplify` and pack/push `amplify-common` in the build stage before `bal build`. `amplify-cron` and `amplify-database` don't depend on it.

M1 scaffolds only the default module and `types` (health types). `outbox`, `crypto`, `linkedin`, `googlechat` and `resilience` arrive as exported modules in M2/M6. Bounded-context logic stays in `amplify-api` modules; the library holds only what both services need.

## Consequences

- One copy of shared code, one change, both services rebuilt from the same commit.
- Developers run `bal pack && bal push --repository=local` in `amplify-common` before building a consumer (documented in the root README and CLAUDE.md).
- Choreo components must set a Docker context that contains `amplify-common` (M8b). **Amended by [ADR-027](ADR-027-per-component-docker-contexts.md):** api builds from `apps/amplify`, jobs from `apps/amplify` too (see ADR-027 note), because Choreo reads `.choreo/component.yaml` from the Docker context.
- `Dependencies.toml` in consumers pins `amplify_common` 0.1.0; bump the version when its public API changes.
- If the repo moves (D12) or more teams consume it, switch to option 2 with no code change beyond dropping `repository = "local"`. B19 stays open to review this.

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M1, M0c B19, M0 D12)
- [ADR-003](ADR-003-worker-shape.md)
