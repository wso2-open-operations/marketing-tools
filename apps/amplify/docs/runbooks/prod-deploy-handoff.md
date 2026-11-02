# Amplify prod deployment: handoff to ops

Phase 1. This is the order and the checks for prod. Console detail for each step is in [choreo-deploy.md](./choreo-deploy.md); section numbers (B1, C2, E3 ...) below point there. Secrets are not in this doc. They live only in Choreo, and the values come from whoever holds them (see "Who supplies what").

Fill in before handing over:

- Release: version `v1.0.0`, commit `________` (marketing-tools `main`)
- Stg sign-off by: `________` on `________`
- Prod window: `________`

## Rules that apply to every step

1. Build once, promote the same image from stg to prod. Only config and secrets change per environment (E2).
2. `ENVIRONMENT` is `prod`. Never `local`. `DEVLOCALJWTENABLED` and `CHATALLOWINSECUREHTTP` stay unset.
3. No LinkedIn Mock anywhere in prod. Prod LinkedIn URLs are `https://api.linkedin.com` and `https://www.linkedin.com`.
4. `TOKENKEYS` is generated fresh for prod (`openssl rand -base64 32`, format `keyId:base64Key`) with `TOKENCURRENTKEYID` set to its key id. Never reuse the dev or stg key. Jobs and Backend get the same values.
5. Jobs, Scheduler and the databases are never published. Only the API Proxy is.

## Order

Four repos ship. Each step needs the ones above it. Steps 2 to 4 are all marketing-tools (`apps/amplify`).

### Step 1: people-app and Novera (parallel)

people-ops-suite (`people-app`):
- The service-client change is deployed to prod.
- Amplify Backend's client id is added to `directoryClientIds` after the Backend connection exists (step 3, item 5). Redeploy people-app after adding it.

wso2-digital-agents (`po-agent`, Novera):
- The imageUrl and button change on `POST /internal/notifications` (DA-01) is deployed to prod.
- If the Amplify card goes out through Novera, Amplify's application must be subscribed to Novera's API. That subscription check is the only auth on the route, so approve it deliberately. See "Open item" below.

Check: both services are healthy in prod.

### Step 2: Databases (B)

1. PostgreSQL 18 server on a plan with backups. If 18 isn't offered, stop and escalate; do not continue on an older version.
2. Run `amplify-database/checks/d2_extensions.sql`. `citext` and `pg_trgm` are required. If either is missing, stop and raise it.
3. Database `amplify` (bootstrap admin goes only into the DB Migrate component's secrets) and database `scheduler` with its own user.
4. Record backup frequency and retention.

### Step 3: Components (C), in this order

1. DB Migrate (Manual Task). Run once for the first release, then after every release that adds a `V###` or `S###` script. The log must end with `Migration run done`.
2. Amplify Jobs (Project visibility). Needs the Chat webhook, the LinkedIn prod URLs and client id, and `TOKENKEYS`.
3. Amplify Scheduler (Project visibility, no auth upstream, never behind the proxy). Needs `DSN` for the `scheduler` database.
4. Amplify Backend. Create the `amplify-jobs` and `amplify-scheduler` connections, and the people-app connection (C7). The `resourceRef` values go into `apps/amplify/.choreo/component.yaml` (replace `REPLACE_WITH_ID`) in a commit before the build. The gateway JWT values don't exist yet, so the first deploy runs without them and step 4 finishes the job.
5. Back to step 1: add the Backend's people-app client id to `directoryClientIds` and redeploy people-app.

### Step 4: API Proxy (D)

1. Proxy targets the Backend's Project endpoint. If Choreo refuses that, set the endpoint to `Organization` and record it in an ADR.
2. Import `amplify-api/openapi.yaml`. Key manager is Asgardeo. Per-resource scopes come from `x-access`; rate limits are tighter on shares and external shares than on reads.
3. Turn on backend JWT. Copy its JWKS URL, issuer and audience into the Backend's `GATEWAYJWKSURL`, `GATEWAYISSUER`, `GATEWAYAUDIENCES` and redeploy the Backend.
4. Security headers at the proxy if supported. If the org uses egress control, allow only `api.linkedin.com`, `www.linkedin.com`, `chat.googleapis.com` and the people-app gateway host.

### Step 5: One WSO2 UI

Deployed by the One WSO2 team after the proxy is live. They need the proxy URL. The prod One WSO2 callback page is the LinkedIn redirect URI in the Backend config and in the LinkedIn app.

## Who supplies what

| Item | From |
|---|---|
| Choreo org admin access | Ops |
| Prod LinkedIn app client id and secret, redirect URI | LinkedIn app owner |
| `CHATWEBHOOKURL` for the WSO2 Club space (`CHATSPACE=club`) | Google Chat space owner (see `google-chat-webhook.md`) |
| `CHATDEFAULTIMAGEURL`, `CHATCARDAVATARURL` (optional) | Repo; public HTTPS image pinned to a commit |
| `SHAREPAGEBASEURL` | One WSO2 team (the prod Celebrate page) |
| Asgardeo setup | `identity-setup.md` |
| Generated DB passwords (`APIDBPASSWORD`, `JOBSDBPASSWORD`, `READONLYDBPASSWORD`), `TOKENKEYS` | Ops generates and stores only in Choreo |

## Verify before calling it done (E3)

1. `GET /ready` on the Backend, through the proxy test console, returns ready.
2. The Backend startup log says `Scheduler sync ... SYNCED`.
3. `GET /leaderboard` as an employee shows `teamStatus: OK` and their sub-team. A 500 from people-app means the client id isn't listed or the claim is wrong. A 403 means the route isn't the directory.
4. `scripts/check-descriptors.sh` passes on the release commit, and no prod config has `ENVIRONMENT=local`, `DEVLOCALJWTENABLED`, `CHATALLOWINSECUREHTTP` or a LinkedIn Mock URL.
5. Post one real share to the Club space and confirm the card, image and LinkedIn button.

## Alerts to turn on (F)

Outbox `FAILED`, share failure rate, breaker `OPEN` in the run log, 5xx rate, scheduler job failures, `schedulerSync: PENDING` or reconcile give-up log, partition-maintenance failures.

## Open item

The runbook sends the Chat card through the Club space webhook (`CHATWEBHOOKURL` on Jobs). It does not list a Novera client credential for Amplify. Whether the prod card also goes through Novera's `/internal/notifications` needs a yes or no from the Amplify team before step 1 is finalised. If no, the Novera subscription step drops out.

## Rollback

Migrations are forward-only (`V###__name.sql`). Do not edit an applied script. To roll back the app, redeploy the previous image for Backend, Jobs and Scheduler; the schema stays. A bad migration gets a new migration, not a revert.

## Questions

Scott Bechtel, scott@wso2.com.
