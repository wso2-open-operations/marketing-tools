# ADR-019: Team page visibility and server-side team roster

- **Status:** Accepted. Visibility of ranks and points is superseded by [ADR-035](ADR-035-open-leaderboards-and-employee-count.md) (2026-10-22); this ADR still governs the Team page, points history and the roster source. Roster source decided 2026-10-19 (people-app directory, plan M0 D13); waiting on the people-app service-client change and a Choreo connection before it works outside local.
- **Date:** 2026-10-16 (updated 2026-10-19)
- **Source:** audit B15, A10, C8; D13

## Context

ADR-014 gave employees three leaderboards and no full company list. The Team page (was Coins) still showed everyone's rank to every employee, which undoes that rule. My Team also needs team membership, which Amplify doesn't store (ADR-009).

The first version of this ADR assumed a One WSO2 roster endpoint (`?email=<viewer>` → `{teamName, members}`). It doesn't exist. What does exist is people-app's employee directory, `GET /employees/basic-info`: every current employee (Active and Marked leaver) with work email, team and sub-team, in one call. One WSO2's Org Chart already reads it.

## Decision

- Employees see the Team page for **their own team** only (read-only). `amplify_po` sees the whole company and keeps Adjust / Reverse (ADR-010).
- `team.visibility` setting: `TEAM` (default) or `COMPANY`, so PO can widen it without a release.
- **A team is the people-app sub-team**, or the team when a person has no sub-team. The key carries both, so two teams with a same-named sub-team stay apart.
- `amplify-api` reads the whole directory server to server and builds the index in memory. It reuses the index for **24 hours** (`rosterCacheSeconds`, amended 2026-11-01 from 3 days: the team list now shows the whole roster, names included, so joiners and movers should appear within a day), never writes it to the database or the logs, and keeps serving the last index when a refresh fails.
- The call goes through the Choreo gateway with OAuth2 client credentials (`peopleDirectoryUrl`, `…TokenUrl`, `…ClientId`, `…ClientSecret`). people-app admits a listed client for `GET /employees/basic-info` only (service-client allow-list, people-ops-suite PR).

## Consequences

- `GET /leaderboard` and `GET /team` shapes are in [leaderboards.md](../solution/Phase%201/leaderboards.md). The leaderboard ETag carries a hash of the viewer and their team, so a roster change or a different viewer never revalidates a stale body.
- New egress from `amplify-api` to people-app (declared connection, circuit breaker). Threat model B-E3, 8.7, AMP-R5 and AMP-R9.
- A person who isn't in the directory, or has no team, gets `teamStatus: NO_TEAM`. A directory that has never loaded gives `UNAVAILABLE`, and a non-PO caller's Team page shrinks to themselves (never widens).
- Someone who moves team shows up in the new team after at most 3 days, or straight away after an `amplify-api` restart.
- The browser-supplied-roster fallback (`team.visibility = COMPANY` with PO agreement) is no longer needed, unless the people-app change is refused.
- Locally, Compose points `amplify-api` at people-stub (`local/people-stub/directory.json`); `local/people-app-proto` runs the real people-app.

## Links

- [leaderboards.md](../solution/Phase%201/leaderboards.md), [ADR-024](ADR-024-amplify-api-m5-boundaries.md) item 5
- [ADR-009](ADR-009-people-data-from-one-wso2.md), [ADR-010](ADR-010-team-adjust-remove-po.md), [ADR-014](ADR-014-three-leaderboards-top-n.md)
- Threat model (B-E3, AMP-R5, AMP-R9)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D13, M0c B15/A10)

## Amendment 2026-11-01: the Team page lists the whole roster

The team list (My Team, the Team page, the company view) is the roster from the people directory joined to the standings, not the standings alone. A member nobody has recorded points for, whether or not they ever signed in to Amplify, is listed with 0 points, no `employeeId` and no company rank; every zero-point member shares the last team rank, and ties order by name then email. Names come from the directory (first and last name). The company-wide view lists everyone the directory lists; with the directory down and nothing cached it falls back to the people with points and answers `teamStatus: UNAVAILABLE`. The Leaderboards (`/leaderboard` top N, `/leaderboard/people`, `/leaderboard/groups`) stay standings-based: a leaderboard ranks people who scored. Directory results are cached for 24 hours (`rosterCacheSeconds`, `headcountCacheSeconds`); only a successful read is kept.
