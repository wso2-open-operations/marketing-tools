# ADR-011: Point rules are maintained by amplify_po

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** audit A5

## Context

R7 gives point values to the PO. The plan had `/admin/point-rules` under `amplify_admin`.

## Decision

Point rules move to `amplify_po`: `GET/POST /po/point-rules` and the Point Rules tab sit in the PO area.

## Consequences

- Admin keeps settings and kill switches only.
- The phase1-domains text still needs the role update (plan M0c A5).

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (A5)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (Roles, M5 C2, M7)
