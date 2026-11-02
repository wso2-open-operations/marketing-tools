# ADR-033: Amplify lives in marketing-tools at `apps/amplify`

- **Status:** Accepted
- **Date:** 2026-10-19
- **Supersedes:** [ADR-030](ADR-030-repository-home.md)
- **Source:** plan M0 D12, M8b, M10

## Context

ADR-030 called for Amplify to get its own repository under a WSO2-managed GitHub org, added to this workspace as a submodule at `projects/wso2-amplify`. That needed an org admin to provision a new repo, and it was still pending.

marketing-tools already exists in a WSO2-managed org (`wso2-open-operations/marketing-tools`, worked on through the fork `BechtelCanDoIt/marketing-tools`) and holds other marketing apps the same way (`apps/conference`, `apps/registrant`), each self-contained with its own `.choreo` descriptors. Amplify is a marketing tool.

## Decision

The Amplify backend moves, unchanged inside, from `projects/wso2-amplify` to **`apps/amplify` in marketing-tools** (workspace path `apps/amplify`). The UI stays in One WSO2 (`webapp/src/features/amplify`). `projects/research/wso2-amplify` keeps only a README pointing at both.

## Consequences

- The security checklist item "source in a WSO2-managed GitHub org" is met once `apps/amplify` merges upstream into `wso2-open-operations/marketing-tools`; no new repo to provision.
- Choreo "Bring Your Own Repository" points at marketing-tools, with each component's path under `apps/amplify` (api context `apps/amplify`, jobs `apps/amplify` too, database and scheduler their own folders, as in ADR-027).
- Inside the tree nothing moved: Dockerfiles, descriptors, `compose.yaml`, scripts and tests are relative to `apps/amplify`. Compose keeps `name: wso2-amplify`, so local volumes and the `wso2-amplify_internal` network survive the move.
- The repo-level LICENSE and issue/PR templates are marketing-tools' (root); Amplify's copies were dropped.
- Shared packages keep `repository = "local"` until marketing-tools has CI for Amplify (ADR-020, ADR-021, ADR-027 name the repo move as the trigger; that trigger is now this move plus CI).
- Links from `apps/amplify` docs to this workspace's `architecture/` and `docs/` work locally but not on GitHub, since they cross the submodule boundary.

## Links

- [ADR-030](ADR-030-repository-home.md) (superseded), [ADR-027](ADR-027-per-component-docker-contexts.md)
- `projects/research/wso2-amplify/README.md`
