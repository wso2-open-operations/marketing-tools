# ADR-006: Phase 1 scoring scope: in-app reposts plus approved external shares

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** domains D7 (no plan number)

## Context

`w_member_social` can verify posts made through the app. It can't verify comments or reactions.

## Decision

Phase 1 scores in-app **reposts only** (plain or with thoughts, one per campaign per employee) plus PO-approved external shares. Comments and reactions are out of scope until a later phase.

## Consequences

- Every awarded point is backed by something the API or the PO verified.
- Comments/reactions return when Community Management access arrives.
- Whether REPOST variants ship depended on the plan D5 spike. It passed on 2026-10-20: the Amplify action is `REPOST` ([ADR-034](ADR-034-share-is-a-repost.md)).

## Links

- [phase1-domains.md](../solution/Phase%201/phase1-domains.md) (D7, open question 2)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D5, D6)
