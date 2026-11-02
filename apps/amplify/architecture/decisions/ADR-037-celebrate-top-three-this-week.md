# ADR-037: Celebrate top three and My position are for this month, cached 2 hours

- **Status:** Accepted. Amended 2026-10-29: the scope was the calendar week, now the calendar month (the file keeps its name so links hold)
- **Date:** 2026-10-22
- **Source:** Lead Developer, 2026-10-22; amends ADR-014 (top N is no longer always all-time)

## Context

The Celebrate "Top three amplifiers" read the all-time standings, so the same people sat on the podium for good. The business first wanted a weekly race, then moved every screen to a monthly scope (2026-10-29), and everyone opens Celebrate at the same few times, so the same sum should not run for every visit.

## Decision

1. **Scope is a setting.** `leaderboard.top_scope` (`config.app_setting`, admin-editable): `MONTH` (default; was `WEEK`) or `ALL`. Seed S009 moves an existing `WEEK` value to `MONTH` and leaves `ALL` alone. `ALL` serves the all-time standings as before.
2. **This month** is the calendar month, the 1st 00:00 UTC to the next 1st. People are ranked by the sum of their signed ledger points in it (adjustments and reversals included, so the arithmetic matches the all-time board). Anyone whose week nets to zero or less is left off. Ties share a rank.
3. **Company wide.** The top three come from every employee with points; they are never narrowed to the caller's team or business unit (checked: `topBoard` reads no roster).
4. **My position matches.** The caller's rank, points and gaps come from the same monthly totals as the podium, so the two always agree.
5. **Shared cache, 2 hours.** The monthly totals live in memory in amplify-api (`topBoardCacheSeconds`, default 7200, env `BAL_CONFIG_VAR_TOPBOARDCACHESECONDS`, `local/.env` as `TOP_BOARD_CACHE_SECONDS`). The first caller after they expire reads the ledger; everyone else reuses them. Ranking and the viewer's line are computed per request from the cached totals, so a new `leaderboard.top_n` applies at once. The cache is dropped when the month rolls over. A failed reload serves the previous totals of the same month; with none, the call answers 503.
6. **Minimum to qualify (2026-10-29).** Only people with at least `leaderboard.top_min_points` (default 100, seed S010, admin-editable, `MONTH` scope only) are ranked. Someone under it sees their own points with no rank. The filter runs per request on the cached totals. If more than three people qualify for the top spots, a further evaluation by post reach is done by hand, outside the app; ties still share a rank.
7. **Endpoint.** `GET /leaderboard/top` (all roles). The body is per viewer (`me`), so the response is `private, max-age=60`. `GET /leaderboard` is unchanged and still feeds My Team.

## Consequences

- Points can take up to 2 hours (plus 60 s in the browser) to show on the podium. Accepted; the all-time board and My Team stay near real time.
- One cache per amplify-api replica: with N replicas the ledger is read up to N times per 2 hours.
- Several callers arriving together on an empty cache may each read the ledger once; the read is one grouped query over a month of rows.
- On the 1st the board starts empty ("No points yet this month").
- `previousRank` is not tracked for months (always null).
- The month sum reads `scoring.points_ledger` from the recognition context, as the rebuild already does.

## Links

- [ADR-014](ADR-014-three-leaderboards-top-n.md), [ADR-035](ADR-035-open-leaderboards-and-employee-count.md)
- [leaderboards.md](../solution/Phase%201/leaderboards.md)
