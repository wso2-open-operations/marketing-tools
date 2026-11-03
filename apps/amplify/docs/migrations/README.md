# Database migrations and integration tests

Schema source of truth: `architecture/solution/Phase 1/phase1-data-model.md`. Scripts:
`amplify-database/migrations/` (V001 to V021; V017 is unused) and `seed/` (S001 to S010). Per-migration notes:
`2026-10-17-v012-recognition-lock-maintenance-timeout.md`, `2026-10-17-v013-idle-timeout-dashboard-indexes.md`,
`2026-10-27-v014-point-actions-all-phases.md`. Runner: `amplify-database/main.bal`. Its settings and files are in
[amplify-database/README.md](../../amplify-database/README.md).

## Running the migrate runner

The runner connects as the one Amplify login user (`dbUser`, password `dbPassword`) and puts one schema first on the
`search_path` (`dbSchema`, default the user name). There are no app roles and no role passwords: that user owns every
object and every component connects as it (ADR-043). The DBA creates the login, the schema and the extensions before
the first run (locally `local/db-init/10-amplify-dba-setup.sh`; check with `amplify-database/checks/d3_single_user.sql`).
The server must be PostgreSQL 15 or later, and the runner checks this before any script runs
([ADR-044](../../architecture/decisions/ADR-044-postgresql-15-or-later.md)).

Each script runs in its own transaction under a transaction-level advisory lock, and is recorded in
`schema_version` (in the Amplify schema) with a SHA-256 checksum. A rerun applies nothing; a changed applied script
stops the run. A pending script that sorts below an already-applied version also stops the run: scripts apply in
version order only, so a late-arriving `V0NN` must be renumbered above the highest applied version.

`dryRun = true` connects to the database but creates nothing (not even `schema_version`) and runs no script. It
logs each script as `PENDING`, `APPLIED` or `CHANGED` and fails on a changed or out-of-order script, so it doubles
as a checksum check before a deploy.

Local: `make up` runs it once before api/jobs start; `make seed` reruns it (Compose pins `postgres:17.11`).

## Integration tests (PostgreSQL 17)

`bal test` without a database passes: the `integration` group returns early unless enabled.
`scripts/test-all.sh` runs the whole set (a throwaway `postgres:17.11`, mock_linkedin, every component). By hand:

```sh
docker run -d --name amplify-pg17 -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:17

# 1. Runner: drops/creates `amplify_it` and its login user (`amplify_it_user`), migrates fresh, reruns
#    (idempotent), checksum guard, partition tests.
cd amplify-database
BAL_CONFIG_VAR_ITENABLED=true BAL_CONFIG_VAR_DBPORT=55432 BAL_CONFIG_VAR_DBPASSWORD=postgres \
  BAL_CONFIG_VAR_DBSSLMODE=DISABLE bal test --groups integration

# 2. Repositories and the M5 API flows (integration_m5_test.bal), as the single login user against `amplify_it`.
cd ../amplify-domain
AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55432 bal test --groups integration

# 3. The Run (M6): mock_linkedin on 19190/19191 as LinkedIn.
cat > /tmp/mock-it.toml <<'TOML'
[wso2.mock_linkedin]
apiPort = 19190
wwwPort = 19191
wwwBaseUrl = "http://localhost:19191"
clientId = "it-client"
clientSecret = "it-secret"
redirectUris = ["http://localhost:3000/auth/linkedin/callback"]
enableMockAdmin = true
TOML
(cd ../../linkedin/apps/mock_linkedin && BAL_CONFIG_FILES=/tmp/mock-it.toml bal run &)
cd ../amplify-jobs
AMPLIFY_IT=true AMPLIFY_IT_DB_PORT=55432 bal test --groups integration
pkill -f mock_linkedin

docker rm -f amplify-pg17
```

Step 3 registers a campaign (announcement to the Novera stub, with `Idempotency-Key: amplify:{id}`), connects through the mock OAuth
flow and seals the token into today's partition, shares, then checks publish → engagement → points →
standing, correlation ids in audit, rerun safety (no second post, card or ledger row), one run across
replicas (advisory lock), stale-lock release and the `Idempotency-Key` purge. `bal run` of the mock rewrites
its `Dependencies.toml`; revert it.

The domain and jobs tests read environment variables (`AMPLIFY_IT`, `AMPLIFY_IT_DB_HOST`, `_PORT`, `_NAME`,
`_LOGIN_USER`, `_LOGIN_PASSWORD`; the domain tests also `_SSL`, `_ADMIN_USER`, `_ADMIN_PASSWORD`) instead of configurables: a configurable in the root test module
is "unused" in every other module's test run and fails it. Ids are fresh UUIDv7s, so step 2 can run again.

## Driver notes (learned the hard way)

- `execute` asks the driver for generated keys, which appends `RETURNING` to the statement. DDL and whole
  script files go through `call` instead.
- `time:Utc` can't be bound directly (UnsupportedOperationException): bind `CAST(${store:ts(t)} AS timestamptz)`.
- uuid and date columns need `CAST(${x} AS uuid)` / `CAST(${x} AS date)`; read them back as `::text`.
- A `?` in SQL text is a bind marker to the driver; scripts must not contain one.
