# WSO2 Amplify (backend)

Amplify helps WSO2 employees share company LinkedIn posts, earn points and show up on the leaderboards in One WSO2.
This folder (`apps/amplify` in the marketing-tools repo) holds the backend. The UI is the Amplify module in One WSO2, `webapp/src/features/amplify`.

> Repo home (plan M0 D12): Amplify lives in marketing-tools, a fork of `wso2-open-operations/marketing-tools`, so it ships through a WSO2-managed org with the other marketing apps ([ADR-033](architecture/decisions/ADR-033-amplify-lives-in-marketing-tools.md), superseding ADR-030).

## Layout

```
apps/amplify/
├── README.md · CLAUDE.md          # LICENSE and the issue/PR templates are marketing-tools' (repo root)
├── compose.yaml · Makefile       # full local stack (M8a): make up / seed / e2e / down
├── .choreo/component.yaml        # Choreo descriptor of amplify-api (its Docker context is this folder, ADR-027); jobs' is ../.choreo/component.yaml (context `apps`)
├── .dockerignore · .gitignore
├── amplify-common/           # shared library (ADR-020): types, events, crypto, linkedin, googlechat
├── amplify-domain/           # shared library (ADR-021): bounded contexts + PostgreSQL repositories + store
├── amplify-api/              # published API (behind the API proxy): /health, /ready
├── amplify-jobs/             # worker: POST /runs, POST /maintenance/partitions, POST /maintenance/rebuild-recognition, /health
├── amplify-scheduler/        # pinned akorn/scheduler image (UID 10014): calls amplify-jobs on schedule (ADR-026)
├── amplify-database/         # Amplify DB Migrate runner + migrations/ + seed/ + checks/
├── local/                        # .env.example, dev-jwt/ (ADR-023), chat-stub/
├── scripts/                      # test-all.sh, e2e-local.sh, load-test.sh (+ load/), check-descriptors.sh, check-logs-pii.sh, it-scheduler.sh, lint-openapi-names.sh
└── docs/migrations/              # dated behavior/schema change notes
```

## Build

`amplify-api` and `amplify-jobs` depend on `amplify-common` and `amplify-domain` from the local Ballerina repository, so publish them first, in that order:

```sh
cd amplify-common && bal pack && bal push --repository=local
cd ../amplify-domain && bal pack && bal push --repository=local
cd ../amplify-api && bal build && bal test
```

Database: migrations, seeds and the integration-test recipe against PostgreSQL 18 are in [docs/migrations/README.md](docs/migrations/README.md).

Docker images build from a clean checkout (the shared packages are packed inside the build stage). Each component has its own Docker context, because Choreo reads `<context>/.choreo/component.yaml` ([ADR-027](architecture/decisions/ADR-027-per-component-docker-contexts.md)):

```sh
docker build -f amplify-api/Dockerfile -t amplify-api .
docker build -f amplify-jobs/Dockerfile -t amplify-jobs ..   # jobs builds from apps/, its own ancestor context
docker build -t amplify-database amplify-database
docker build -t amplify-scheduler amplify-scheduler
```

## Local stack

Needs Docker (Compose v2), `openssl`, `curl`, `jq`. From this folder:

```sh
make up      # first run writes local/.env (random local-only secrets) and the dev JWT keys, builds, starts, waits for health
make e2e     # scripts/e2e-local.sh: campaign -> scheduler Run -> Chat card -> mock OAuth -> share -> points -> leaderboard
make seed    # rerun Amplify DB Migrate (migrations + seeds; idempotent)
make logs    # follow all logs; `docker compose --env-file local/.env logs -f chat-stub` for cards
make check   # descriptor drift check (Choreo component.yaml vs workload.yaml vs Dockerfile vs compose) + log hygiene (scripts/check-logs-pii.sh)
```

The gates under `scripts/` are the only thing between a drift and a release, so each one carries its own
fixtures: `scripts/check-descriptors.sh --self-test`, `scripts/check-logs-pii.sh --self-test` and
`scripts/lint-openapi-names.sh --self-test`, plus `scripts/check-transaction-gate.sh --self-test`. Run them
after changing a gate; each one exercises the bypasses a reviewer has found in it.

```sh
make load-test  # k6 (Docker image) against the running stack: 1k employees / 50k ledger rows, p95 < 50 ms (docs/testing/load-test-2026-10.md)
make down    # stop and REMOVE volumes
```

`make test-all` (stack down) runs every tier and removes what it starts: unit tests of every package, the integration tests on a throwaway `postgres:18` with `mock_linkedin` (including Postgres stopped mid-run), the scheduler IT and the Compose e2e.

| Service | Host port | Notes |
|---|---|---|
| amplify-api | `127.0.0.1:9090` | Published directly (no gateway). Call it with a dev JWT: `curl -H "x-jwt-assertion: $(local/dev-jwt/mint-dev-jwt.sh token emp-1 ada@example.com amplify_po)" localhost:9090/me` (ADR-023, `environment=local` only) |
| mock-linkedin | `127.0.0.1:19091` (www/OAuth only) | The browser follows the authorization redirect here; api port 9090 stays internal. One mock member signs in every time |
| people-stub | `127.0.0.1:19092` | people-app directory stub (`GET /employees/basic-info`) for team rosters and One WSO2 photos/names. `make env` (and so `make up`) creates `local/people-stub/directory.json` from the example the first time (the real file is gitignored, so it never gets committed); edit it to add yourself. ThunderID users are keyed `<sub>@example.com` (the dev proxy's fallback when the token has no email) |
| postgres, amplify-db-migrate, amplify-jobs, scheduler, scheduler-db, chat-stub | none | Compose network only. Scheduler UI: `docker compose --env-file local/.env exec amplify-api wget -qO- http://scheduler:8080/jobs` |
| apim (`make up PROFILE=apim`) | `127.0.0.1:9443`, `8243` | Optional WSO2 API Manager 4.7.0. **Pending the non-prod Asgardeo org** (key manager); steps in `compose.yaml`. Until then the default profile is the supported one |

To point a local One WSO2 at it, use `http://localhost:9090` with a dev JWT forwarded as `x-jwt-assertion`, and `LINKEDIN_REDIRECT_URI` (default `http://localhost:3000/amplify/connect/callback`) as its callback page.

## Configuration

Every setting is a Ballerina `configurable`, set through `BAL_CONFIG_VAR_<NAME>` (or a mounted `Config.toml`). The **same env names** are used in `compose.yaml`, Choreo (`.choreo/component.yaml` `configurations.env`) and OpenChoreo (`workload.yaml`); `scripts/check-descriptors.sh` fails if they drift. Secrets are Choreo secrets / OpenChoreo `secretRef`, never in Git. Local values come from `local/.env` (`local/.env.example`).

| Env name (`BAL_CONFIG_VAR_…`) | api | jobs | db-migrate | Secret | Local (compose) value |
|---|---|---|---|---|---|
| `DBHOST`, `DBPORT`, `DBNAME`, `DBUSER` | ✓ | ✓ | ✓ | | `postgres`, 5432, `amplify`, per-component user |
| `DBPASSWORD` | ✓ | ✓ | ✓ | ✓ | `AMPLIFY_API_DB_PASSWORD` / `AMPLIFY_JOBS_DB_PASSWORD` / `POSTGRES_PASSWORD` |
| `DBSSLMODE` | ✓ | ✓ | ✓ | | `DISABLE` (local only). api, jobs and db-migrate default `VERIFY_FULL` |
| `DBSSLROOTCERT` | ✓ | ✓ | ✓ | | unset (local `DISABLE`). Choreo: path of the managed Postgres CA PEM, mounted as a file mount; api, jobs and db-migrate warn at start-up when a remote database isn't verified |
| `APIDBPASSWORD`, `JOBSDBPASSWORD`, `READONLYDBPASSWORD` | | | ✓ | ✓ | from `local/.env` |
| `ENVIRONMENT` | ✓ | | | | `local` (Choreo: `dev`/`prod`, never `local`) |
| `GATEWAYJWKSURL`, `GATEWAYISSUER`, `GATEWAYAUDIENCES` | ✓ | | | | unset placeholders; APIM profile sets them |
| `DEVLOCALJWTENABLED`, `DEVJWKSFILE` | ✓ | | | | `true`, `/dev-jwt/jwks.json` (local only, ADR-023) |
| `JOBSURL`, `SCHEDULERJOBSURL` | ✓ | | | | `http://amplify-jobs:9091` (Choreo: jobs connection `ServiceURL`) |
| `SCHEDULERURL` | ✓ | | | | `http://scheduler:8080` (Choreo: scheduler connection) |
| `MINRUNINTERVALSECONDS`, `RECONCILEDELAYSECONDS` | ✓ | | | | 10, 5 (local only; defaults 60, 15) |
| `PEOPLEDIRECTORYURL` | ✓ | | | | `http://people-stub:9096/employees/basic-info` (Choreo: unset until D13's service credential, `teamStatus: UNAVAILABLE`). people-app `GET /employees/basic-info`; directory results (teams, names, houses) cached 24 hours |
| `CAMPAIGNLINKORIGINS` | ✓ | | | | `https://www.linkedin.com,https://linkedin.com,http://localhost:19091` (Choreo prod: unset = LinkedIn only; dev may add the mock's public www URL). Origins a campaign's post link may use |
| `ROSTERCACHESECONDS` | ✓ | | | | unset (default 86400 = 24 hours). TTL of the directory results (teams, names, houses): how long a team move or new hire takes to show without a restart. Only a successful read is kept; a failed refresh keeps serving the last result and asks again on the next call |
| `HEADCOUNTCACHESECONDS` | ✓ | | | | unset (default 86400 = 24 hours). How long the employee count ("of N") reuses one directory read |
| `SCORECARDTARGETCONNECTEDPCT`, `SCORECARDMAXEXPIREDPCT`, `SCORECARDTARGETSHARESUCCESSPCT`, `SCORECARDTARGETPRIORITYREACHPCT`, `SCORECARDTARGETACTIVE30D`, `SCORECARDTARGETREPOSTSPERMONTH` | ✓ | | | | unset (defaults 25, 5, 98, 25, 100, 600). The scorecard lines; local `.env` names are `SCORECARD_TARGET_CONNECTED_PCT` etc. |
| `PEOPLEDIRECTORYTOKENURL`, `PEOPLEDIRECTORYCLIENTID`, `PEOPLEDIRECTORYCLIENTSECRET` | ✓ | | | | unset. OAuth2 client credentials for the people-app API (Choreo connection) |
| `LINKEDINCLIENTID` | ✓ | ✓ | | | `amplify-local` (mock) |
| `LINKEDINCLIENTSECRET` | ✓ | | | ✓ | random, shared with the mock |
| `LINKEDINREDIRECTURI` | ✓ | | | | `http://localhost:3000/amplify/connect/callback` |
| `LINKEDINAPIBASEURL`, `LINKEDINAUTHBASEURL` | ✓ | ✓ | | | `http://mock-linkedin:9090`, `http://mock-linkedin:9091` |
| `LINKEDINAUTHORIZEBASEURL` | ✓ | | | | `http://localhost:19091` (browser-facing; local only, empty = `LINKEDINAUTHBASEURL`) |
| `LINKEDINIDTOKENVALIDATION` | ✓ | | | | `false` (`LINKEDIN_ID_TOKEN_VALIDATION`; the mock issues no ID token). `LINKEDINJWKSURL` / `LINKEDINOIDCISSUER` default to LinkedIn's |
| `LINKEDINNONCEMODE` | ✓ | | | | `OFF` (`LINKEDIN_NONCE_MODE`). OIDC nonce on connect, only with `LINKEDINIDTOKENVALIDATION=true`: `SEND` puts it on the authorize URL and checks it when the ID token carries one (logs `nonce not echoed` otherwise), `REQUIRE` refuses a token without the same nonce. LinkedIn documents neither a nonce parameter nor a nonce claim, so stay at `SEND` until a real app is seen to echo it |
| `TOKENKEYS`, `TOKENCURRENTKEYID` | ✓ | ✓ | | ✓ (keys) | `local-1:<random base64 32 bytes>`, `local-1` |
| `CHATWEBHOOKURL` | | ✓ | | ✓ | chat-stub URL (or the dev test space) |
| `CHATSPACE`, `CHATCARDAVATARURL`, `SHAREPAGEBASEURL` | | ✓ | | | `dev-test`, empty, One WSO2 Celebrate page |
| `CHATALLOWINSECUREHTTP` | | ✓ | | | `true` (local only, plain-http stub) |
| `AMPLIFYONNOVERA`, `AMPLIFYONWEBHOOK` | | ✓ | | | `true`, `false` (`AMPLIFY_ON_NOVERA`, `AMPLIFY_ON_WEBHOOK`): which channels announce a campaign. Novera is primary, the webhook best effort |
| `NOVERANOTIFYURL`, `NOVERATOKENURL`, `NOVERACLIENTID`, `NOVERASCOPES` | | ✓ | | | empty (Novera's `POST /internal/notifications` through its Choreo gateway, the token endpoint, the subscribed application, optional scopes) |
| `NOVERACLIENTSECRET` | | ✓ | | ✓ | empty (that application's secret) |

Scheduler: `DSN` (secret, its own database/user). Mock LinkedIn: `LISTENERHOST=0.0.0.0`, `WWWBASEURL`, `CLIENTID`, `CLIENTSECRET` (secret), and `BAL_CONFIG_DATA` for `redirectUris`. Tuning knobs with safe defaults (run batch sizes, timeouts, breakers, LinkedIn ceilings) are in each component's `config.bal`; set them the same way when needed.

Deploying to Choreo: [docs/runbooks/choreo-deploy.md](docs/runbooks/choreo-deploy.md).

### LinkedIn: mock or real

One switch in `local/.env`: **`LINKEDIN_USE_MOCK`**. `true` (the default) sends amplify-api and amplify-jobs to the `mock-linkedin` container. `false` sends them to real LinkedIn with your own non-prod app. `scripts/compose.sh` turns the flag into the right `LINKEDIN_*` values (Compose can't branch on a boolean), and `make`, `make e2e`, the load tests and JMeter all go through it. When you run Compose by hand, use `scripts/compose.sh up -d --build` instead of `docker compose --env-file local/.env up -d --build`, so the switch applies. It prints which mode it picked.

| `local/.env` | `LINKEDIN_USE_MOCK=true` | `LINKEDIN_USE_MOCK=false` |
|---|---|---|
| API / OAuth base URLs | `http://mock-linkedin:9090` / `:9091` | `https://api.linkedin.com` / `https://www.linkedin.com` |
| Browser authorization base | `http://localhost:19091` | empty (reuses the OAuth base) |
| Client id and secret | `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET` (made-up, shared with the mock) | `LINKEDIN_REAL_CLIENT_ID`, `LINKEDIN_REAL_CLIENT_SECRET` (your app; required) |
| ID-token validation | off | on, unless `LINKEDIN_REAL_ID_TOKEN_VALIDATION=false` (checks `iss`, `aud`, `exp` and the signature against LinkedIn's JWKS) |
| `LINKEDIN_REDIRECT_URI` | `http://localhost:3000/amplify/connect/callback` | exactly a redirect URI registered on your app |
| `WSO2_ORGANIZATION_URN` | `urn:li:organization:1477` (WSO2's page) | the company page your test posts belong to, `urn:li:organization:<id>`; keep One WSO2's `ONE_WSO2_AMPLIFY_LINKEDIN_ORG_URN` in `public/config.js` the same |

Change the flag, then `scripts/compose.sh up -d --no-deps amplify-api amplify-jobs` (or `make up`) to apply it.

Before you switch:

- **Use a non-prod LinkedIn app and a test member account.** With real credentials, a share from your laptop publishes to that member's real feed.
- **The app needs two products:** "Sign In with LinkedIn using OpenID Connect" and "Share on LinkedIn" (scopes `openid profile w_member_social`). Register your exact callback URL on it. amplify-api refuses a redirect URI that isn't `https://`, except plain `http://` with `ENVIRONMENT=local`.
- **Keep the real secret out of Git.** `local/.env` is gitignored (`local/*.env`); `local/.env.example` is not, so never put real values there.
- **The mock container still starts** (Compose depends on it), but only ever gets the made-up mock credentials, never your real app's. That's harmless locally.
- **The e2e script only works against the mock.** It scripts the mock's sign-in page and refuses to run when `LINKEDIN_USE_MOCK=false`. Set it back to `true` before `make e2e` or `make test-all`.

In Choreo it's the same settings per environment. Dev uses the LinkedIn Mock component, and prod uses `https://api.linkedin.com` / `https://www.linkedin.com` with the prod app (see [choreo-deploy.md](docs/runbooks/choreo-deploy.md) C2 and C6). The go-live check is that no LinkedIn Mock URL is set in prod.

Which tests use the mock:

| Tests | LinkedIn double |
|---|---|
| amplify-api unit | in-process `FakeLinkedIn` (`amplify-api/tests/read_fakes.bal`); never calls the mock |
| amplify-jobs unit | in-process `FakeLinkedIn` (`amplify-jobs/tests/fakes.bal`) |
| amplify-common unit | its own HTTP stub on 18210 to check the exact wire format (headers, payload) |
| amplify-domain | no LinkedIn calls |
| amplify-jobs IT (`integration`, `db-down-it`) | **real `mock_linkedin`** on 19190/19191, started by `scripts/test-all.sh` |
| e2e (`scripts/e2e-local.sh`) | **real `mock_linkedin`** in Compose: connect, share, publish |

## Docs

- Plan: [`docs/requirements/phase1-planned-todos.md`](docs/requirements/phase1-planned-todos.md)
- Design: [`architecture/solution/Phase 1/`](architecture/solution/Phase%201/)
- Decisions: [`architecture/decisions/`](architecture/decisions/)

## License

Apache License 2.0. See [LICENSE](../../LICENSE).
