# ADR-043: One database login and one schema, no roles

Status: Accepted (2026-11-03)

## Context

The first design gave Amplify eleven schemas (`identity`, `campaign`, `connection`, ...) and four database roles
(`amplify_api`, `amplify_jobs`, `amplify_readonly`, `amplify_migrate`) with per-table grants. The migrate runner
connected as the bootstrap admin, created the roles and set their passwords.

That assumed we control the database server. We don't. The DBAs give each application **one login and one
database user-named schema** (staging: `amplify_stg_user`; production gets its own name), and the login has no
`SUPERUSER`. Our login can't be the bootstrap admin, and creating roles and one login per component is not part of
the established pattern for apps on this server.

## Decision

- **One login, one schema.** The login owns every object. The schema has the login's name by default (`dbSchema`
  overrides it). Every component (api, jobs, migrate) connects as that login with the same `DBUSER` and
  `DBPASSWORD`.
- **No roles and no grants.** V001 creates no schema and no role. It checks that the schema exists, that `citext`
  and `pg_trgm` are installed and that `uuidv7()` exists (ADR-044).
- **Tables are named `<context>_<name>`** (`identity_employee`, `scoring_points_ledger`, ...) because the contexts
  share one schema. No script names a schema: the runner and every pooled connection put the schema first on the
  `search_path` (`<schema>, public, pg_temp`). `SECURITY DEFINER` functions use `SET search_path FROM CURRENT`.
- **The schema name is checked** against a plain-identifier pattern before it goes into the JDBC options, and the
  migrate tool quotes and binds it.
- **Compensating control (V021):** the points ledger and the audit log guard themselves with row triggers, since
  there are no grants left to make them insert-only. The ledger allows no deletes and changes only the settlement
  columns; the audit log allows no updates or deletes (retention drops whole partitions, which fire no row trigger).
- **Context isolation (ADR-005) is a convention.** A context reads and writes only its own tables and has no
  cross-context foreign keys. Code review and the repository layout hold it, not the database.

## Alternatives considered

| Alternative | Why not |
| --- | --- |
| Keep four roles and eleven schemas | Needs `CREATEROLE`/superuser at the DBA's side and one login per component; not what the DBAs provide |
| `NOLOGIN` app roles created by the migrate tool (it has `CREATEROLE` on staging), with `-c role=...` in the JDBC options per component | Not a hard boundary, because a session can `RESET ROLE`. It still limits what a bug in one component can do. Kept as a later hardening step if the DBA policy allows it |
| One schema, one login per component | Three passwords per environment and three DBA requests, for the same blast radius, since each component's login would still need the others' tables |

## Consequences

- **Least privilege is gone at the database layer.** A leaked login password, or an injection bug, can `DROP`,
  `TRUNCATE` or disable the V021 triggers (V021 says so itself). The password lives only in Choreo secrets, the
  queries are parameterized (`sql:ParameterizedQuery`), and the ledger and audit log are guarded against every
  code path.
- **Phase 2 reporting** runs as the same login, or as a read-only login the DBAs create later. The
  `amplify_readonly` role no longer exists.
- **A fresh database is required.** V002-V020 were rewritten in place and V001 replaced, so an environment
  migrated under the old design can't be upgraded by the runner (the checksums differ). See
  `docs/migrations/2026-11-03-adr-043-single-login-single-schema.md`.
- This follows the established one-login-per-app pattern on the shared database server, so it needs no separate
  Security approval. The threat model's database section describes the roles that no longer exist and is updated
  with the next threat-model revision.
