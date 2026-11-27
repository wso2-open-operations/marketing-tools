# Seed

Reference data applied after the migrations, tracked in `schema_version` (in the Amplify schema) like them (`S###__name.sql`).
Every insert is `ON CONFLICT DO NOTHING`, so an admin's later change is never overwritten.

- `S001__point_rules.sql`: the first proposal, effective from the epoch: REPOST 5, REPOST_COMMENTARY 12, SHARE 5,
  SHARE_COMMENTARY 12, OWN_POST 20, OWN_POST_AMPLIFIED 40. Kept for awards made before 2026-10-19.
- `S005__point_rules_pilot.sql`: the pilot values from the business, effective 2026-10-19: SHARE 2 (phase 1, the
  Amplify button), REPOST 2 and REPOST_COMMENTARY 5 (phase 4, native reposts tracked from LinkedIn), OWN_POST 10
  and OWN_POST_AMPLIFIED 25 (phase 3, 10 + the 15 bonus). No SHARE_COMMENTARY: no phase uses it. Likes/comments
  (phase 4) and Amplify Challenge entry/winner (PO adjustments for now) aren't rules yet.
- `S006__point_rules_all_values.sql`: adds the rules the platform prices for later phases, effective 2026-10-19: SHARE_COMMENTARY 5, REACTION 1, COMMENT 1, CHALLENGE_ENTRY 10, CHALLENGE_WINNER 25.
- `S007__top_scope_setting.sql`: `leaderboard.top_scope = WEEK` (ADR-037), what the Celebrate top three covers; S009 moves it to MONTH. An admin can set `ALL`.
- `S002__categories.sql`: placeholder categories until Marketing confirms them.
- `S003__app_settings.sql`: `leaderboard.top_n = 3`, `team.visibility = TEAM`, `campaign.default_window_days = 30`,
  `po.review_sla_hours = 48`, `posts.window_days = 14`, `connection.reminder_days = 7`,
  `connection.token_grace_days = 5`, `audit.retention_months = 60`, kill switches `sharing.enabled`,
  `announcements.enabled`.
- `S004__scheduler_settings.sql`: `run.schedule = @every 5m`, `run.enabled = true`,
  `maintenance.schedule = 0 2 * * *` (UTC), pushed to the scheduler by amplify-api (ADR-026).
- `S008__token_grace_one_day.sql`: moves `connection.token_grace_days` from 5 to 1 (ADR-002). S003 can't be edited once applied; V016 does the same for databases that already have the 5.
- `S009__top_scope_month.sql`: moves `leaderboard.top_scope` from WEEK to MONTH (ADR-037 amended). S007 can't be edited once applied. It changes WEEK to MONTH whoever set it, so an admin's WEEK becomes MONTH on its first run; an admin value of ALL is kept.
- `S010__top_min_points_setting.sql`: `leaderboard.top_min_points = 100`, the points needed in the month to qualify for the Celebrate top three (ADR-037); an admin can change it.
- `S011__external_share_daily_limit.sql`: `external_share.daily_limit = 3`, the own posts one employee may submit per UTC day (phase 3; 0 = no limit); the PO team decides the number, and an admin can change it.
- `S012__coin_settings.sql`: the Coins settings, `coin.block_points = 100`, `coin.block_coins = 10`, `coin.schedule = "MONTHLY"` and `coin.wallets_enabled = false` (phase 2: automatic conversion, wallets off until the WSO2 Coins API exists); the PO team changes the rate and schedule, an admin the switch.
- `S013__engagement_sync_settings.sql`: the Community Management engagement sync (V025), `engagement.sync_enabled = false`, `engagement.schedule = "0 */2 * * *"` and `engagement.daily_call_budget = 450` (calls per UTC day across runs).
- `S014__coin_caps.sql`: the Coins safety caps for the automatic conversion (V026, ADR-048), `coin.max_coins_per_person = 500` (one person in one run) and `coin.max_coins_per_run = 50000` (one period, everyone together); points above a cap carry over. Admins change them.
- `S016__reach_settings.sql`: post reach (V028) and the reports, `reach.enabled = false`, `reach.schedule = "30 3 * * *"`, `reach.window_days = 30` (in-app shares of the last N days are measured) and `dashboards.min_group_size = 5` (a location with fewer people is merged into "Other"). Admins change them.

## Rules

- Never edit an applied seed: the runner compares checksums and stops. To change a seeded value, add a new seed (S011 and up) that sets it, and a migration when databases that already hold the old value need it too (S008 with V016 is the example).
- Every insert is `ON CONFLICT DO NOTHING`, so an insert never overwrites a value an admin changed. S008 and S009 are updates: each changes its setting only while it holds the old value (`token_grace_days` 5, `top_scope` WEEK), whether that value was the seed's or an admin's.
- Seeds apply after all migrations, in number order, each in its own transaction. The runner (`../main.bal`) lists them from `seedDir`.
- Files must match `S###__snake_name.sql`.
