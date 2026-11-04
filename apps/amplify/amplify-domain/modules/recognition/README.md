# amplify_domain.recognition

Pre-built leaderboard, team, monthly and campaign-participation read models, derived from the ledger and rebuildable from it. Tables: `recognition_standing`, `recognition_standing_version`, `recognition_employee_points_monthly`, `recognition_campaign_participation`.

## Types and ports

File: `modules/recognition/types.bal`.

- `EmployeeTotal` (input to ranking), `Standing` (one row of `recognition_standing`, ranks precomputed), `EmailPoints`.
- `PERIOD_ALL` (`ALL`) and `DEFAULT_TOP_N` (3). This module defines no repository port.

## Service

File: `modules/recognition/service.bal`. Pure ranking:

- `rankStandings(periodKey, totals, previousRanks)`: dense rank by points (ties share a rank), then name.
- `topN(standings, n)` and `teamStandings(periodKey, standings, teamEmails)`: company top N and My Team (the viewer's team ranked within itself).

## Reads and rebuild

File: `modules/recognition/repository.bal` (functions on a `postgresql:Client`, no class).

- `topStandings`, `standingOf`, `pointsByEmail` (input to the team and business unit boards; Amplify stores no org data), `standingVersion` (the ETag source).
- `rebuild(db, topN)` recomputes every read model with the SQL function `recognition_rebuild` (`amplify_jobs` only). It runs in a gated transaction and takes `store:lockRecognition` first.

## Queries

File: `modules/recognition/queries.bal`.

- Team and roster pages: `teamStandingsOf`, `teamPage` (`TeamSort`, `TeamPage`, `TeamEntry`), `rosterPage` (`RosterMember`, `RosterEntry`, `RosterPage`). The roster always comes from the server side, never from the caller.
- Per-person and totals: `emailOf`, `monthlyPointsOf` (`MonthPoints`), `recognitionTotals`, `campaignNumbers` (`CampaignNumbers`), `monthlyTotals`, `monthStartOf`, `nextMonthStartOf`.

## Events

None. Recognition consumes ledger rows; it publishes no event.

## Config

None. `recognition.bal` holds `MODULE`.

## Depends on

`amplify_common.types`, `amplify_domain.store`. The queries also read `scoring_points_ledger` and join `identity_employee` for names (read only).

## Does not do

- No writes of its own from the API. The ledger append updates the tables through `recognition_apply_ledger_entry` (called from `scoring`).
- No org data (team, business unit). The people directory supplies emails.
- No source-of-truth data: dropping and rebuilding the tables loses nothing.

## Tests

`modules/recognition/tests/recognition_test.bal`. Integration tests are in the package `tests/` directory (see the component README).
