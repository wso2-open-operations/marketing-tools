# ADR-009: People data comes from One WSO2

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan D13

## Context

Leaderboard and Team rows need photo, team and department. Storing HR data in Amplify adds privacy scope.

## Decision

The One WSO2 UI enriches Leaderboard/Team rows from what One WSO2 already has, keyed by email. `amplify-api` stores no photos or org data in phase 1.

## Consequences

- Amplify stays HR-free in phase 1.
- `amplify-api` returns emails so the UI can look people up.
- The One WSO2 endpoint (and whether it batches) is still to be found.

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D13)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md) (no HR data)
