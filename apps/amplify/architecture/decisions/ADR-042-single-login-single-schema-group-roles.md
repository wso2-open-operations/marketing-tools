# ADR-042: One login user, one schema, group roles for access

- **Status:** Superseded by ADR-043 (2026-11-02). Kept for history: the four group roles described here were dropped the same day.
- **Date:** 2026-11-02
- **Source:** the DBA gives Amplify one database user per environment (staging `amplify_stg_user`, production its own name) and one schema, and no CREATEROLE
- **Related:** ADR-005 (no cross-context FKs, still true), ADR-027 (one Docker context per component)

## Context

Until now each bounded context had its own schema and each component its own login (`amplify_migrate`, `amplify_api`, `amplify_jobs`, `amplify_readonly`). The shared database gives us one user and one schema named after it. We can't create schemas or logins, and role-level settings (`ALTER ROLE ... SET`) need CREATEROLE.

## Decision

1. **One schema.** Every table, view and function lives in the schema named after the login user. Names carry the old schema as a prefix: `sharing.share_request` is `sharing_share_request`. A name that already starts with its context isn't doubled (`audit_log`, `campaign`, `campaign_tag`). Scripts and application SQL name no schema; they rely on the `search_path`.
2. **Four NOLOGIN group roles stay.** The DBA creates `amplify_migrate`, `amplify_api`, `amplify_jobs`, `amplify_readonly` and grants each to the login user `WITH SET TRUE, INHERIT FALSE`. The login user has no table privileges of its own; it can only act through a role. All V002+ grants are unchanged.
3. **The migrate runner** connects as the login user, puts the schema first on the `search_path` (`dbSchema`, default the user name) and runs each script as `SET LOCAL ROLE amplify_migrate`, so `amplify_migrate` owns every object. V001 checks the DBA's setup and grants the roles `USAGE` (and `CREATE` for `amplify_migrate`) on the schema; it creates no roles and no schema. `checks/d3_single_user_roles.sql` lists what is missing before the first run.
4. **Services connect as the login user and switch role per connection** through the PostgreSQL startup options, set in code: `store:newClient` appends `?options=-c role=<dbRole> -c search_path=<dbSchema>,public -c idle_in_transaction_session_timeout=30000` to the JDBC database name (the Ballerina client has no other hook; the `PGOPTIONS` environment variable works for `psql` but the Java driver ignores it, which we tested). Per component the settings are `dbRole` (`amplify_api`, `amplify_jobs`) and `dbSchema` (empty = the login's name). The old per-role passwords and the runner's password step are gone. The 30 s idle timeout moved here from V013 because a role-level setting never applies under `SET ROLE`.
5. **SECURITY DEFINER functions** pin `SET search_path FROM CURRENT`, which captures the runner's `<schema>, public, pg_temp`, so they need no hard-coded schema and work in every environment.
6. **Forward-only still holds, with one exception, once.** The 20 migrations and 10 seeds were rewritten for this design and the dev database was wiped and reinstalled (2026-11-02). No environment held data worth migrating. From here on, applied scripts are not edited.

## Consequences

- One set of scripts serves staging and production; only the login user, schema name and `PGOPTIONS` differ.
- Separation between api, jobs and readonly is still enforced by the database (grants, column grants, the jobs-only partition functions), as long as every service sets its role. A client built without a role runs as the bare login user and fails closed: it has no table privileges.
- `session_user` in the V018 erasure audit row is now always the login user; `current_user` is the role. The row's `calledBy` still records the actor the API names.
- Audit `entity_type` values follow the new table names (`sharing_share_request`, not `sharing.share_request`).
- Table-level partitions share one namespace with every table; partition names are `provider_token_pYYYYMMDD` and `audit_log_pYYYYMM`, which don't collide.
- Without CREATEROLE we can't make the roles; if the DBA ever refuses the `SET TRUE` grant the fallback is one identity for all components, which weakens isolation and needs its own ADR.

## Links

- [V001__roles_and_schema.sql](../../amplify-database/migrations/V001__roles_and_schema.sql)
- [d3_single_user_roles.sql](../../amplify-database/checks/d3_single_user_roles.sql)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md)
