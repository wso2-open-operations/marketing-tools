# ADR-008: Local and dev identity: non-prod Asgardeo

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan D10

## Context

One WSO2 requires Asgardeo. A local WSO2 IS container would behave differently from what ships.

## Decision

Local Docker and Choreo dev use a **non-prod Asgardeo org/app** with test users in each `amplify_*` group. No local IdP container.

## Consequences

- Local runs need internet.
- Non-prod org must have no linkage to prod (security checklist).
- Org setup, localhost redirect URLs and test users are still open (plan M0 D10 sub-items).

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D10, M4, M8a)
