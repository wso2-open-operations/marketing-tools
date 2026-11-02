# WSO2 Amplify — Phase 1 Leaderboards

Status: Draft v1 (2026-10-16)
Closes: audit B15, A10 ([requirements-map.md](requirements-map.md)) · Decisions: [ADR-014](../../decisions/ADR-014-three-leaderboards-top-n.md) (three views, top N), [ADR-009](../../decisions/ADR-009-people-data-from-one-wso2.md) (people data from One WSO2), [ADR-019](../../decisions/ADR-019-leaderboard-team-visibility.md) (visibility)

**Phasing (2026-10-19):** individual and team leaderboards are **phase 1** (Celebrate in One WSO2: top three, my position, team leaderboard). The full points/Coins history is phase 2; automatic scoring rules and PO point edits are phase 3. Phase 1 still ranks by points, so whatever awards points in phase 1 (repost tracking) has to stay on.
Data: [phase1-data-model › recognition](phase1-data-model.md#recognition--s4-recognition-read-models) · Plan: [M5 S4, M7 Leaderboard and Team](../../../docs/requirements/phase1-planned-todos.md)

## The three views

| View | Who sees it | What it shows | Where in the UI |
| --- | --- | --- | --- |
| **Company top N** | Every employee | The top `leaderboard.top_n` people (default **3**) by points: rank, name, points, movement arrow. Ties share a rank (`dense_rank`), so the list can hold more than N rows | Leaderboard page, the podium |
| **Personal** | The viewer only | Own rank, points, `points_to_next_rank`, `points_to_top_n`, movement, last activity. Merges into the podium when the viewer is in the top N | Leaderboard page, "your card" |
| **My Team** | Every member of that team | Everyone in the viewer's team, ranked within the team: team rank, name, points. Headcount and "active" count on top | Leaderboard page, below your card; Team page for employees |

The Celebrate top three and My position use `GET /leaderboard/top` (this calendar month by default, `leaderboard.top_scope`, monthly totals cached 2 hours: [ADR-037](../../decisions/ADR-037-celebrate-top-three-this-week.md); only people with `leaderboard.top_min_points` (100) that month are ranked); `GET /leaderboard` below stays `ALL` and feeds My Team.

Period: `ALL` in phase 1. `period` is a parameter on every call so monthly or quarterly boards (plan D6, open) need no API change.

**Open boards (2026-10-22, [ADR-035](../../decisions/ADR-035-open-leaderboards-and-employee-count.md)).** WSO2 is an open company, so the full company list is no longer withheld: every employee can see ranks and points for the company, any business unit (BU) and any team, and teams and BUs ranked against each other. This replaces the 2026-10-15 "gossip, not motivation" rule for ranks and points. Another person's points *history* is still limited (own, own team, PO).

| View | Endpoint | Who | What |
| --- | --- | --- | --- |
| Company, every person | `GET /leaderboard/people?scope=COMPANY` | Everyone | Paged and searchable. No directory needed |
| One BU, every person | `GET /leaderboard/people?scope=BU&bu=` | Everyone | `bu` defaults to the caller's own BU |
| One team, every person | `GET /leaderboard/people?scope=TEAM&team=` | Everyone | `team` is the opaque key from `/headcount` or `/leaderboard/groups`; defaults to the caller's own |
| All teams | `GET /leaderboard/groups?by=TEAM` (`&bu=` for one BU's teams) | Everyone | Teams ranked by summed points, with participants, headcount, participation rate |
| All BUs | `GET /leaderboard/groups?by=BU` | Everyone | Same, one row per BU |
| Employee count | `GET /headcount` | Everyone | Total, by BU, by team. Memory cache 7 days |

Shapes are in `amplify-api/openapi.yaml` (`LeaderboardPeople`, `LeaderboardGroups`, `Headcount`). Group rows use dense rank (ties share a rank), then name. Participants are people with a standing row; participation rate is participants over headcount (3 decimals). People with points whom the directory can't place in a team or BU are summed in `unassigned`, so totals still reconcile. BU is each person's `businessUnit` from the directory, never worked out; the team key is `businessUnit/team/subTeam`.

## Team grouping (where "team" comes from)

Amplify stores no org data (ADR-009). The team comes from **people-app's employee directory**, keyed by work email: the same source the One WSO2 UI reads for photos and names.

1. `amplify-api` resolves the viewer's team roster (member emails + team name) from people-app's employee directory (`GET /employees/basic-info`, the same source One WSO2's Org Chart reads), **server to server**, through a declared egress connection with a circuit breaker. The whole directory is fetched in one call and grouped by **sub-team**, falling back to **team** when a person has no sub-team (decided 2026-10-19), under the person's own `businessUnit` (ADR-035). The index is kept in memory for **3 days** (teams change, but rarely), **never written to the database**; a failed refresh keeps serving the last index.
2. It ranks that set from `recognition.standing` (query below).
3. The One WSO2 UI adds photos and full names per row from the same directory, with the user's own token (Org Chart's query, shared through React Query). If that fails, rows show amplify-api's display name and initials.

Why server side: if the browser sent the list of emails, any employee could ask for anyone's points, and the visibility rule below would mean nothing.

**How `amplify-api` gets in:** OAuth2 client credentials through a Choreo connection to people-app. people-app's interceptor used to refuse any token without a user email (500), so the people-ops-suite PR adds a service-client allow-list: a listed client may call `GET /employees/basic-info` and nothing else. Proven end to end locally (`apps/amplify/local/people-app-proto`, 11/11). Still open (plan M0 D13): merge it, create the connection, and confirm on a real gateway token which claim carries the client id (`azp` assumed). If people-app refused the change, the fallback would be the UI posting the roster emails **and** `team.visibility = COMPANY`, which needs PO agreement that points and rank aren't sensitive.

If the directory has never loaded and is down, or the breaker is open with nothing cached, `myTeam` comes back as `null` with `teamStatus: "UNAVAILABLE"`; the company and personal views still work.

## Visibility

| Data | Employee | `amplify_po` | `amplify_marketing`, `amplify_slt`, `amplify_admin` |
| --- | --- | --- | --- |
| Company top N, full company list, BU and team boards, team and BU rankings ([ADR-035](../../decisions/ADR-035-open-leaderboards-and-employee-count.md)) | yes | yes | yes |
| Own rank, points, gaps, history | yes | yes | yes (as employees) |
| My Team (own team only) | yes | yes | yes (as employees) |
| Team page, own team (search, expand history) | yes, read-only | yes | as employees |
| Team page, **whole company** (search, sort, filter by team/department) | no | **yes**, with Adjust / Reverse (ADR-010) | no |
| Another employee's points history (`GET /team/{id}/history`) | only a member of the viewer's team | anyone | as employees |

Setting `team.visibility` (`TEAM` default, or `COMPANY`) lets PO widen the Team page later without a release ([ADR-019](../../decisions/ADR-019-leaderboard-team-visibility.md)). Enforced in `amplify-api` (the real gate); the UI only hides.

## Queries

All against `recognition.standing` (PK `(period_key, employee_id)`, indexes `(period_key, rank)` and `(period_key, email)`), read through `amplify_api`'s `select` grant.

```sql
-- Company top N (ties can return more than N rows)
SELECT employee_id, display_name, email, total_points, rank, previous_rank
FROM recognition.standing
WHERE period_key = $period AND rank <= $top_n
ORDER BY rank, display_name;

-- Personal (single PK lookup; no row = no points yet)
SELECT total_points, rank, previous_rank, points_to_next_rank, points_to_top_n, last_activity_at
FROM recognition.standing
WHERE period_key = $period AND employee_id = $viewer;

-- My Team: rank within the viewer's directory sub-team
SELECT employee_id, display_name, email, total_points, rank AS company_rank,
       dense_rank() OVER (ORDER BY total_points DESC) AS team_rank
FROM recognition.standing
WHERE period_key = $period AND email = ANY($team_emails::citext[])
ORDER BY team_rank, display_name;

-- Team page (paged, searchable). Employees: add AND email = ANY($team_emails)
SELECT employee_id, display_name, email, total_points, rank, previous_rank, last_activity_at
FROM recognition.standing
WHERE period_key = $period
  AND ($q IS NULL OR display_name % $q OR display_name ILIKE $q || '%')
ORDER BY rank, display_name
LIMIT $size OFFSET $offset;
```

`points_to_top_n` = points of the lowest-ranked person inside the top N, minus the viewer's points, plus 1 (0 if the viewer is already in). It's precomputed by the re-rank step, so changing `leaderboard.top_n` triggers `POST /maintenance/rebuild-recognition`.

Team members with no standing row have no points yet. They count toward `headcount` but not `activeCount`, and phase 1 doesn't list them: `myTeam.entries` holds only people with points, and the API never returns the rest of the roster's emails.

## `GET /leaderboard`

Employee and up. `?period=ALL` (default). ETag `<period>:<standing_version>:<viewer>`, where `<viewer>` is 16 hex characters of a SHA-256 over the viewer's employee id and team (name and size); `Cache-Control: private, max-age=30`, `Vary: Authorization`. The body is per viewer (`me`, `myTeam`), so the ETag has to be too: with only the standings in it, a browser revalidated one user's cached body for another after an account switch and got a 304 (fixed 2026-10-19). A body degraded by a directory outage carries no ETag and is `no-store`. The team index behind `myTeam` is reused for 3 days.

```jsonc
{
  "period": "ALL",                       // ALL | YYYY-MM | YYYY-Qn
  "topN": 3,                             // leaderboard.top_n
  "generatedAt": "2026-10-30T09:12:00Z",
  "company": [                           // rank <= topN, ties included
    { "employeeId": "a1b2…", "displayName": "Jane Doe", "email": "jane@example.com",
      "points": 120, "rank": 1, "previousRank": 2 }
  ],
  "me": {                                // null fields when the viewer has no points yet
    "employeeId": "c3d4…", "points": 35, "rank": 14, "previousRank": 17,
    "pointsToNextRank": 5, "pointsToTopN": 70, "inTopN": false,
    "lastActivityAt": "2026-10-29T15:40:00Z"
  },
  "myTeam": {                            // null when teamStatus != OK
    "teamName": "Digital Engineering",   // people-app sub-team (team when none)
    "headcount": 18,                     // roster size
    "activeCount": 11,                   // roster members with a standing row
    "entries": [
      { "employeeId": "e5f6…", "displayName": "Sam Lee", "email": "sam@example.com",
        "points": 60, "teamRank": 1, "companyRank": 6, "isMe": false }
    ]
  },
  "teamStatus": "OK"                     // OK | NO_TEAM | UNAVAILABLE
}
```

## `GET /team`

`?period=ALL&q=&sort=rank|points|name&page=0&size=25`. Employees get their own team (`scope: "TEAM"`); `amplify_po` gets the company (`scope: "COMPANY"`), plus `?team=` / `?department=` filters that the UI turns into an email list from One WSO2 data. Emails are returned so One WSO2 can add photo, team and department (ADR-009).

```jsonc
{
  "period": "ALL",
  "scope": "TEAM",                       // TEAM | COMPANY
  "page": 0, "size": 25, "total": 18,
  "summary": { "headcount": 18, "activeCount": 11 },   // C8: headcount from the people-app directory, active from standing
  "entries": [
    { "employeeId": "e5f6…", "displayName": "Sam Lee", "email": "sam@example.com",
      "points": 60, "rank": 6, "teamRank": 1, "previousRank": 6,
      "lastActivityAt": "2026-10-28T10:02:00Z",
      "actions": { "canAdjust": false, "canReverse": false } }   // true only for amplify_po
  ]
}
```

`GET /team/{employeeId}/history` returns that person's ledger rows (reference, date, action, points, campaign title, reason for ADJ/REV), paged, newest first, under the same visibility rule. Errors: `403 TEAM_SCOPE` outside the caller's scope.

## Tests

- Ties at rank N return every tied row; `pointsToTopN` is 0 for them.
- An employee can't read a non-team member through `/team`, `/team/{id}/history` or a crafted `q`.
- Directory down with nothing cached → `teamStatus: UNAVAILABLE`, rest of the response 200; an expired index is still served while a refresh fails.
- One directory call serves every viewer until the index expires.
- Another viewer's `If-None-Match` gets their own 200, never a 304.
- p95 < 50 ms for `/leaderboard` with a warm directory index (load test, M11).
