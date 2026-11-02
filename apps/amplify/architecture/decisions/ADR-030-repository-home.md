# ADR-030: Amplify source lives in its own repository under a WSO2-managed GitHub org

- **Status:** Superseded by [ADR-033](ADR-033-amplify-lives-in-marketing-tools.md) (2026-10-19): Amplify lives in marketing-tools at `apps/amplify`
- **Date:** 2026-10-17
- **Source:** plan M0 D12, M1, M8b, M10

## Context

The WSO2 Application Deployment Security Checklist requires the Amplify source to live in a **WSO2-managed GitHub org**. Today the workspace repo's origin is a personal org (`git@github.com:BechtelCanDoIt/wso2-amplify.git`), and M1 built the code **in-tree** at `projects/wso2-amplify` with D12 left open (plan M1: "D12 still open: built inside this repo for now"). Every sibling project (`one-wso2`, `people-ops-suite`, `wso2-coin`, `wso2-digital-agents`) is already a git **submodule** of this workspace.

D12 asks whether `projects/wso2-amplify` becomes its own repo under a WSO2-managed org, added as a submodule, or lives in this repo.

## Decision

The Amplify source becomes **its own repository under a WSO2-managed GitHub org**, added to this workspace as a **git submodule at `projects/wso2-amplify`**, matching the pattern of the other projects. Its default branch is `main` (Choreo "Bring Your Own Repository" builds v1.0.0 from `main`, M8b). Until the org and repo are provisioned, the code stays in-tree in this workspace repo; nothing at runtime depends on the move.

**What it gates:**

1. **M8b Choreo onboarding.** Choreo "Bring Your Own Repository" needs the Choreo GitHub app authorized on the org repo. The component descriptors, Docker contexts and `workload.yaml`s are already in place ([ADR-027](ADR-027-per-component-docker-contexts.md)); only the repo and console connection are missing.
2. **M10 security checklist.** The item "Source in a WSO2-managed GitHub org" is a go-live gate; the checklist exception process does not cover it.
3. **Shared-package build switch.** Once the repo has its own CI, `amplify_common` / `amplify_domain` can drop `repository = "local"` and be built as ordinary dependencies ([ADR-020](ADR-020-amplify-common-local-package.md), [ADR-021](ADR-021-amplify-domain-shared-contexts.md), [ADR-027](ADR-027-per-component-docker-contexts.md) name a repo move as the trigger).

**Pending — WSO2 GitHub org admin (and the security checklist owner):** which WSO2 org, the repository name, and the provisioning itself. Pending (out of scope here): whether the other submodules must also move to a WSO2-managed org.

## Rejected alternatives

- **Keep it in this workspace repo (personal org):** fails the security checklist, which is a go-live gate.
- **A subtree instead of a submodule:** this workspace already uses submodules for every project; a subtree would diverge and make one-repo/one-CI/one-access-list harder to tell.
- **Monorepo with the One WSO2 UI:** different owners and release cadence; the One WSO2 UI is its own project.

## Consequences

- The move is `git submodule add` + removing the in-tree copy + pointing Choreo's BYOR at the new repo. Code, Dockerfiles and descriptors are unaffected (paths stay `projects/wso2-amplify` and `apps/...`).
- No secrets or console state in Git; provisioning needs org access (owner above).
- The shared-library `repository = "local"` setting is untouched until the move; the build stays self-contained inside each component's Docker context (ADR-027).

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D12, M1, M8b, M10)
- [ADR-020](ADR-020-amplify-common-local-package.md), [ADR-021](ADR-021-amplify-domain-shared-contexts.md), [ADR-027](ADR-027-per-component-docker-contexts.md)
- `projects/wso2-amplify/README.md` (repo-home note)
