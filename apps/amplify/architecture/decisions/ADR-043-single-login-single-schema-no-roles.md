# ADR-043: One login user, one schema, no database roles

- **Status:** Accepted (2026-11-02)
- **Date:** 2026-11-02
- **Source:** the DBA gives Amplify one database user per environment (staging `amplify_stg_user`, production its own name) and one schema, with no CREATEROLE, and would not grant any role to that user
- **Related:** ADR-005 (no cross-context FKs, still true), ADR-027 (one Docker context per component), ADR-040 (erasure function)

## Context

The first design used one schema per bounded context and four login roles (`amplify_migrate`, `amplify_api`, `amplify_jobs`, `amplify_readonly`) so the database itself separated what the API, the worker and a reader could do. The shared database allows one user and one schema, and the DBA would not create the roles or let the login switch into them (`GRANT ... TO amplify_stg_user WITH SET TRUE` was refused). A design that depends on roles can't be deployed there, and the same refusal would repeat in production.

## Decision

1. **One schema.** Every table, view and function lives in the schema named after the login user. Names carry the old schema as a prefix: `sharing.share_request` is `sharing_share_request`. A name that already starts with its context isn't doubled (`audit_log`, `campaign`, `campaign_tag`). Scripts and application SQL name no schema; the `search_path` does.
2. **No roles.** No script creates, grants to or switches to a role. The login user owns every object and every component (api, jobs, the migrate runner) connects as it. The scripts contain no `GRANT` to a role and no `SET LOCAL ROLE`. V017 (narrow token grants) was removed because it only held grants. V021 (added after this ADR was accepted) adds the immutability triggers below.
3. **The migrate runner** connects as the login user and puts the schema first on the `search_path` (`dbSchema`, default the user name). V001 checks that the schema exists and that `citext` and `pg_trgm` are installed; it creates nothing else. `checks/d3_single_user.sql` lists what the DBA still has to do before the first run.
4. **Services** connect as the login user. `store:newClient` takes `dbSchema` and sends the `search_path` and `idle_in_transaction_session_timeout=30000` as the PostgreSQL startup options in the JDBC URL (`?options=-c search_path=<schema>,public ...`). The `PGOPTIONS` environment variable works for `psql` but the Java driver ignores it, which we tested.
5. **SECURITY DEFINER functions** keep `SET search_path FROM CURRENT`, which captures the runner's `<schema>, public, pg_temp`, so no function hard-codes a schema. With one identity they no longer elevate anything; they stay as the one audited way to run partition upkeep and erase an employee.
6. **Forward-only, one exception.** The 19 migrations and 10 seeds were rewritten for this design and the dev database was wiped and reinstalled (2026-11-02). Nothing had been applied to staging or production. Applied scripts are not edited from here.

## Consequences

- One set of scripts serves staging and production; only the login user, the schema name and the password differ. Nothing in the deployment needs a DBA action beyond the user, the schema and two extensions.
- **The database no longer separates components.** The API, the jobs worker and any reader share one identity. These protections are gone, and the code paths now carry them alone:
  - the API can't run the partition upkeep or `recognition_rebuild`;
  - the API and jobs can't rewrite or delete ledger rows or audit rows (settlement columns only);
  - jobs can't write settings, campaigns or identities;
  - `amplify_readonly` could not read tokens, member URNs or commentary (the phase 2 reader);
  - the narrowed token grants of ADR-040.
  A bug or a compromised component can now do what any component can. The threat model and the deployment security checklist need this recorded.
- `session_user` in the V018 erasure audit row is always the login; the row's `calledBy` still records the actor the API names.
- Audit `entity_type` values follow the new table names (`sharing_share_request`, not `sharing.share_request`).
- Partitions share one namespace with every table; their names (`provider_token_pYYYYMMDD`, `audit_log_pYYYYMM`) don't collide.
- A reader for phase 2 reports can't be a separate database identity. It would need a read replica, a separate schema of views, or another user the DBA agrees to create.

## Compensating controls

Roles are not needed to protect the two append-only tables. **V021** adds row triggers: `scoring_points_ledger` may only change its settlement columns (`status`, `status_changed_at`, `paid_at`, `coin_reference`) and is never deleted; `audit_log` is never changed or deleted (retention drops whole partitions, which fire no row trigger). They hold for every component and for the owner. They do not stop a person who has the login's password and drops the trigger, and they leave `TRUNCATE` alone. The one local fixture that clears ledger rows (`scripts/load/seed-load.sql`) uses the superuser-only `session_replication_role` bypass.

Still open: the other limits in the list above (who may call the upkeep and rebuild functions, narrowed token access, a phase 2 reader) have no database enforcement and live in code.

## Links

- [V001__schema_and_extensions.sql](../../amplify-database/migrations/V001__schema_and_extensions.sql)
- [d3_single_user.sql](../../amplify-database/checks/d3_single_user.sql)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md)
