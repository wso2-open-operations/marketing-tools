# One login, one schema, no roles (2026-11-03)

Scripts: `amplify-database/migrations/V001__schema_and_extensions.sql` through `V021__immutable_ledger_and_audit.sql`.
Decision: ADR-043 (and ADR-044 for PostgreSQL 15 or later).

## What changed

- V001 is replaced (`V001__schemas_roles.sql` is gone). It creates no schema and no role: it checks the schema, the
  extensions and `uuidv7()`.
- V002-V020 are rewritten in place: no schema prefix in any statement, tables named `<context>_<name>`, no `GRANT`,
  no `SET ROLE`, no role-based `ALTER ROLE`.
- V021 is new: triggers that keep the points ledger and the audit log from being rewritten.
- The runner connects as the one login, not a bootstrap admin, and sets the `search_path` itself (`dbSchema`).

## Fresh database required

The checksums of V001-V020 changed, so the runner stops with a checksum error on any database migrated under the
old design (it never edits an applied script). There is no in-place upgrade:

1. Environments that never ran the old scripts (local, CI, the first staging run on the DBA login): run the
   migrate component. That is all.
2. A database that already holds the old schemas: take a backup, drop the old schemas and `public.schema_version`
   (or use a new database), then run the migrate component. This loses every campaign, share and point. It is fine
   before the pilot; once real posts exist, ask first.

## Revert

Forward-only, as always. To go back to the role design, restore the backup, redeploy the previous release of
`amplify-database` and the components, and set the per-component `DBUSER` and role passwords again. There is no
down script. Locally: `make down && make up`.

## Verify

`make seed` (local) or the migrate component's log ending with `Migration run done`; then
`amplify-database/checks/d3_single_user.sql` (one login, no extra roles) and `bal test` in `amplify-database`.
