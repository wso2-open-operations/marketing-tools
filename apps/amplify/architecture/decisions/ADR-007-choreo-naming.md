# ADR-007: Choreo project and component naming

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan D9

## Context

Choreo display names should follow the team convention and match across environments.

## Decision

Project **Amplify**. Components **Amplify API Proxy**, **Amplify Backend** (`amplify-api`, single consumer One WSO2), **Amplify Jobs**, **Amplify Cron**, **Amplify DB Migrate**, **LinkedIn Mock** (dev only). Repo folders keep kebab-case.

## Consequences

- Console names are predictable for ops and on-call.
- Repo and Choreo names differ in case only; the mapping is this table.

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D9, M8b)
