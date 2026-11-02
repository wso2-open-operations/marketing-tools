# ADR-036: Dashboards for the amplify_* roles, read from a reporting context

- **Status:** Accepted
- **Date:** 2026-10-22
- **Source:** Lead Developer, 2026-10-22; boards agreed with the business team's review pending; builds on ADR-013 and ADR-035

## Context

PO, Marketing and SLT need to see what is live, who is sharing, which campaigns work, where participation drops and how it tracks against targets. Plain employees must not see these screens. ADR-013's PO dashboard covers PO only and still carries phase 3 tiles.

## Decision

1. **Five boards, five read endpoints**, `GET /dashboards/{operations,campaigns,participation,glance,scorecard}`, role-gated to `amplify_po`, `amplify_marketing`, `amplify_slt` and `amplify_admin` (the known role list). A plain employee gets 403 `ROLE_NOT_PERMITTED`. The activity matrix row is `DASHBOARD_READERS` (since ADR-038: `CAN_DASHBOARD`, groups from configuration).
2. **One Dashboarding menu** in One WSO2 under Amplify, a collapsible group, in this order: At A Glance, Operations, Post Performance, Participation, Scorecard. The group and routes appear only for callers holding one of the four roles; the backend is still the real gate. UI names say "Post"; API names say "Campaign" (the ubiquitous-language lint).
3. **A reporting context** (`amplify_domain.reporting`) holds the read-only aggregates. It reads across contexts with `amplify_api`'s existing `SELECT` grants, writes nothing and publishes no events. ADR-005's "a context reads only its own schema" is kept by making reporting its own read-only context, the same way the PO dashboard already composes contexts. No new tables, no new grants.
4. **One snapshot** serves all five boards: every aggregate read in one gated `REPEATABLE READ, READ ONLY` transaction (`reporting:loadSnapshot`), so all ~15 statements see the same committed state, kept in memory for 60 seconds so a refresh storm costs one set of queries. The boards compose from the snapshot, the employee count (ADR-035) and the scorecard configuration.
5. **Only facts in the database:** reposts (`sharing.engagement`), shares, connections, announcements and outbox attempts, points. No reach, impressions or anything LinkedIn analytics holds (ADR-018). A missing employee count degrades a board (no "of N"), it doesn't fail it.
6. **Expired is its own number.** The connection state `NEEDS_RECONNECT` lumps three causes; the boards split token-past-expiry (`expired`) from the rest (`revoked`). No reminders are sent or shown: expiry is a participation metric only.
7. **Chat card delivery is read-only.** A card still retrying shows the outbox attempt it is on; only a card that used every attempt needs the admin retry (ADR-024/025). No retry button on a board.

## Consequences

- `GET /po/dashboard` (ADR-013) stays as is. The operations board overlaps it by design and drops the phase 3 review queue.
- The scorecard's On track / Watch lines come from configuration (`scorecard*` configurables, env and Choreo configs, defaults in code), not the database. They are starting lines, not agreed targets. A measure with nothing to measure (no shares, no campaigns) is On track with a note; a missing employee count is Watch.
- Three test layers, each real where it matters: domain integration tests run every reporting query and the whole snapshot against PostgreSQL 18; the amplify-api tests fake only the database seam (Ballerina test mocks apply to the whole module run, so they can't be mixed with a real database) and cover role gating, response shapes, composition arithmetic and degradation; `make e2e` calls the boards over real HTTP against the real stack.
- The team and BU tables on the Participation and At A Glance boards come from `/leaderboard/groups` (ADR-035), not from the dashboard endpoints.

## Links

- [po-dashboard.md](../solution/Phase%201/po-dashboard.md), [activity-matrix.md](../solution/Phase%201/activity-matrix.md), [leaderboards.md](../solution/Phase%201/leaderboards.md)
- [ADR-013](ADR-013-po-dashboard-phase1.md), [ADR-018](ADR-018-share-verification-and-metrics-need-community-management.md), [ADR-025](ADR-025-jobs-run-delivery-and-resilience.md), [ADR-035](ADR-035-open-leaderboards-and-employee-count.md)
- Code: `amplify-api/dashboards.bal`, `amplify-api/dashboard_data.bal`, `amplify-domain/modules/reporting`
