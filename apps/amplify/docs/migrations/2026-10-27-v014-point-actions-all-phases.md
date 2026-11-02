# V014: every action the points table prices (2026-10-27)

Script: `amplify-database/migrations/V014__point_actions_all_phases.sql`, with seed
`amplify-database/seed/S006__point_rules_all_values.sql` (and S007, below). Source of the values:
`docs/requirements/point-values.md`.

## Context

The business's points table prices more actions than the schema could hold. `scoring.point_rule` and
`scoring.points_ledger` only accepted REPOST, REPOST_COMMENTARY, SHARE, SHARE_COMMENTARY, OWN_POST and
OWN_POST_AMPLIFIED, so likes, comments and the Amplify Challenge had no place to land when their phase
arrived. Adding them later would have meant a schema change in the middle of a phase.

## What changed

- `point_rule_action_check` and `points_ledger_action_check` are dropped and re-added with four more actions:
  REACTION (a like), COMMENT, CHALLENGE_ENTRY and CHALLENGE_WINNER.
- `sharing.engagement.action` is unchanged. It grows when comments and reactions are synced.
- Nothing awards the new actions yet. Likes and comments need Community Management (phase 4); Challenge entry
  and winner are PO adjustments until the Challenge has its own flow.
- S006 prices them, effective 2026-10-19 like S005: REACTION 1, COMMENT 1, CHALLENGE_ENTRY 10,
  CHALLENGE_WINNER 25. It also adds SHARE_COMMENTARY 5, which S005 left out; without that row S001's 12
  would still be in force for that action.
- S007 (`S007__top_scope_setting.sql`) seeds `leaderboard.top_scope = "WEEK"` (ADR-037). It has no schema
  change behind it and is listed here only because it lands in the same release.

## Changed files

- `amplify-database/migrations/V014__point_actions_all_phases.sql` (new)
- `amplify-database/seed/S005__point_rules_pilot.sql`, `S006__point_rules_all_values.sql`,
  `S007__top_scope_setting.sql` (new)
- `amplify-database/tests/v014_test.bal` (new: every action has a rule in force with the expected points, both
  constraints list the new actions, an unpriced action is refused)
- `docs/migrations/README.md` (script list)

## Verify

```sql
SELECT version FROM public.schema_version WHERE version = 'V014__point_actions_all_phases';
SELECT DISTINCT ON (action) action, points, effective_from FROM scoring.point_rule
WHERE effective_from <= now() ORDER BY action, effective_from DESC;
```

Ten actions come back: REPOST 2, SHARE 2, REPOST_COMMENTARY 5, SHARE_COMMENTARY 5, OWN_POST 10,
OWN_POST_AMPLIFIED 25, REACTION 1, COMMENT 1, CHALLENGE_ENTRY 10, CHALLENGE_WINNER 25.

## Revert

Forward-only: never edit or delete V014 once applied. To undo, add a new `V0NN__` script that restores the
two CHECK constraints with the six original actions. It fails while any `point_rule` or `points_ledger` row
uses one of the four new actions (S006 inserts four rule rows), so remove those rows first with a reason in
the change record.
