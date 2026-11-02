# ADR-014: Three leaderboards, configurable top N (default 3)

- **Status:** Accepted. Top N scope amended by [ADR-037](ADR-037-celebrate-top-three-this-week.md). "No full company list" superseded by [ADR-035](ADR-035-open-leaderboards-and-employee-count.md) (2026-10-22): the company board is open to everyone.
- **Date:** 2026-10-16
- **Source:** audit B15, B16

## Context

"No full company list" clashed with a Team page showing everyone's rank. Leaderboard size was unclear.

## Decision

Three views from `recognition.standing`: **company top N**, **personal** (own rank, points, gap to the top N), **My Team** (ranked within the viewer's team, team from One WSO2 per ADR-009). Top N is configurable, `leaderboard.top_n = 3` for phase 1.

## Consequences

- `GET /leaderboard` returns all three views.
- Rename `points_to_podium` to `points_to_top_n`.
- Team-page visibility follows from these views.

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (B15, B16)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0c, M5 S4)
