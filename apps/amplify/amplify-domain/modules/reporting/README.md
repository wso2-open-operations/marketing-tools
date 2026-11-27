# amplify_domain.reporting

Read-only aggregates for the dashboards (ADR-036). It reads across the other contexts' views and tables with `amplify_api`'s existing `SELECT` grants and writes nothing. Every number is a fact Amplify recorded (reposts, shares, connections, announcements, the reactions and comments the engagement sync recorded), plus post reach: the latest reading of each in-app share's own post from LinkedIn's member post analytics (`sharing_engagement_metric`, V028). Reach covers only employees who connected Reach, so the boards label it approximate with `reachConsenting`.

A repost is an engagement with a share action (`REPOST`, `REPOST_COMMENTARY`, `SHARE`, `SHARE_COMMENTARY`). Every repost count filters on it, so synced `REACTION` and `COMMENT` rows never count as reposts.

This module has no `types.bal`, no repository port, no service and no events. It has no module-level unit tests; `tests/integration_reporting_test.bal` in the package covers it.

## Snapshot

File: `modules/reporting/snapshot.bal`.

- `loadSnapshot(db, now)` returns a `Snapshot` read in one `REPEATABLE READ`, read-only transaction (through `store:inTransactionValue`), so every number shares one committed state.
- Contents: live counts, campaign rows, delivery by campaign, share health (`sharing:ShareHealth`), card counts, participation, points awarded, monthly reposts, `engagementThisMonth` (reactions, comments, impressions, members reached, measured reposts) and `reachConsenting`.

## Queries

File: `modules/reporting/queries.bal`. Each function takes a `postgresql:Client`.

- Counts: `liveCounts`, `repostsBetween`, `commentaryRepostsBetween`, `connectionBreakdown`, `participationCounts`, `cardCounts`, `repostingPeople`, `pointsInMonth`, `pointsAwarded`.
- Series: `repostsByDay`, `repostsByCategory`, `monthlyReposts`.
- Campaigns: `campaignRows` (with reactions, comments, impressions, members reached and measured reposts per campaign), `deliveryOf`, `campaignCard`, `campaignReposters`.
- Reach and reactions: `engagementTotalsBetween`, `reachConsenting`.
- People and export: `personIdentity`, `personPosts`, `personPointsThisMonth`, `participationByPerson` (per employee email, for the API's location breakdown), `exportRows` (with `reactions`, `comments`, `reach`).

## Tables and views read

`campaign`, `campaign_v`, `campaign_category`, `announcement_v`, `connection_member_connection_v`, `sharing_engagement_v`, `sharing_engagement_metric`, `connection_member_analytics` (count only), `sharing_share_request_v`, `scoring_points_ledger`, `identity_employee`, `recognition_standing`, `recognition_employee_points_monthly`, `messaging_outbox`.

## Config

`configurable` in `snapshot.bal`: `dashboardCampaignWindowDays` (90), `dashboardCampaignLimit` (200), `dashboardMonthlyMonths` (6), `dashboardCardsWindowDays` (30). `reporting.bal` holds `MODULE`.

## Depends on

`amplify_domain.recognition`, `amplify_domain.sharing`, `amplify_domain.store`.

## Does not do

- No writes, no events, no audit rows.
- No access checks (`amplify-api` decides who sees which dashboard).
- No location: the people directory holds it, and amplify-api groups `participationByPerson` by it (ADR-009: no HR data stored).
