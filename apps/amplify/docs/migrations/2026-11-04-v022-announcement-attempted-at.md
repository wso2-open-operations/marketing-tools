# V022: attempt marker for Novera announcements (2026-11-04)

Script: `amplify-database/migrations/V022__announcement_attempted_at.sql`, test `amplify-database/tests/v022_test.bal`.

## Context

Novera does not dedupe on `Idempotency-Key` (owner decision 2026-11-03). If Amplify's call to Novera succeeds but the
answer is lost, or the save after it fails, a plain retry would send the same campaign card twice. Amplify therefore
needs to remember that it has attempted a send before it calls Novera.

## What changed

- `announcement.attempted_at timestamptz` (nullable) is added. amplify-jobs sets it in its own transaction before it
  calls Novera, and clears it again only when the call definitely sent nothing.
- A queued row that still carries the marker on a later run may already have reached Novera. The worker marks it
  `Delivery unknown` for a person to check instead of sending again. The admin retry clears the marker.
- `announcement_v` is dropped and recreated with `a.*`, so it picks up the new column. `CREATE OR REPLACE` cannot
  insert a column before `status`, so the view has to be recreated.

## Changed files

- `amplify-database/migrations/V022__announcement_attempted_at.sql` (new)
- `amplify-database/tests/v022_test.bal` (new)
- `amplify-jobs` announcement flow (sets and clears the marker)
- `amplify-api` admin retry (clears the marker)

## Verify

```sql
SELECT version FROM public.schema_version WHERE version = 'V022__announcement_attempted_at';
SELECT column_name FROM information_schema.columns
WHERE table_name = 'announcement' AND column_name = 'attempted_at';
```

## Revert

Forward-only: never edit V022 once applied. To undo, add a new `V0NN__` script that recreates `announcement_v`
without `attempted_at` (the view has to be dropped and recreated), then drops the column. Check first that no
announcement row is in `Delivery unknown` state, because the marker is the only record of those attempts.
