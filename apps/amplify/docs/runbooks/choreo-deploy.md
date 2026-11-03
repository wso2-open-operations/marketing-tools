# Runbook: deploy Amplify to Choreo (plan M8b)

Console steps that config-as-code can't do. The repo side is done: Dockerfiles, `.choreo/component.yaml` (schemaVersion 1.2) per component, `workload.yaml` for OpenChoreo, and `apps/amplify/scripts/check-descriptors.sh` to catch drift. Run the check before every Choreo change.

Owner: a WSO2 Digital org admin in Choreo. Order matters: database first, then Jobs and Scheduler, then Backend (it needs their Project URLs), then the API Proxy.

## Deploy order across repos

Four repos ship for phase 1. Each step needs the ones above it.

| # | Repo | What | Why it goes here |
|---|---|---|---|
| 1 | People Operations | HR Entity GraphQL: a client for Amplify (ADR-045) | Backend team rosters read it (C7). Without it My Team answers `UNAVAILABLE` and the rest works |
| 1 | wso2-digital-agents | `po-agent` (Novera): optional `imageUrl` and button on `POST /internal/notifications` | Amplify's Novera client-credentials application must be subscribed to its API, and the rich card needs the change live |
| 2 | marketing-tools | `apps/amplify`: sections B to E below | Needs 1 for rosters and Novera cards |
| 3 | one-wso2 | Amplify UI (`webapp/src/features/amplify`) | Calls the API proxy from step 2 and hosts the LinkedIn callback page |

The two repos in step 1 don't depend on each other; ship them in parallel. Settle the One WSO2 callback URL early, since Backend and the LinkedIn Mock config both need it before the UI ships.

Inside marketing-tools the order is: databases, DB Migrate, Jobs, Scheduler, Backend, API Proxy. LinkedIn Mock is dev only and goes up with Jobs and Backend.

## A. Org, repo, project

1. **A1 Bring Your Own Repository.** Choreo console > Organization settings > GitHub: authorize the Choreo GitHub app on the WSO2-managed org and grant it the **marketing-tools** repo only (not "all repositories"). Amplify lives there at `apps/amplify` (ADR-033), so every build path in the table below is relative to the marketing-tools repo root.
2. **A2 Project.** Create project **Amplify** in the WSO2 Digital org. Environments: **dev** and **prod** (add staging only if the org standard requires it).
3. **A3 Cost check.** Before creating paid resources, price the pilot (~830 employees): 3 services + 1 manual task + 1 dev-only mock, 1 replica each, 2 Postgres databases per environment (Amplify, scheduler) on a plan **with backups**. Record the estimate in the plan (M8b "Cost check").

## B. Databases (per environment)

1. **B1** Create a Choreo-managed PostgreSQL **18** server per environment (dev, prod) on a paid plan with backups (Hobbyist has none). If 18 isn't offered, stop: M3 depends on native `uuidv7()` (fallback: UUIDv7 generated in Ballerina, never v4).
   - **B1a Extension check (plan D2).** On each new server run `apps/amplify/amplify-database/checks/d2_extensions.sql` (marketing-tools repo): it lists `pg_partman`, `pg_cron`, `pgaudit`, `citext`, `pg_trgm` and `SELECT version()`. Record the output in the plan's D2 line. `citext` and `pg_trgm` are required; if either is missing, stop and raise it (B18) before running DB Migrate.
2. **B2** Database `amplify`; bootstrap admin credentials go only into the DB Migrate component's secrets (C5).
3. **B3** Database `scheduler` with its own user (ADR-026). Never Amplify's users.
4. **B4** Record backup frequency and retention; restore one backup into dev once (plan M3 "Backups").

## C. Components (all: **Create > Bring your own repo > Dockerfile** build preset, branch `main`)

The Docker context is where Choreo reads `.choreo/component.yaml`, so each component has its own (ADR-027). Use these values exactly:

| Component (display name) | Type | Component directory / Docker context | Dockerfile path |
|---|---|---|---|
| Amplify Jobs | Service | `apps` (its own ancestor context; Choreo reads `apps/.choreo/component.yaml`) | `apps/amplify/amplify-jobs/Dockerfile` |
| Amplify Scheduler | Service | `apps/amplify/amplify-scheduler` | `apps/amplify/amplify-scheduler/Dockerfile` |
| Amplify DB Migrate | Manual Task | `apps/amplify/amplify-database` | `apps/amplify/amplify-database/Dockerfile` |
| Amplify Backend | Service | `apps/amplify` | `apps/amplify/amplify-api/Dockerfile` |
| LinkedIn Mock (dev only) | Service | `apps/amplify/linkedin/apps/mock_linkedin` | `apps/amplify/linkedin/apps/mock_linkedin/Dockerfile` |

After each build, confirm the endpoint Choreo shows matches the descriptor (name, port, visibility). If Choreo shows the wrong port, the Docker context is wrong (Jobs on `apps/amplify` would read the Backend's descriptor and show 9090).

1. **C1 Amplify DB Migrate** (Manual Task). Config form: `BAL_CONFIG_VAR_DBHOST/DBPORT/DBNAME/DBUSER` from B1/B2, secrets `BAL_CONFIG_VAR_DBPASSWORD` (bootstrap admin), `APIDBPASSWORD`, `JOBSDBPASSWORD`, `READONLYDBPASSWORD` (generate, 16+ chars, store only in Choreo). Run it once per environment, then after every release that adds a `V###`/`S###` script. Check the log ends with `Migration run done`.
2. **C2 Amplify Jobs** (Project visibility only). `INTERNALAPIKEY` (full access) and `SCHEDULERAPIKEY` (only `POST /runs` and `POST /maintenance/partitions`): each a secret of at least 32 characters (`openssl rand -hex 24`), **different values**, each the **same value** on Amplify Backend (C5) and here, one pair per environment (ADR-039). Without both Jobs does not start; the Backend needs the internal key when `JOBSURL` is set and the scheduler key when `SCHEDULERURL` is set. DB: user `amplify_jobs` + its password. `TOKENKEYS` (`keyId:base64Key`, `openssl rand -base64 32`, one per environment, never shared dev↔prod) + `TOKENCURRENTKEYID`. Chat: `CHATWEBHOOKURL` secret (dev = test space, prod = WSO2 Club; see `google-chat-webhook.md`), `CHATSPACE` (`dev-test` / `club`), `CHATCARDAVATARURL` and `CHATDEFAULTIMAGEURL` (both optional; the default image is a public HTTPS PNG/JPEG pinned to a commit, see `google-chat-webhook.md` section C), `SHAREPAGEBASEURL` (the One WSO2 Celebrate page, e.g. `https://one.wso2.com/amplify/celebrate`; the card button adds `?share=<campaignId>`). LinkedIn: dev = LinkedIn Mock URLs + mock client id; prod = `https://api.linkedin.com`, `https://www.linkedin.com` + prod app client id. **Never** set `CHATALLOWINSECUREHTTP`.
3. **C3 Amplify Scheduler** (Project visibility only, no auth upstream, never published, never behind the proxy). Secret `DSN` = `postgres://<user>:<pw>@<host>:<port>/scheduler?sslmode=require` (B3).
4. **C4 Jobs and Scheduler URLs for Amplify Backend.** Copy the **Project URL** of the Amplify Jobs endpoint and of the Amplify Scheduler endpoint (each component's overview) into the Backend's `BAL_CONFIG_VAR_JOBSURL` and `BAL_CONFIG_VAR_SCHEDULERURL`. Leave `BAL_CONFIG_VAR_SCHEDULERJOBSURL` empty: it then uses the Jobs URL. They are plain settings, not Choreo connections, so nothing is committed after the first deploy; Digital Operations sets the production values when promoting.
5. **C5 Amplify Backend** (endpoint `Project`, schema `amplify-api/openapi.yaml`). `ENVIRONMENT` = `dev` or `prod` (**never `local`**; that and `DEVLOCALJWTENABLED` stay unset, ADR-023). `INTERNALAPIKEY` = the same secret as Jobs (C2); the Backend sends it on its own calls to Jobs. `SCHEDULERAPIKEY` = the scheduler secret, the same as Jobs; the Backend sets it (not the internal key) as a header on the jobs it registers with the scheduler (ADR-039). `GATEWAYJWKSURL` / `GATEWAYISSUER` / `GATEWAYAUDIENCES` from the Choreo gateway's backend JWT (identity-setup runbook). DB user `amplify_api`. LinkedIn client id/secret (secret), redirect URI = the One WSO2 callback page for that environment. Same `TOKENKEYS` as Jobs in that environment. Team rosters: `HRENTITYBASEURL`, `HRENTITYTOKENURL`, `HRENTITYCLIENTID` and `HRENTITYCLIENTSECRET` (secret) from the HR Entity client (C7). Left empty, My Team answers `UNAVAILABLE` and the rest works.
6. **C6 LinkedIn Mock** (dev only; never promote to prod). Endpoints: api `Project`, www `Public` (the browser follows the OAuth redirect). `CLIENTID`/`CLIENTSECRET` = made-up values matching Backend/Jobs in dev, `WWWBASEURL` = the www endpoint's public URL, `BAL_CONFIG_DATA` = `redirectUris = ["<dev One WSO2 callback>"]`. In dev, Backend `LINKEDINAUTHBASEURL` = the mock's **public** www URL (the authorization URL is shown to the browser).

7. **C7 HR Entity access** (team rosters and the leaver sweep, ADR-045). No people-app change is needed.
   1. People Operations issues Amplify its own client for the **HR Entity GraphQL service** (ask for read-only on `employees` and, if the service can scope it, only `workEmail`, `firstName`, `lastName`, `businessUnit`, `team` and `subTeam`, plus `houseId` and `house` for houses). Note the GraphQL URL, the token URL, the client id and the secret.
   2. Set C5's `HRENTITYBASEURL`, `HRENTITYTOKENURL`, `HRENTITYCLIENTID` and `HRENTITYCLIENTSECRET` (secret), and the same four on the Jobs component (the leaver sweep). Redeploy both.
   3. **Houses (2026-11-03).** Ask People Operations which `hr_entity` version the environment runs. Once it is 1.1.1 or later (digiops-hr #2005 adds `houseId` and `house`), set C5's `HRENTITYINCLUDEHOUSE` = `true` and redeploy. Leave it unset before that: an older service fails the whole read for the unknown fields and My Team answers `UNAVAILABLE`. Jobs does not need it.
   4. Check: `GET /leaderboard` as an employee shows `teamStatus: OK` and their sub-team. A 401 or 403 in the Backend log (`People directory answered 401`) means the HR Entity does not accept the client; `People directory answered with GraphQL errors` right after turning on `HRENTITYINCLUDEHOUSE` means the service is older than 1.1.1 (set it back to unset). With houses on, `GET /leaderboard/groups?by=HOUSE` lists the houses.

## D. API Proxy (console only)

1. **D1 Spike first:** create an API Proxy targeting Amplify Backend's Project endpoint. If Choreo refuses a Project-visible target, set the Backend endpoint to `Organization` in `.choreo/component.yaml` and record it in an ADR (the proxy stays the only *published* API, ADR-004).
2. **D2** Import `amplify-api/openapi.yaml`; access mode as One WSO2 needs (External if the SPA calls it from the browser). Key manager: Asgardeo (identity-setup runbook A3–A6). **Check the access token carries `groups`, `email` and `name` before testing anything else** (identity-setup, "Token requirements"): without `groups` every user is a plain employee and New Post, Current Posts and the dashboards refuse them. Per-resource scopes from the `x-access` in the spec; rate limits per resource (shares, external shares tighter than reads).
3. **D3** Turn on backend JWT so the Backend gets `x-jwt-assertion`; copy its JWKS/issuer/audience into C5.
4. **D4** Security headers at the proxy too if supported (`nosniff`, CSP `upgrade-insecure-requests`, HSTS).
5. **D5 WAF / egress.** If the org uses egress control, allow-list only `api.linkedin.com`, `www.linkedin.com`, `chat.googleapis.com` and the people-app connection's gateway host for this project. Attach the org WAF policy to the proxy if one exists.
6. **D6 Ingress rate limiting.** Put a rate limit on the proxy in front of amplify-api that slows an abusive caller without touching normal use. The limit itself is still to be chosen.
7. **D7 Egress rate limiting to LinkedIn.** On the developer tier we are on for now, LinkedIn allows 500 reposts in a 24-hour window. amplify-jobs caps a run at 50 and a day at 1000 (`linkedinMaxPostsPerRun`, `linkedinMaxPostsPerDay`), so its own day cap sits above that limit. `linkedinMaxPostsPerDay` is not in the Jobs descriptor yet, so it cannot be lowered from the config form: add it (and to `workload.yaml`) before relying on it, or expect LinkedIn to answer 429 past 500.

## E. Versioning and promotion

1. **E1** First version **v1.0.0 from `main`**; no extra deployment tracks.
2. **E2** Build once, promote the same image dev → prod. Only config and secrets differ per environment.
3. **E3** Before promoting: run DB Migrate in prod, then deploy Jobs, Scheduler, Backend; check Backend `GET /ready` (via the proxy test console) and that the startup log says `Scheduler sync … SYNCED`.
4. **E4** CI runs part of the quality gates on every pull request (marketing-tools #45 and #55, upstream #247). `.github/workflows/amplify-quality-gates.yml` runs on changes under `apps/amplify/`: the gate scripts' self-tests, `make check` (descriptors, log PII, transaction gate) and `scripts/lint-openapi-names.sh`. `.github/workflows/amplify-database-integration.yml` runs the `amplify-database` integration group on PostgreSQL 15, 17 and 18 when `amplify-database/` changes. CI does not run the other components' unit and integration tests, so run `scripts/test-all.sh` by hand before every promotion.

## F. Observability

Alerts (Choreo logs/metrics): outbox `FAILED`, share failure rate, breaker `OPEN` in the run log, 5xx rate, scheduler job failures (scheduler `/jobs/{id}/history`, Project network only), `schedulerSync: PENDING` / reconcile give-up log, partition-maintenance failures.

## G. Environment variable reference

Every variable each component's `.choreo/component.yaml` declares, checked against the descriptors. Kind: **cfg** = config form, **secret** = config form secret (only ever in Choreo), **conn** = filled by a Choreo connection. Req: **R** required, **O** optional. Values here are non-secret only. "Local/stg" is what the local stack or the stg Novera setup uses today (`local/.env`, gitignored); it is a hint for dev, **not** a prod value. **TBD** means nobody has supplied it yet; do not guess.

Same names in two components (`DBHOST`, `DBPORT`, `DBNAME`, `DBUSER`, `DBPASSWORD`, `DBSSLROOTCERT`, `LINKEDIN*`, `TOKEN*`) take the per-component values below. All names carry the `BAL_CONFIG_VAR_` prefix except `DSN` and `BAL_CONFIG_DATA`.

### G1. Amplify Backend

| Variable | Kind | Req | Local/stg value | Prod |
|---|---|---|---|---|
| `ENVIRONMENT` | cfg | R | `local` (compose only) | `prod`. Never `local` |
| `GATEWAYJWKSURL` | cfg | R | empty | TBD, from the proxy's backend JWT (D3) |
| `GATEWAYISSUER` | cfg | R | empty | TBD, same source |
| `GATEWAYAUDIENCES` | cfg | R | `amplify-local` | TBD, same source |
| `DBHOST` / `DBPORT` | cfg | R | compose Postgres | TBD, from the Choreo server (B1) |
| `DBNAME` | cfg | R | | `amplify` |
| `DBUSER` | cfg | R | | `amplify_api` |
| `DBPASSWORD` | secret | R | | Ops-generated (`APIDBPASSWORD` from C1) |
| `DBSSLROOTCERT` | cfg | O | | File-mount path of the managed Postgres CA PEM, e.g. `/home/choreo/db-ca/ca.pem`. TBD until mounted |
| `JOBSURL` | cfg | R | | The Jobs endpoint's Project URL (C4) |
| `SCHEDULERURL` | cfg | R | | The Scheduler endpoint's Project URL (C4) |
| `SCHEDULERJOBSURL` | cfg | O | | Empty: it then uses `JOBSURL` |
| `CAMPAIGNLINKORIGINS` | cfg | O | | Leave empty (LinkedIn only: `https://www.linkedin.com,https://linkedin.com`). Dev may add the mock's www URL |
| `ROSTERCACHESECONDS` | cfg | O | | Leave empty (default 259200) |
| `TOPBOARDCACHESECONDS` | cfg | O | | Leave empty (default 7200) |
| `HEADCOUNTCACHESECONDS` | cfg | O | `604800` | Leave empty (default 604800) |
| `SCORECARDTARGETCONNECTEDPCT` | cfg | O | `25` | Leave empty (default 25) |
| `SCORECARDMAXEXPIREDPCT` | cfg | O | `5` | Leave empty (default 5) |
| `SCORECARDTARGETSHARESUCCESSPCT` | cfg | O | `98` | Leave empty (default 98) |
| `SCORECARDTARGETPRIORITYREACHPCT` | cfg | O | `25` | Leave empty (default 25) |
| `SCORECARDTARGETACTIVE30D` | cfg | O | `100` | Leave empty (default 100) |
| `SCORECARDTARGETREPOSTSPERMONTH` | cfg | O | `600` | Leave empty (default 600) |
| `HRENTITYBASEURL` | cfg | O | | TBD, the HR Entity GraphQL URL (C7) |
| `HRENTITYTOKENURL` | cfg | O | | TBD (C7) |
| `HRENTITYCLIENTID` | cfg | O | | TBD (C7) |
| `HRENTITYCLIENTSECRET` | secret | O | | TBD (C7) |
| `HRENTITYINCLUDEHOUSE` | cfg | O | `false` | Leave empty (default false) until the environment's HR Entity is 1.1.1 or later, then `true` (C7 step 3) |
| `LINKEDINCLIENTID` | cfg | R | `amplify-local` (mock) | TBD, from the LinkedIn app owner |
| `LINKEDINCLIENTSECRET` | secret | R | | TBD, from the LinkedIn app owner |
| `LINKEDINREDIRECTURI` | cfg | R | `http://localhost:3000/amplify/connect/callback` | TBD, the prod One WSO2 callback page |
| `LINKEDINAPIBASEURL` | cfg | R | mock API URL | `https://api.linkedin.com` |
| `LINKEDINAUTHBASEURL` | cfg | R | mock www **public** URL | `https://www.linkedin.com` |
| `WSO2ORGANIZATIONURN` | cfg | O | `urn:li:organization:143998207` (test org) | TBD. Code default is `urn:li:organization:1477`; confirm it is the WSO2 page before relying on it |
| `LINKEDINIDTOKENVALIDATION` | cfg | O | unset (default `false`) | TBD, decide before go-live |
| `TOKENKEYS` | secret | R | local random | Fresh for prod, `keyId:base64Key` (`openssl rand -base64 32`); same as Jobs |
| `TOKENCURRENTKEYID` | cfg | R | local | The key id in `TOKENKEYS` |
| `CANADJUSTPOINTSGROUPS` | cfg | O | | Asgardeo groups for adjust/reverse points, comma separated. Empty = the default `amplify_po` |
| `CANADMINGROUPS` | cfg | O | | Asgardeo groups for admin, comma separated. Empty = the default `amplify_admin` |
| `CANCAMPAIGNGROUPS` | cfg | O | | Asgardeo groups for campaigns, comma separated. Empty = the default `amplify_po,amplify_marketing` |
| `CANDASHBOARDGROUPS` | cfg | O | | Asgardeo groups for dashboards, comma separated. Empty = the default `amplify_po,amplify_marketing,amplify_slt,amplify_admin` |
| `CANEXPORTGROUPS` | cfg | O | | Asgardeo groups for dashboard CSV export, comma separated. Empty = the default `amplify_po,amplify_marketing,amplify_slt,amplify_admin` |
| `CANPODASHBOARDGROUPS` | cfg | O | | Asgardeo groups for the PO dashboard, comma separated. Empty = the default `amplify_po` |
| `CANPOINTRULESGROUPS` | cfg | O | | Asgardeo groups for point rules, comma separated. Empty = the default `amplify_po` |
| `CANREPORTSGROUPS` | cfg | O | | Asgardeo groups for SLT reports, comma separated. Empty = the default `amplify_slt,amplify_po` |
| `CANREVIEWSHARESGROUPS` | cfg | O | | Asgardeo groups for external-share review, comma separated. Empty = the default `amplify_po` |
| `LINKEDINNONCEMODE` | cfg | O | `OFF` | `OFF`, `SEND` (checked when LinkedIn echoes the nonce) or `REQUIRE`. Only with ID-token validation on. Empty = `OFF` |
| `INTERNALAPIKEY` | secret | R | | Ops-generated, at least 32 characters, the same value as Jobs (C2) |
| `SCHEDULERAPIKEY` | secret | R | | Ops-generated, at least 32 characters, different from the internal key, the same value as Jobs (C2) |

### G2. Amplify Jobs

| Variable | Kind | Req | Local/stg value | Prod |
|---|---|---|---|---|
| `DBHOST` / `DBPORT` | cfg | R | compose Postgres | TBD (B1) |
| `DBNAME` | cfg | R | | `amplify` |
| `DBUSER` | cfg | R | | `amplify_jobs` |
| `DBPASSWORD` | secret | R | | Ops-generated (`JOBSDBPASSWORD` from C1) |
| `DBSSLROOTCERT` | cfg | O | | Same file-mount path as Backend |
| `LINKEDINCLIENTID` | cfg | R | `amplify-local` (mock) | TBD, same as Backend |
| `LINKEDINAPIBASEURL` | cfg | R | mock API URL | `https://api.linkedin.com` |
| `LINKEDINAUTHBASEURL` | cfg | R | mock www URL | `https://www.linkedin.com` |
| `TOKENKEYS` | secret | R | | Same as Backend |
| `TOKENCURRENTKEYID` | cfg | R | | Same as Backend |
| `CHATWEBHOOKURL` | secret | O | dev test space webhook (Scott-only) | TBD, from the Club space owner |
| `CHATSPACE` | cfg | O | `Amplify Demo` locally; `dev-test` in Choreo dev | `club` |
| `CHATCARDAVATARURL` | cfg | O | `https://fonts.gstatic.com/s/e/notoemoji/17.0/1f50a/72.png` | Same URL is fine; confirm |
| `CHATDEFAULTIMAGEURL` | cfg | O | `https://raw.githubusercontent.com/BechtelCanDoIt/marketing-tools/5e5006aadd4a031021265342a20ff0fcda3102b7/apps/amplify/amplify-jobs/img/WSO2-Amplify-Poster-Default.png` (fork) | TBD, same file pinned to a commit in the WSO2-managed repo |
| `SHAREPAGEBASEURL` | cfg | R | `https://one.wso2.com/amplify/celebrate` | TBD, the One WSO2 team confirms the prod Celebrate page |
| `NOVERANOTIFYURL` | cfg | O | `https://apis-stg.wso2.com/people-ops-suite/po-agent/v1.0/internal/notifications` (stg) | TBD, prod gateway URL of `POST /internal/notifications` (https) |
| `NOVERATOKENURL` | cfg | O | `https://api.asgardeo.io/t/wso2/oauth2/token` (stg app) | TBD |
| `NOVERACLIENTID` | cfg | O | stg application id (in `local/.env`) | TBD, a prod application subscribed to Novera's API |
| `NOVERACLIENTSECRET` | secret | O | | TBD |
| `NOVERASCOPES` | cfg | O | empty | TBD, empty unless Novera needs a scope |
| `AMPLIFYONNOVERA` | cfg | O | `false` locally (default `true`) | TBD, the open item in `prod-deploy-handoff.md` |
| `AMPLIFYONWEBHOOK` | cfg | O | `true` locally (default `false`) | TBD, same open item |
| `INTERNALAPIKEY` | secret | R | | Ops-generated, at least 32 characters, the same value as the Backend (C5) |
| `SCHEDULERAPIKEY` | secret | R | | Ops-generated, at least 32 characters, different from the internal key; accepted only for `POST /runs` and `POST /maintenance/partitions`; the same value as the Backend |
| `LEAVERSWEEPMODE` | cfg | O | `OFF` | `OFF`, `DRY_RUN` or `ERASE`. Start with `DRY_RUN` (ADR-040) |
| `HRENTITYBASEURL` | cfg | O | | HR Entity GraphQL URL for the leaver sweep |
| `HRENTITYTOKENURL` | cfg | O | | HR Entity OAuth token URL |
| `HRENTITYCLIENTID` | cfg | O | | HR Entity client id |
| `HRENTITYCLIENTSECRET` | secret | O | | HR Entity client secret |

### G3. Amplify Scheduler

| Variable | Kind | Req | Prod |
|---|---|---|---|
| `DSN` | secret | R | `postgres://<user>:<pw>@<host>:<port>/scheduler?sslmode=require` (B3), TBD |

### G4. Amplify DB Migrate (Manual Task)

| Variable | Kind | Req | Prod |
|---|---|---|---|
| `DBHOST` / `DBPORT` | cfg | R | TBD (B1) |
| `DBNAME` | cfg | R | `amplify` |
| `DBUSER` | cfg | R | Bootstrap admin user, TBD |
| `DBPASSWORD` | secret | R | Bootstrap admin password, from the Choreo server |
| `DBSSLROOTCERT` | cfg | O | Same file-mount path |
| `APIDBPASSWORD` | secret | R | Ops-generated, 16+ chars |
| `JOBSDBPASSWORD` | secret | R | Ops-generated, 16+ chars |
| `READONLYDBPASSWORD` | secret | O | Ops-generated, 16+ chars |

### G5. LinkedIn Mock (dev only)

| Variable | Kind | Req | Dev |
|---|---|---|---|
| `LISTENERHOST` | cfg | R | `0.0.0.0` (fixed) |
| `WWWBASEURL` | cfg | R | The www endpoint's public URL, TBD |
| `CLIENTID` | cfg | R | `amplify-local` (matches Backend and Jobs) |
| `CLIENTSECRET` | secret | R | Made-up; matches Backend |
| `BAL_CONFIG_DATA` (no prefix) | cfg | R | `redirectUris = ["<dev One WSO2 callback>"]`, TBD |

## Go-live config review (M10)

No environment has `BAL_CONFIG_VAR_ENVIRONMENT=local`, `DEVLOCALJWTENABLED`, `CHATALLOWINSECUREHTTP` or a LinkedIn Mock URL in prod. `scripts/check-descriptors.sh` passes.
