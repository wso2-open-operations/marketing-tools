# ADR-016: Employee erasure deferred; security checklist exception

- **Status:** Accepted (security flag raised)
- **Date:** 2026-10-16
- **Source:** audit C3

## Context

Erasure can't anonymize the append-only ledger as designed. Phase 1 is a quick-to-market pilot.

## Decision

Employee delete/anonymize is deferred to a later phase. Phase 1 drops the data-deletion path from M10 and `EmployeeErased` from the build.

## Consequences

- ⚠ The WSO2 Application Deployment Security Checklist asks for a data-deletion path. The pilot needs a **recorded checklist exception** and a short manual interim process (both still open, plan M0c C3).
- The ledger erasure design and its legal basis are future work.

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (C3)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0c C3, M10)
