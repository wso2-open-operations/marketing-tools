# ADR-015: A retry after a failed share reuses the same row

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** audit C2

## Context

Unique `(campaign_id, employee_id)` plus a final `failed_at` locked an employee out of a campaign after one failure.

## Decision

Posting again after a `FAILED` share reuses the row: clear `failed_at` / `failure_reason`, bump `attempts`, re-queue. The API doesn't return `DUPLICATE_ACTION` for that case.

## Consequences

- Still one row per campaign per employee.
- Attempt history lives in the audit log, not extra rows.

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (C2)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M5 C1)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md) (share_request)
