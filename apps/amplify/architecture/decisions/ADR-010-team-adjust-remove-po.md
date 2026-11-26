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

## Amendment 2026-11-26: Remove invalid activity (Task #1764)

**Decision.** "Remove invalid activity" is its own PO action, beside adjust and reverse: `POST /po/points/{reference}/remove {reasonCode, note}` (`CAN_ADJUST_POINTS`). The reason code is one of `DUPLICATE`, `NOT_A_REAL_REPOST`, `SPAM`, `OTHER` (a note is required for `OTHER`, up to 1000 characters). It applies to an engagement award only (`AMP-`, source `ENGAGEMENT`); adjustments, reversals and own-post awards answer 409 `NOT_REMOVABLE` and are adjusted or reversed instead. The self-correction rule (403 `SELF_REVIEW`) and "reversed at most once" (409 `ALREADY_REVERSED`) hold as for a reversal.

**Two steps, not one cross-context transaction.** ADR-005 keeps each context to its own tables; B12 (ledger to recognition) and ADR-024 item 1 (claim decision plus award) are the only deliberate cross-context writes, and this action does not need a third:

1. **C2, one gated transaction:** the removal row (a `REV-` reversal carrying `removal_reason`, reason text = the code's label plus the note), its `PointsReversed` event, an `ActivityRemoved` outbox event (key `ActivityRemoved:<engagementId>`), the audit row (`ActivityRemoved`) and the recognition update (B12). This is the authoritative step: points and standings change here.
2. **C1, idempotent:** `sharing:markEngagementInvalid` sets `sharing_engagement.invalidated_at` and `invalid_reason` once (a flagged engagement keeps its first reason) and audits `EngagementInvalidated`. amplify-api runs it right after step 1; if it fails, the request still succeeds (the points are already removed), the jobs run is triggered, and amplify-jobs handles the `ActivityRemoved` outbox row, which repeats the flag (a no-op when it is already set).

**Effects.** `sharing_engagement_v` derives status `INVALID` (before `DELETED`), so every dashboard query that counts `status = 'ACTIVE'` leaves the engagement out; leaderboards follow the ledger (B12), so the removal row takes the points and the action count off. The sync never records the engagement again (a reshare is already covered; a reaction or comment hits `engagement_once_uk`) and the award reference is deterministic, so it is never re-awarded. A PAID award is not edited: it stays PAID (V026), and the HELD removal row reduces the next Coins conversion, like any reversal.

**History.** The PO team sees `removalReason` and the reason text. The employee and their teammates see the neutral label "Removed after review by the PO team" and no reason code.

Schema: V030.
