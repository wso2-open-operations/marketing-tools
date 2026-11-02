# ADR-035: Open leaderboards by company, BU and team; employee count cached for a week

- **Status:** Accepted
- **Date:** 2026-10-22
- **Source:** Lead Developer, 2026-10-22 ("very open company: the full company leaderboard is accessible to all"); amends ADR-014 and ADR-019

## Context

ADR-014 gave employees a top N, their own rank and their own team, and deliberately no full company list ("gossip, not motivation", 2026-10-15 review). ADR-019 then limited the Team page to the viewer's own team, with `team.visibility = COMPANY` as the switch to open it.

WSO2 is an open company and the owner wants the company board open. Dashboards for PO, Marketing and SLT also need teams and business units (BU) ranked against each other, and an employee count to turn "people with points" into a participation rate. Amplify stores no org data (ADR-009), so both come from the people-app directory.

## Decision

1. **Points boards are open to every signed-in employee.** Ranks and points are visible company-wide, by BU, by team, and as team-vs-team and BU-vs-BU boards. No role is needed and `team.visibility` doesn't gate them.
2. **Three read endpoints** (all roles, activity matrix rows added):
   - `GET /leaderboard/people?scope=COMPANY|BU|TEAM&bu=&team=&q=&page=&size=`: people ranked in the scope. `BU` and `TEAM` default to the caller's own.
   - `GET /leaderboard/groups?by=TEAM|BU|HOUSE&bu=`: teams (optionally one BU's), BUs or houses (the people-app `house` on each directory row, added after this ADR) ranked by the sum of their members' points, with participants, headcount and participation rate. Teams with no points are listed. People the directory can't place are summed in `unassigned`, never dropped.
   - `GET /headcount`: employees overall, by BU and by team.
3. **What stays narrower:** `GET /team/{employeeId}/history` (another person's dated ledger rows) is still own, own team, or PO, and no longer opens up when `team.visibility = COMPANY`. The Team page (`GET /team`) keeps its setting and its PO Adjust/Reverse actions (ADR-010).
4. **Directory index grows.** One call to `GET /employees/basic-info` now builds team *and* BU membership and the full count of people with a work email, once each. **BU is never derived.** It is the `businessUnit` on each person's directory row, and the team key carries it (`businessUnit/team/subTeam`), so a team's BU is the one the directory gives its members. If people of one team sit under two BUs in the directory, they show as two teams, which exposes the data problem instead of guessing past it. A person with no team still counts toward the headcount and their BU.
5. **Employee count cache: 7 days** (`headcountCacheSeconds`, memory only, never written to the database). When it runs out the directory is read again, which also refreshes the team index. A failed refresh keeps serving the last count; a count that was never taken gives 503 `DEPENDENCY_UNAVAILABLE`. The team index keeps its 3-day cache (ADR-019).
6. **Denominators:** group and people boards take headcount from the weekly count, membership from the team index. They can differ by up to a few days when someone moves; the weekly count wins for "of 830".
7. **Scorecard targets** are configuration, not database settings: `scorecardTargetConnectedPct`, `scorecardMaxExpiredPct`, `scorecardTargetShareSuccessPct`, `scorecardTargetPriorityReachPct`, `scorecardTargetActive30d`, `scorecardTargetRepostsPerMonth` (env `BAL_CONFIG_VAR_*`, `local/.env` as `SCORECARD_*`, Choreo configs). A missing or non-positive value uses the default (25, 5, 98, 25, 100, 600). The reposts target is per calendar month (ADR-036, ADR-037). The employee-count TTL is `headcountCacheSeconds` (default 7 days) the same way. The defaults are starting lines for PO to tune, not agreed targets.

## Consequences

- ADR-014's "no full company list" and ADR-019's visibility rule are superseded for ranks and points. Points *history* is not.
- The reports need no new table: group boards read `recognition.standing` through `pointsByEmail` and the directory index. One more query of at most ~830 rows per request.
- Group boards and BU views need the directory. When it has never loaded, they answer 503; the company board doesn't need it.
- Another employee's rank and points are now visible to all. That is the decision, but security should note it in the threat model (data classification of points) and the data-deletion exception still applies.
- Reach and impressions stay out: boards report only what Amplify recorded (reposts, shares, connections, points, Chat card status).

## Links

- [leaderboards.md](../solution/Phase%201/leaderboards.md), [activity-matrix.md](../solution/Phase%201/activity-matrix.md), [po-dashboard.md](../solution/Phase%201/po-dashboard.md)
- [ADR-009](ADR-009-people-data-from-one-wso2.md), [ADR-014](ADR-014-three-leaderboards-top-n.md), [ADR-019](ADR-019-leaderboard-team-visibility.md)
- Code: `amplify-api/groups.bal`, `amplify-api/outbound.bal`, `amplify_domain.recognition:pointsByEmail`
