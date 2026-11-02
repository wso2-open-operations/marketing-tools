# ADR-018: Share verification and share metrics wait for Community Management

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** M0b research (2026-10-15 design review), C6

## Context

Pre-coin verification (C6) has to confirm that an employee's repost still exists before points become Coins. The share-metrics pass wants impressions, reactions, comments and reshares per share. Phase 1 asks members for `w_member_social` only.

Research ([2026-10-16-linkedin-deletion-and-analytics.md](../../docs/research/2026-10-16-linkedin-deletion-and-analytics.md)) found:

- Reading a member's post (`GET /rest/posts/{urn}`) needs `r_member_social`, which is restricted and closed to new requests. `w_member_social` is write-only.
- Per-share metrics come from `GET /memberCreatorPostAnalytics?q=entity` with `r_member_postAnalytics`, part of the vetted Community Management API (202506+). LinkedIn calls the counts best-effort.

## Decision

1. Phase 1 does **not** verify that shares still exist. The M6 pre-coin verification pass stays in the design and is built once Community Management access is approved. Then we live-test whether `memberCreatorPostAnalytics?q=entity` on a deleted post is a reliable existence probe.
2. Phase 1 points stay `HELD`. No Coins are issued until verification works (already true: Coins are phase 2).
3. The share-metrics pass and `sharing.engagement_metric` are phase 2. The UI keeps a slot for them.
4. Metrics are for display and reporting only. They never feed points.
5. We don't apply for `r_member_social` (closed). We apply for Community Management on its own developer app when phase 2 starts.

## Consequences

- In phase 1, an employee can delete a repost and keep the points. The DB unique keys still stop delete-and-repost from scoring twice. The PO can reverse points by hand on the Team page (D14).
- The `ENGAGEMENT_DELETED` reversal path and `engagement_verification` table stay in the model, so turning verification on later needs no schema change.
- Community Management adds a vetting step (legal entity, privacy policy, screen recording) and dev-tier limits (500 calls/app/day, 100/member/day, no BATCH_GET) to phase 2 planning.

## Links

- [Research note](../../docs/research/2026-10-16-linkedin-deletion-and-analytics.md)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0b, M6)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md) (`EngagementDeleted`, `engagement_metric`)
