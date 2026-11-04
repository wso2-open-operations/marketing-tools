# CLAUDE.md — amplify-database

## Overview
Amplify DB Migrate: Choreo Manual Task / Compose one-shot. Applies `migrations/` (`V###`) then `seed/` (`S###`) in order, one transaction per script, records each in `public.schema_version` (checksum), sets app role passwords from secrets, exits. Rerun is a no-op; a changed applied script stops the run (forward-only). `dryRun = true` only lists.

## Layout
`main.bal` (runner) · `migrations/` (`V###__snake_name.sql`) · `seed/` (`S###__snake_name.sql`, idempotent `ON CONFLICT DO NOTHING`) · `checks/` (one-off checks such as `d2_extensions.sql`) · `tests/` (unit + `integration` group).

## Commands
`bal build` · `bal test` · `bal run` (from this folder). Integration tests run against the Postgres image pinned in `compose.yaml`: see `docs/migrations/README.md`.

## DB connections
Connects as the one Amplify login user (`dbUser`, staging `amplify_stg_user`) and puts its schema first on the `search_path` (`dbSchema`, default the user name), so no script names a schema and every table is `<context>_<name>` (ADR-043). There are no roles: that user owns every object and every component connects as it. Secret: `dbPassword`. V001 checks the schema and the two extensions exist and installs `uuidv7()` on servers older than 18 (ADR-044). TLS: `dbSslMode` defaults to `VERIFY_FULL` with `dbSslRootCert` (CA PEM path, Choreo file mount via `BAL_CONFIG_VAR_DBSSLROOTCERT`), same as api/jobs; start-up warns when a remote host isn't verified; Compose and the IT set `DISABLE`.

## Key patterns
Never edit an applied migration. Every `.sql` carries the Apache-2.0 header. No `?` in scripts (the JDBC driver reads it as a bind marker). Enums are `text` + `CHECK`. Views are `security_invoker`. Maintenance functions are `SECURITY DEFINER` with a pinned `search_path` and `format(%I)`.
