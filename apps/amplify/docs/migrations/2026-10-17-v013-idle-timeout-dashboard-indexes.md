# V013: idle-in-transaction limit for the app roles, dashboard indexes, lock order on the SQL side (2026-10-17)

Script: `amplify-database/migrations/V013__idle_timeout_dashboard_indexes.sql`. Round 2 of the deep
review (`docs/reviews/2026-10-17-round2-handoffs.md`): domain review H-3b and H-4, round 2 items 9, 11 and
12.6, and the R-13 write-up (`docs/reviews/2026-10-17-r13-transaction-race.md`).

## Context

1. **Sessions left idle in a transaction hold their locks.** On Ballerina 2201.13.x concurrent
   `transaction` blocks can report a commit that never happened and leave the session `idle in
   transaction` (R-13, ballerina-lang #44737). amplify_domain now runs every transaction through one
   process-wide gate, but a role-level limit is the backstop for anything that still leaks: PostgreSQL ends
   the session and releases its locks. 30 s, as the R-13 write-up recommends; the recognition lock holders
   keep their tighter transaction-local 5 s.
2. **Dashboard tiles scan whole tables.** Tile 4 (`scoring.pointsByAction`, points this month) and the tile 7
   breakdown by failure reason (`sharing.shareHealth`) filter on a time column with no index.
3. **Two advisory locks guard recognition writes** (app key `4242101`, SQL key `1634561133`), always in that
   order. V012 can't be edited, so the order is documented on its functions with `COMMENT ON FUNCTION`.

## What changed

- `ALTER ROLE amplify_api SET idle_in_transaction_session_timeout = '30s'` and the same for `amplify_jobs`
  (runs as the bootstrap admin, the roles' creator, before `SET LOCAL ROLE amplify_migrate`). New sessions
  pick it up; pools recycle connections within `maxConnectionLifeTime` (30 min).
- `points_ledger_created_at_idx` on `scoring.points_ledger (created_at)`.
- `share_request_failed_at_idx` on `sharing.share_request (failed_at) WHERE failed_at IS NOT NULL`.
- `COMMENT ON FUNCTION` for `recognition.apply_ledger_entry(varchar, int)`, `recognition.rerank(text, int)`,
  `recognition.rebuild(int)`, naming the lock order.

Plain `CREATE INDEX` (the runner wraps each script in a transaction, so `CONCURRENTLY` isn't possible). Both
tables are small in phase 1, so the build takes milliseconds; on a large table this would need its own
out-of-band `CREATE INDEX CONCURRENTLY`.

## Which indexes, and why only two (EXPLAIN)

Domain review H-4 proposed four indexes. Each was checked with `EXPLAIN` on a copy of the migrated IT
database seeded with a year of activity: 30,000 ledger rows, 4,000 engagements, 6,000 share requests
(4,000 published, 1,200 failed) and 4,000 external shares, spread over 365 days, then `ANALYZE`. The time
bounds are `now()`-based stand-ins for the bound parameters (the driver's first executions get custom plans
with the real values). Only the indexes the planner picked are in V013:

| Proposed index | Query | Used | In V013 |
|---|---|---|---|
| `points_ledger (created_at)` | tile 4 `pointsByAction` | yes, bitmap index scan, cost 1207 -> 457 | yes |
| `share_request (failed_at) WHERE failed_at IS NOT NULL` | tile 7 failures by reason | yes, bitmap index scan, cost 233 -> 73 | yes |
| `share_request (published_at) WHERE published_at IS NOT NULL` | tile 7 totals | no: `count(*) FILTER (...)` over the whole view | no |
| `external_share (decided_at) WHERE decided_at IS NOT NULL` | tile 2 `reviewThroughput` | no: `count(*) FILTER (...)` and a percentile over the whole table | no |

The tile 2 and tile 7 totals queries aggregate every row with `FILTER`, so no index can help them as
written. If they grow slow, rewrite them with a `WHERE` on the window (and then add the index); that is a
query change, not a migration.

Before (no new indexes):

```text
=== tile 4 pointsByAction (month)
                                                                  QUERY PLAN                                                                  
----------------------------------------------------------------------------------------------------------------------------------------------
 HashAggregate  (cost=1207.32..1210.82 rows=200 width=40)
   Group Key: CASE WHEN (source_type = ANY ('{ADJUSTMENT,REVERSAL}'::text[])) THEN source_type ELSE action END
   ->  Seq Scan on points_ledger  (cost=0.00..1196.62 rows=1426 width=36)
         Filter: ((created_at >= date_trunc('month'::text, now())) AND (created_at < (date_trunc('month'::text, now()) + '1 mon'::interval)))
(4 rows)

=== tile 7 shareHealth totals
                                 QUERY PLAN                                 
----------------------------------------------------------------------------
 Aggregate  (cost=382.00..382.02 rows=1 width=12)
   ->  Seq Scan on share_request sr  (cost=0.00..187.00 rows=6000 width=24)
(2 rows)

=== tile 7 shareHealth by reason
                                   QUERY PLAN                                   
--------------------------------------------------------------------------------
 GroupAggregate  (cost=232.64..232.86 rows=1 width=22)
   Group Key: sr.failure_reason
   ->  Sort  (cost=232.64..232.71 rows=27 width=18)
         Sort Key: sr.failure_reason
         ->  Seq Scan on share_request sr  (cost=0.00..232.00 rows=27 width=18)
               Filter: (failed_at >= (now() - '7 days'::interval))
(6 rows)

=== tile 2 reviewThroughput
                                QUERY PLAN                                
--------------------------------------------------------------------------
 Aggregate  (cost=369.07..369.09 rows=1 width=28)
   ->  Seq Scan on external_share  (cost=0.00..149.01 rows=4001 width=33)
(2 rows)

```

After (all four candidate indexes present; the planner used two):

```text
=== tile 4 pointsByAction (month)
                                                                       QUERY PLAN                                                                       
--------------------------------------------------------------------------------------------------------------------------------------------------------
 HashAggregate  (cost=456.53..460.03 rows=200 width=40)
   Group Key: CASE WHEN (source_type = ANY ('{ADJUSTMENT,REVERSAL}'::text[])) THEN source_type ELSE action END
   ->  Bitmap Heap Scan on points_ledger  (cost=34.95..445.82 rows=1429 width=36)
         Recheck Cond: ((created_at >= date_trunc('month'::text, now())) AND (created_at < (date_trunc('month'::text, now()) + '1 mon'::interval)))
         ->  Bitmap Index Scan on points_ledger_created_at_idx  (cost=0.00..34.59 rows=1429 width=0)
               Index Cond: ((created_at >= date_trunc('month'::text, now())) AND (created_at < (date_trunc('month'::text, now()) + '1 mon'::interval)))
(6 rows)

=== tile 7 shareHealth totals
                                 QUERY PLAN                                 
----------------------------------------------------------------------------
 Aggregate  (cost=382.00..382.02 rows=1 width=12)
   ->  Seq Scan on share_request sr  (cost=0.00..187.00 rows=6000 width=24)
(2 rows)

=== tile 7 shareHealth by reason
                                              QUERY PLAN                                               
-------------------------------------------------------------------------------------------------------
 GroupAggregate  (cost=72.33..72.55 rows=1 width=22)
   Group Key: sr.failure_reason
   ->  Sort  (cost=72.33..72.40 rows=27 width=18)
         Sort Key: sr.failure_reason
         ->  Bitmap Heap Scan on share_request sr  (cost=4.49..71.69 rows=27 width=18)
               Recheck Cond: (failed_at >= (now() - '7 days'::interval))
               ->  Bitmap Index Scan on share_request_failed_at_idx  (cost=0.00..4.48 rows=27 width=0)
                     Index Cond: (failed_at >= (now() - '7 days'::interval))
(8 rows)

=== tile 2 reviewThroughput
                                QUERY PLAN                                
--------------------------------------------------------------------------
 Aggregate  (cost=369.07..369.09 rows=1 width=28)
   ->  Seq Scan on external_share  (cost=0.00..149.01 rows=4001 width=33)
(2 rows)

```

## Changed files

- `amplify-database/migrations/V013__idle_timeout_dashboard_indexes.sql` (new)
- `amplify-database/tests/v013_test.bal` (new: role settings, both indexes, and the SQL half of the
  lock-order check: no function takes `4242101`, the three recognition functions take `1634561133` and
  document the order)
- `amplify-database/migrations/README.md`, `docs/migrations/README.md` (script list)

## Verify

```sql
SELECT r.rolname, s.setconfig FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
WHERE r.rolname IN ('amplify_api', 'amplify_jobs');
SELECT indexname, indexdef FROM pg_indexes
WHERE indexname IN ('points_ledger_created_at_idx', 'share_request_failed_at_idx');
SELECT obj_description('recognition.apply_ledger_entry(varchar, int)'::regprocedure, 'pg_proc');
```

## Revert

Forward-only: never edit V013 once applied. To undo, add a new `V0NN__` script with
`ALTER ROLE amplify_api RESET idle_in_transaction_session_timeout;` (same for `amplify_jobs`, as the bootstrap
admin), then under `SET LOCAL ROLE amplify_migrate`: `DROP INDEX scoring.points_ledger_created_at_idx;`,
`DROP INDEX sharing.share_request_failed_at_idx;` and `COMMENT ON FUNCTION ... IS NULL;` for the three
functions. Dropping the timeout brings back the unbounded lock hold after a leaked transaction.
