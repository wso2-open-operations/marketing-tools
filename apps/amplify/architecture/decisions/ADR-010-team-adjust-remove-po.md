# ADR-010: Team page adjust/remove is amplify_po only

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan D14

## Context

The Team page lets someone adjust or remove an employee's points. That needs a clear owner.

## Decision

Only `amplify_po` can adjust or reverse points from the Team page.

## Consequences

- Adjust/reverse needs a reason and a PO actor (DB `CHECK`).
- Whether `amplify_marketing` also gets this is an open client question (plan M0 D14 sub-item).

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D14, M0b)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md) (ledger rules)
