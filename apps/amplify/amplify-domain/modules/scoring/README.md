# amplify_domain.scoring

Core context: point rules, the append-only points ledger and the automatic Coins conversion (ADR-048). Tables: `scoring_point_rule`, `scoring_points_ledger`, `scoring_coin_wallet`, `scoring_coin_run`, `scoring_coin_issue` (V026). Points are `HELD` until a conversion pays them (`PAID`, final).

## Types and ports

File: `modules/scoring/types.bal`.

- `PointRule` (versioned by `effectiveFrom`, one row per action per effective time), `EngagementFact` (from `EngagementRecorded`), `ExternalShareFact`, `LedgerAppend` (a ledger row plus its event).
- `LedgerRepository` port: `append`, `findByReference`, `findReversalOf`, `updateSettlement`. There is no update of facts, only `append` (`ON CONFLICT DO NOTHING`) and the settlement columns.
- `PointRuleRepository` port: `all`, `insert`.
- The ledger row type `types:LedgerEntry` and the `AMP-`, `ADJ-`, `REV-` references are in `amplify_common.types`.

## Service and use cases

File: `modules/scoring/service.bal`.

- Pure rules: `ruleInForce` (latest `effectiveFrom` not after the time), `newRuleVersion` (cannot be backdated, cannot repeat `(action, effectiveFrom)`), `awardForEngagement`, `awardForExternalShare`, `ownPostNet`, `amplifiedTopUp` (`OWN_POST_AMPLIFIED` points minus the net `OWN_POST` points on the ledger), `reversal` (a reason is required, a row is reversed once, a reversal cannot be reversed), `adjustment`.
- Use cases: `setPointRule`, `appendAward` (re-running the same fact is a no-op), `reverseEntry`, `adjustPoints`.

## Coins conversion

File: `modules/scoring/coins.bal` (rules, port, use cases) and `modules/scoring/coin_repository.bal` (PostgreSQL).

- Pure rules: `coinPeriod` (`2026-12` monthly, ISO week `2026-W49` weekly, `2026-12-01` daily, UTC), `planConversion` (carry in + the HELD rows not yet taken, reversals negative, in whole blocks within the person cap and what is left of the run cap; the rest carries out), `retryAt` (15 min doubling, at most a day), `isConvertible` (HELD and untaken: the seam for pre-coin verification, which flags rows action required), `changeSettlement` (`PAID` only to a HELD row and naming its `CNV-` reference; a PAID row is final, `ALREADY_PAID`), `maskWallet`, `sameAmount`.
- Ports: `CoinRepository` (`openRun`, `openIssues`, `issuesOf`, `candidates`, `committedCoins`, `transferTaken`, `begin`, `skipNoWallet`, `markSent`, `markFailed`, `markUnknown`, `finishRun`) and `CoinWalletRepository` (`walletOf`, `saveWallet`). PostgreSQL: `PgCoinRepository`, `PgCoinWalletRepository`; each multi-statement write runs through `store:inTransaction` with an audit row (`CoinsIssued`, `CoinIssueFailed`, `CoinIssueUnknown`, `CoinWalletCaptured` with the masked address).
- Use cases: `convertCoins(repo, port, settings, options, now)` (the jobs' `POST /coins/convert`): reconcile open issues of earlier runs (search the Coins ledger by master wallet, recipient, amount and time; one match SENT, none FAILED, more UNKNOWN `RECONCILE_AMBIGUOUS`), plan, check the master balance covers the whole run (else `STOPPED INSUFFICIENT_BALANCE`, nothing sent), record wallet-less employees `SKIPPED_NO_WALLET`, then per employee `begin` (issue PENDING + rows tagged) -> transfer -> `markSent` (rows PAID). A refusal is `markFailed` (rows untagged, retried in the period after `retryAt`, or by the next period); no clear answer is `markUnknown` and stops the run. `captureWallet(repo, port, employeeId, userAssertion, ...)`: the default wallet, else the first.
- Queries: `coinSummaryOf` (Coins received, carry, captured wallet) for `GET /me/points`; `timelineOf` (ledger rows and SENT / in-progress conversions, `CoinConversion`, in one paged newest-first list) for the history.

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

`amplify_common.types`, `amplify_common.events`, `amplify_common.coins` (the Coins port), `amplify_common.resilience` (log hygiene), `amplify_domain.store`.

## Does not do

- No reads of the sharing or external-sharing tables. Facts come in as `EngagementFact` and `ExternalShareFact`.
- No HTTP: the Coins service is reached only through `coins:CoinsPort`, which the caller passes in.
- No update or delete of a ledger fact. Corrections are new `ADJ-` and `REV-` rows.

## Tests

`modules/scoring/tests/scoring_test.bal` (in-memory ledger), `modules/scoring/tests/coins_test.bal` (the conversion on an in-memory repository and Coins service). `tests/integration_coins_test.bal` runs the Coins repositories against PostgreSQL. The package `tests/lock_order_test.bal` checks the recognition lock order. Integration tests are in the package `tests/` directory (see the component README).
