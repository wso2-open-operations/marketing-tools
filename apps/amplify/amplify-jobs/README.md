# amplify-jobs

The Amplify worker (Ballerina). It does the background work: announcements, LinkedIn reposts, scoring and upkeep.

## What it is and how it is triggered

amplify-jobs has no timer of its own (ADR-003). Two callers start its work:

- The scheduler (the pinned `akorn/scheduler` image, ADR-026) calls `POST /runs` and `POST /maintenance/partitions` on the schedules in `config_app_setting`. amplify-api registers those jobs (`amplify-api/scheduler_sync.bal`).
- amplify-api calls it right away for "Save & Share Now".

It is reachable inside the Amplify project only and is never published (`workload.yaml`: `visibility: project`, port 9091).

Every route except `GET /health` and `GET /ready` needs the header `X-Amplify-Internal-Key` (ADR-039). There are two keys, each a secret of at least 32 characters, with different values:

| Key | Setting | What it opens |
| --- | --- | --- |
| Internal key | `internalApiKey` | Every route. Used by amplify-api |
| Scheduler key | `schedulerApiKey` | Only `POST /runs` and `POST /maintenance/partitions`. Any other route answers 403 |

A missing or wrong key answers 401. The worker refuses to start without both keys, or when they are equal (`checkKeys` in `auth.bal`). Keys are compared in constant time.

## Routes

Defined in `service.bal`; the contract is `openapi.yaml`.

| Route | What it does |
| --- | --- |
| `GET /health` | Liveness. Up when the process is |
| `GET /ready` | Readiness. Reports the database, each breaker, the outbox backlog and the token partition runway. Answers 200 unless the database is not configured (`dbHost` empty), because Choreo stops routing on any non-2xx |
| `POST /runs` | The Run. Synchronous. Returns the run log. `202 SKIPPED` while another run holds the lock, `503` when the database is not reachable. Optional `X-Correlation-ID` header |
| `POST /maintenance/partitions` | Daily upkeep (see Maintenance). `202 SKIPPED` when another pass is running |
| `POST /maintenance/leavers` | Runs only the leaver sweep (the daily upkeep includes it) |
| `POST /maintenance/rebuild-recognition` | Rebuilds every leaderboard and standing table from the ledger and returns the new standing version. The ledger is the source of truth, so this is always safe |

## The Run

`run.bal` does one pass of the outbox:

1. Takes a lock (an in-process flag plus a session advisory lock, so one run at a time across replicas).
2. Releases rows left locked by a dead run, reads the settings, and counts connections that are expiring or need a reconnect.
3. Claims rows in batches with `FOR UPDATE SKIP LOCKED`, hands each to the handler for its event, and settles it.
4. Returns the run log (`RunReport` in `run.bal`).

Handlers live in `handlers.bal`, one per event:

| Outbox event | What it does |
| --- | --- |
| `CampaignRegistered` | Announces the campaign once. Novera is the primary channel (`POST /internal/notifications`, `novera.bal`) when it is on and configured. The Club card in Google Chat (`WebhookChat` in `ports.bal`) is then best effort. With Novera off, the webhook is the only channel. Waits if the post is not open yet, skips closed or archived ones, defers if `announcements.enabled` is off or no channel is configured |
| `RepostRequested` | Opens the employee's encrypted token in memory and calls `POST /rest/posts` as the employee, then records the published share and its engagement in one transaction. Clears the commentary once published. Never posts twice on a rerun (`PUBLISH_IN_FLIGHT` marker in `constants.bal`). A 401 revokes the connection (`NEEDS_RECONNECT`). A 429, 5xx or timeout retries. A 403 or other 4xx fails the share. A token on an old key is re-sealed on use, best effort |
| `EngagementRecorded` | Looks up the point rule in force, appends one row to the points ledger (once per action per post per person) and updates the recognition tables in the same transaction |
| `ExternalShareApproved`, `ExternalShareAmplified` | Nothing to do. amplify-api wrote the award when the PO decided (ADR-024). The row is marked done |
| Every other event | No phase 1 subscriber. The row is marked done |

Each handler returns one of four outcomes (`outcome.bal`):

| Outcome | Meaning | What the Run does |
| --- | --- | --- |
| `DONE` | Handled, or nothing to do | Marks the row done |
| `RETRY` | Transient failure (429, 5xx, timeout, open breaker, handler error) | Backs off and tries again. After `maxAttempts` the row fails |
| `DEFER` | Not now: a kill switch is off, a ceiling is reached, a dependency is not configured, the campaign is not open yet | Due again later. The attempt is not counted |
| `FAIL` | Permanent failure | Marks the row `FAILED` |

There is no HTTP-level retry on LinkedIn posts or the Chat webhook, because a retry after a lost response could post twice. The outbox retries instead (ADR-025). Kill switches live in `config_app_setting`: `sharing.enabled` and `announcements.enabled`. Turning one off defers its rows. Nothing is lost.

Files: `run.bal`, `handlers.bal`, `outcome.bal`, `ports.bal`, `novera.bal`, `outbound.bal`.

## Maintenance

`POST /maintenance/partitions` (`runMaintenance` in `service.bal`) does, in order:

- Creates token and audit partitions ahead, drops expired token days and audit months (each one audited), purges finished outbox rows and expired OAuth states (`store:runPartitionMaintenance`, which calls the V009 functions).
- Purges expired `Idempotency-Key` records.
- Re-seals token rows written under an older key with the active one (`token_rotation` in the report, never fatal).
- Runs the leaver sweep (`leaver_sweep` in the report).

One pass at a time across replicas. At start-up the worker also creates the next 14 days of token partitions in the background (`partitions.bal`).

## The leaver sweep

ADR-040 and ADR-045. `leavers.bal` compares the employees Amplify holds with the HR Entity GraphQL directory and erases the people who are gone, through the audited erase function (V018). It reads the work email only. It never fails: every problem becomes a `skipped` reason or a count in the report.

Modes (`leaverSweepMode`): `OFF` (default, does nothing), `DRY_RUN` (reports who would be erased), `ERASE`. Guards that skip the sweep and erase nobody:

- The directory is unreachable, or lists fewer than `leaverMinDirectorySize` people.
- More than `leaverMaxPerRun` leavers, or more than `leaverMaxPercent` percent of the known employees.

A person must also be away from Amplify for `leaverGraceDays` days. Start-up fails when the mode is not `OFF` and `hrEntityBaseUrl` is empty.

## Settings

All are `configurable`. In Choreo they arrive as `BAL_CONFIG_VAR_*` (see `workload.yaml`). Secrets are marked.

| Group | Settings | File |
| --- | --- | --- |
| Listener | `port` (9091) | `service.bal` |
| Keys | `internalApiKey` (secret), `schedulerApiKey` (secret), both required | `auth.bal` |
| Database | `dbHost` (empty gives 503), `dbPort`, `dbName`, `dbUser`, `dbPassword` (secret), `dbSchema` (default the user name), `dbSslMode` (default `VERIFY_FULL`), `dbSslRootCert`, `dbConnectTimeoutSeconds`, `dbPoolAcquireTimeoutSeconds`, `dbBreakerFailureThreshold`, `dbBreakerWindowSeconds`, `dbBreakerResetSeconds`, `dbMaintenanceSocketTimeoutSeconds`, `leaderboardTopN` | `database.bal` |
| Run tuning | `runBatchSize` (25), `runMaxRows` (200), `runMaxSeconds` (240), `runLockLeaseSeconds` (300), `maxAttempts` (8), `backoffBaseSeconds` (30), `backoffMaxSeconds` (3600), `deferSeconds` (900) | `config.bal` |
| LinkedIn | `linkedinApiBaseUrl`, `linkedinAuthBaseUrl`, `linkedinClientId` (empty defers sharing), `linkedinApiVersion`, `linkedinTimeoutSeconds`, `linkedinApiResilience`, `linkedinMaxPostsPerRun` (50), `linkedinMaxPostsPerDay` (1000) | `config.bal` |
| Google Chat | `chatWebhookUrl` (secret), `chatAllowInsecureHttp`, `chatCardAvatarUrl`, `chatDefaultImageUrl`, `chatSpace`, `chatTimeoutSeconds`, `chatResilience`, `chatMinIntervalSeconds` (1), `sharePageBaseUrl`, `amplifyOnWebhook` | `config.bal` |
| Novera | `amplifyOnNovera`, `noveraNotifyUrl`, `noveraTokenUrl`, `noveraClientId`, `noveraClientSecret` (secret), `noveraScopes`, `noveraTimeoutSeconds`, `noveraAllowInsecureHttp` | `config.bal` |
| Token keys | `tokenKeys` (secret), `tokenCurrentKeyId` | `config.bal` |
| Alerts | `outboxAlertSeconds`, `outboxBacklogCacheSeconds`, `outboxAlertLogIntervalSeconds`, `tokenPartitionAlertDays` | `backlog.bal`, `partitions.bal` |
| Leaver sweep | `leaverSweepMode`, `leaverGraceDays`, `leaverMinDirectorySize`, `leaverMaxPerRun`, `leaverMaxPercent` | `leavers.bal` |
| HR Entity directory | `hrEntityBaseUrl`, `hrEntityTimeoutSeconds`, `hrEntityTokenUrl`, `hrEntityClientId`, `hrEntityClientSecret` (secret), `hrEntityPageSize` (1000), `hrEntityRetryCount` / `hrEntityRetryInterval` / `hrEntityRetryBackOffFactor` / `hrEntityRetryMaxWaitInterval` (3 / 3.0 / 2.0 / 20.0), `hrEntityStatuses` (`Active`, `Marked leaver`) | `leavers.bal` |

Start-up check (`validateRunConfig` in `ready.bal`): `runLockLeaseSeconds` must exceed `runMaxSeconds` plus the longest external call. Otherwise the next run could release a row that is still being handled, and a LinkedIn post could go out twice.

Run defaults: backoff doubles from 30 s up to 3600 s with equal jitter (half fixed, half random). Rows still unhandled when `runMaxSeconds` runs out go back untouched. Google Chat is limited to one message per second.

The HR Entity client has a timeout and an optional OAuth2 client-credentials token (an empty `hrEntityTokenUrl` sends no auth header, for local stubs). It retries on a connection error or a 500, 502, 503 or 504 (`hrEntityRetryCount` 3, `hrEntityRetryInterval` 3.0 s, `hrEntityRetryBackOffFactor` 2.0, `hrEntityRetryMaxWaitInterval` 20 s, the same as the other apps that read the HR Entity). It has no breaker. A read ends on an empty page, with at most 100 pages.

## Safety rules

- A handler re-reads its aggregate before any external call, so `POST /runs` is safe to call at any time and from several places at once.
- Tokens, commentary and the webhook URL are never logged or audited. Directory errors never carry the response body, because it names people.
- Database access goes through a breaker (opens at 3 transient failures in 60 s, tries again after 30 s). LinkedIn, Chat and Novera each have their own breaker and pool. Their trouble defers or retries rows; only the database makes the service unready.
- The correlation id travels with each row from the request that created it, through the handler, into audit and outbox writes and outbound calls.

## Files

| File | What |
| --- | --- |
| `service.bal` | The HTTP routes and the maintenance steps |
| `auth.bal` | The two keys and the interceptor |
| `run.bal` | The Run: lock, stale release, sweep, claim batches, settle, run log |
| `handlers.bal` | One handler per event, plus the LinkedIn failure rules |
| `outcome.bal` | The four outcomes and the backoff |
| `ports.bal` | Ports (`RunStore`, `Store`, `RunLock`, `ChatPort`) and their Postgres or webhook implementations |
| `novera.bal` | Client for Novera's notifications endpoint |
| `outbound.bal`, `config.bal` | LinkedIn adapter, Chat webhook, Novera client, token cipher, run tuning |
| `leavers.bal` | The leaver sweep and its HR Entity reader |
| `partitions.bal` | Start-up partitions and the token partition runway |
| `backlog.bal` | Outbox backlog report and alert |
| `ready.bal` | The readiness report and the run-config check |
| `database.bal` | Lazy database client with its breaker, the single-connection lock client, the maintenance client |
| `types.bal`, `constants.bal` | Report types and shared constants |
| `openapi.yaml`, `workload.yaml`, `Dockerfile` | Contract and deploy descriptors |
| `img/WSO2-Amplify-Poster-Default.png` | Source asset for the default card image. Host it on a WSO2 CDN and set `chatDefaultImageUrl` |
| `tests/` | See below |

## Build and test

Publish `amplify_common`, then `amplify_domain`, to the local Ballerina repository first. Then, from this folder:

```sh
bal build
bal test
AMPLIFY_IT=true bal test --groups integration   # needs a migrated PostgreSQL and mock_linkedin
```

`tests/Config.toml` holds test-only keys. Unit tests use in-memory fakes (`tests/fakes.bal`) and cover the Run (`run_test.bal`, `round2_test.bal`), handlers, readiness, backlog, partitions, leavers, the service routes and keys, the Novera and webhook clients, and a database outage (`db_down_test.bal`). `tests/integration_test.bal` is the group `integration`, off unless `AMPLIFY_IT=true`. Integration setup: `docs/migrations/README.md`.

## What it does not do

- It runs no timer. Nothing happens unless a caller asks.
- It does not retry LinkedIn posts or the Chat webhook over HTTP.
- It does not serve end users. amplify-api and the scheduler are its only callers.
- It does not score PO decisions. amplify-api does that (ADR-024).
