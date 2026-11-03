# db-init

The local stand-in for what the DBA does in staging and production: one login user, a schema named after it, and the extensions. There are no roles (ADR-043).

## What it is and how it is triggered

`10-amplify-dba-setup.sh` runs in two ways:

- Postgres runs it on a fresh volume, because Compose mounts this folder at `/docker-entrypoint-initdb.d` (`compose.yaml`).
- `make dba-setup` runs it on an existing volume.

It is idempotent. It needs `AMPLIFY_DB_USER` and `AMPLIFY_DB_PASSWORD`; `POSTGRES_USER` and `POSTGRES_DB` come from the postgres image.

## What it does

- Creates the login role when missing, and sets its password.
- Creates the schema named after the user, owned by it.
- Grants `CONNECT` on the database.
- Sets the database `search_path` to the schema then `public`. This is a local convenience for `psql` sessions in scripts. The services set their own `search_path`.
- Creates `citext` and `pg_trgm` in `public`.

The migration runner (`amplify-database`) then builds every table as that user.

## Files

| File | What |
| --- | --- |
| `10-amplify-dba-setup.sh` | The setup script |

## What it does not do

- It does not create tables or seed data. `amplify-database` does.
- It does not create roles beyond the one login, or grant anything to other users.
- It is not used in Choreo. There the DBA does these steps, and `amplify-database/checks/d3_single_user.sql` verifies them.
