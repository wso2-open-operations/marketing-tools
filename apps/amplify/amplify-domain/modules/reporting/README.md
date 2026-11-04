# amplify_domain.reporting

Read-only aggregates for the dashboards (ADR-036). It reads across the other contexts' views and tables with `amplify_api`'s existing `SELECT` grants and writes nothing. Every number is a fact Amplify recorded (reposts, shares, connections, announcements). No reach or impressions.

This module has no `types.bal`, no repository port, no service and no events. It has no module-level unit tests; `tests/integration_reporting_test.bal` in the package covers it.

## Snapshot

File: `modules/reporting/snapshot.bal`.

- `loadSnapshot(db, now)` returns a `Snapshot` read in one `REPEATABLE READ`, read-only transaction (through `store:inTransactionValue`), so every number shares one committed state.
- Contents: live counts, campaign rows, delivery by campaign, share health (`sharing:ShareHealth`), card counts, participation, points awarded, monthly reposts.

## Queries

File: `modules/reporting/queries.bal`. Each function takes a `postgresql:Client`.

- Counts: `liveCounts`, `repostsBetween`, `commentaryRepostsBetween`, `connectionBreakdown`, `participationCounts`, `cardCounts`, `repostingPeople`, `pointsInMonth`, `pointsAwarded`.
- Series: `repostsByDay`, `repostsByCategory`, `monthlyReposts`.
- Campaigns: `campaignRows`, `deliveryOf`, `campaignCard`, `campaignReposters`.
- People and export: `personIdentity`, `personPosts`, `personPointsThisMonth`, `exportRows`.

## Tables and views read

`campaign`, `campaign_v`, `campaign_category`, `announcement_v`, `connection_member_connection_v`, `sharing_engagement_v`, `sharing_share_request_v`, `scoring_points_ledger`, `identity_employee`, `recognition_standing`, `recognition_employee_points_monthly`, `messaging_outbox`.

## Config

`configurable` in `snapshot.bal`: `dashboardCampaignWindowDays` (90), `dashboardCampaignLimit` (200), `dashboardMonthlyMonths` (6), `dashboardCardsWindowDays` (30). `reporting.bal` holds `MODULE`.

## Depends on

`amplify_domain.recognition`, `amplify_domain.sharing`, `amplify_domain.store`.

## Does not do

- No writes, no events, no audit rows.
- No access checks (`amplify-api` decides who sees which dashboard).
- No external metrics (impressions, reach).
