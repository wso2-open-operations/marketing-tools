# V012: recognition writers serialized, upkeep lock waits bounded (2026-10-17)

Script: `amplify-database/migrations/V012__recognition_lock_maintenance_timeout.sql`. Found in the deep
review of jobs/db/infra (`docs/reviews/2026-10-26-code-review-backend.md`, findings D1 and D2).

## Context

1. **Concurrent ledger appends left stale ranks.** `recognition.apply_ledger_entry` upserts the employee's
   standing row and then `recognition.rerank` re-ranks the whole period in one `UPDATE`. The ranking CTE
   reads the statement snapshot, so when the jobs score pass and an amplify-api PO decision commit at the
   same time, each ranks without the other's row. The later commit keeps ranks computed without the
   earlier one's points (two people at rank 1, wrong `points_to_top_n`) until the next append, and the two
   transactions can deadlock on opposite row-lock orders. Reproduced by
   `testConcurrentLedgerAppendsKeepRanksConsistent` (fails on V011, passes on V012).
2. **Partition upkeep could stall the app.** `CREATE TABLE ... PARTITION OF` (every day: a new token day
   and, monthly, an audit month) and `DETACH PARTITION` take `ACCESS EXCLUSIVE` on the parent
   (`connection.provider_token`, `audit.audit_log`) and hold it until the whole upkeep commits. Behind any
   long reader that request queued forever, and every audit insert and token write in amplify-api queued
   behind it. Reproduced by `testUpkeepGivesUpOnALockInsteadOfQueueing` (V011: waits until
   `statement_timeout`; V012: fails with `lock timeout` after 5 s).

## What changed

- `recognition.rerank`, `recognition.apply_ledger_entry`, `recognition.rebuild`: `CREATE OR REPLACE` with
  the same bodies plus `pg_advisory_xact_lock(1634561133)` first, so recognition writers run one at a time.
  The lock lasts to the end of the ledger transaction (one insert, one upsert, one UPDATE).
- `messaging.run_partition_maintenance`: same body plus `pg_advisory_xact_lock(1634561134)`, so two
  concurrent upkeep calls don't race on the same `CREATE TABLE`.
- `ALTER FUNCTION ... SET lock_timeout = '5s'` on `run_partition_maintenance`, `create_token_partitions`,
  `drop_expired_token_partitions`, `create_audit_partitions`, `drop_old_audit_partitions`,
  `purge_done_outbox`. A blocked upkeep now fails with SQLSTATE `55P03`; amplify-jobs answers 500, the
  scheduler retries (2 retries, 60 s apart), and partitions already exist 7 days / 3 months ahead.

Signatures, owner (`amplify_migrate`), `SECURITY DEFINER`/`INVOKER`, pinned `search_path` and grants are
unchanged (`CREATE OR REPLACE` and `ALTER FUNCTION ... SET` keep them). No callers change.

## Changed files

- `amplify-database/migrations/V012__recognition_lock_maintenance_timeout.sql` (new)
- `amplify-database/tests/invariants_test.bal` (new: the two regression tests above, plus constraint,
  grant, definer and partition-bound invariants)
- `amplify-database/migrations/README.md`, `docs/migrations/README.md` (script list)

## Verify

```sql
SELECT version FROM public.schema_version WHERE version = 'V012__recognition_lock_maintenance_timeout';
SELECT p.proname, p.proconfig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('messaging', 'connection', 'audit') AND p.proconfig::text LIKE '%lock_timeout%';
```

## Revert

Forward-only: never edit or delete V012 once applied. To undo, add a new `V0NN__` script that
`CREATE OR REPLACE`s the four functions with their V010/V009 bodies (copy them from those files) and runs
`ALTER FUNCTION <each of the six> RESET lock_timeout;`. Reverting brings both problems back.
