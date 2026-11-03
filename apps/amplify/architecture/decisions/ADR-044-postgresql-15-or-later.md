# ADR-044: PostgreSQL 15 or later; local and tests pin 17.11

Status: Accepted (2026-11-02)

## Context

The design assumed PostgreSQL 18 for two features: the native `uuidv7()` (column default of every `uuid` key) and
`RETURNING old.*` (audit "before" values). Staging runs PostgreSQL 17.11, so V002 failed there with
`function uuidv7() does not exist`.

## Decision

- **Floor is 15.** The runner refuses older servers (`security_invoker` views need 15). PostgreSQL 18 still works.
- **`uuidv7()`:** V001 creates `public.uuidv7()` when the server has no native `pg_catalog.uuidv7()`; on 18 it does
  nothing. The function is a v4 random uuid with the Unix time in milliseconds in the first 48 bits and version 7.
  Ids sort by creation across milliseconds; two ids made in one millisecond are ordered randomly. Tables bind the
  function by OID, so upgrading the server to 18 leaves existing tables working.
- **`RETURNING old.*`:** the six repository updates that fill audit "before" values (campaign, connection, sharing,
  scoring, external sharing, settings) use `WITH prev AS (SELECT ... FOR UPDATE) UPDATE ... FROM prev RETURNING
  prev.old_*`. The row is read and locked in the statement that changes it, so the version check and the audit
  values stay atomic.
- **Local and tests:** Compose and the test scripts pin `postgres:17` (17.11, by digest). The data volumes mount at
  `/var/lib/postgresql/data`; an existing 18 volume must be recreated (`make down`, `make up`). The database
  integration workflow (`amplify-database-integration.yml`) still runs on 18 only; adding 17, the staging version, is a
  follow-up.

## Consequences

Hand-applied V001 needs the schema owner to run it (it creates a function in `public`). Phase 1 documents that
required PostgreSQL 18 are superseded by this ADR where they conflict.
