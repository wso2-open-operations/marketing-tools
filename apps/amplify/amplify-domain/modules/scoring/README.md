# amplify_domain.scoring

Core context: point rules and the append-only points ledger. Tables: `scoring_point_rule`, `scoring_points_ledger`. Points are `HELD`; phase 1 issues no Coins.

## Types and ports

File: `modules/scoring/types.bal`.

- `PointRule` (versioned by `effectiveFrom`, one row per action per effective time), `EngagementFact` (from `EngagementRecorded`), `ExternalShareFact`, `LedgerAppend` (a ledger row plus its event).
- `LedgerRepository` port: `append`, `findByReference`, `findReversalOf`, `updateSettlement`. There is no update of facts, only `append` (`ON CONFLICT DO NOTHING`) and the settlement columns.
- `PointRuleRepository` port: `all`, `insert`.
- The ledger row type `types:LedgerEntry` and the `AMP-`, `ADJ-`, `REV-` references are in `amplify_common.types`.

## Service and use cases

File: `modules/scoring/service.bal`.

- Pure rules: `ruleInForce` (latest `effectiveFrom` not after the time), `newRuleVersion` (cannot be backdated, cannot repeat `(action, effectiveFrom)`), `awardForEngagement`, `awardForExternalShare`, `ownPostNet`, `amplifiedTopUp` (`OWN_POST_AMPLIFIED` points minus the net `OWN_POST` points on the ledger), `reversal` (a reason is required, a row is reversed once, a reversal cannot be reversed), `adjustment`, `changeSettlement` (`PAID` is refused in phase 1).
- Use cases: `setPointRule`, `appendAward` (re-running the same fact is a no-op), `reverseEntry`, `adjustPoints`.

## Events

File: `modules/scoring/events.bal`. `pointsChangedEvent(entry)` wraps `events:newPointsChanged`.

## Repository and tables

File: `modules/scoring/repository.bal`.

- `PgLedgerRepository(db, actor, topN)` and `PgPointRuleRepository(db, actor)`.
- `appendInTransaction(db, actor, append, ...)` is the transactional append other modules call. It takes `store:lockRecognition` first, then calls the SQL function `recognition_apply_ledger_entry` (B12), so the ledger and the leaderboard tables change together.

## Queries

File: `modules/scoring/queries.bal`. `historyOf` (a `LedgerPage`), `pointsByAction` (`ActionPoints`), `actionRequiredCount`, `recentCorrections`, `DASHBOARD_ACTIONS`.

## Config

None. `scoring.bal` holds `MODULE`.

## Depends on

`amplify_common.types`, `amplify_common.events`, `amplify_domain.store`.

## Does not do

- No reads of the sharing or external-sharing tables. Facts come in as `EngagementFact` and `ExternalShareFact`.
- No Coin issue and no payment (phase 2).
- No update or delete of a ledger fact. Corrections are new `ADJ-` and `REV-` rows.

## Tests

`modules/scoring/tests/scoring_test.bal` (in-memory ledger). The package `tests/lock_order_test.bal` checks the recognition lock order. Integration tests are in the package `tests/` directory (see the component README).
