# ADR-012: amplify_po can manage campaigns

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** audit A6

## Context

R1 says Marketing **and** PO register posts. Phase 1 limited campaign writes to `amplify_marketing`.

## Decision

`amplify_po` is allowed on every campaign endpoint alongside `amplify_marketing`.

## Consequences

- Interceptor and proxy scopes accept either role for campaign writes.
- Audit rows record which role acted.

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (A6)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (Roles, M5 S1, M7)
