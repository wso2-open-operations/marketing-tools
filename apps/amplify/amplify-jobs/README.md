# amplify-jobs

The Amplify worker. It has no timer of its own: the scheduler (ADR-026) calls it on a schedule, and "Save & Share Now" calls it right away (ADR-003). It is reachable inside the Amplify project only, never published.

Two kinds of work live here:

- **The Run** (`POST /runs`): drains the Postgres outbox. This is where announcements, LinkedIn reposts and scoring happen.
- **Maintenance** (`POST /maintenance/...`): daily upkeep and a rebuild tool.

## The jobs

| # | Job | Trigger | What it does |
| --- | --- | --- | --- |
| 1 | **The Run** | `POST /runs` | Claims outbox rows in batches (`FOR UPDATE SKIP LOCKED`), hands each to the handler for its event, and settles the row as done, retry, defer or failed. Also releases rows left locked by a dead run and counts connections that are expiring or need a reconnect. Returns the run log. A second caller gets `202 SKIPPED` while a run is going |
| 2 | **Announce a campaign** | outbox event `CampaignRegistered` | Builds the Club card (image, title, summary, button to the share page in One WSO2) and posts it to the Google Chat space through the incoming webhook. Once per campaign. Waits if the post isn't open yet, skips closed or archived ones, defers if announcements are switched off or the webhook isn't configured |
| 3 | **Repost on LinkedIn** | outbox event `RepostRequested` | Opens the employee's encrypted token in memory, calls `POST /rest/posts` as the employee (`REPOST` or `REPOST_COMMENTARY`, or the `SHARE*` fallback kinds), then records the published share and its engagement in one transaction. Clears the commentary once it is published. Never posts twice on a rerun. A 401 revokes the connection (`NEEDS_RECONNECT`). A 429, 5xx or timeout is retried with backoff. A 403 or other 4xx fails the share |
| 4 | **Score an engagement** | outbox event `EngagementRecorded` | Looks up the point rule in force at the time, appends one row to the points ledger (once per action per post per person) and updates the recognition tables in the same transaction |
| 5 | **Acknowledge PO decisions** | outbox events `ExternalShareApproved`, `ExternalShareAmplified` | Nothing to do. `amplify-api` already wrote the award when the PO decided (ADR-024). The row is just marked done |
| 6 | **Acknowledge the rest** | every other event (`CampaignAnnounced`, `ConnectionReady`, `RepostFailed`, `Points*`, and so on) | No phase 1 subscriber, so the row is marked done |
| 7 | **Partition and housekeeping upkeep** | `POST /maintenance/partitions` (daily, from the scheduler) | Creates token and audit partitions ahead, drops expired token days and audit months (each one audited), purges finished outbox rows and expired OAuth states, purges expired `Idempotency-Key` records, and re-seals tokens written under an older key with the active one. The report says what was done |
| 8 | **Rebuild recognition** | `POST /maintenance/rebuild-recognition` (by hand) | Rebuilds every leaderboard and standing table from the ledger and returns the new standing version. The ledger is the source of truth, so this is always safe |

Other endpoints: `GET /health` (always up if the process is) and `GET /ready` (database reachable; reports each breaker's state).

## How the Run treats each row

Each handler returns one of four outcomes:

| Outcome | Meaning | What the Run does |
| --- | --- | --- |
| `DONE` | Handled, or nothing to do | Marks the row done |
| `RETRY` | Transient failure (429, 5xx, timeout, open breaker, handler error) | Backs off and tries again. After `maxAttempts` the row fails |
| `DEFER` | Not now: a kill switch is off, a ceiling is reached, a dependency isn't configured, the campaign isn't open yet | Due again later. The attempt isn't counted |
| `FAIL` | Permanent failure | Marks the row `FAILED` |

Defaults (all `configurable`, see `config.bal`):

| Setting | Default |
| --- | --- |
| Rows per batch / per run | 25 / 200 |
| Run time budget | 240 s (rows still unhandled go back untouched) |
| Row lock lease | 300 s |
| `maxAttempts` | 8 |
| Backoff | 30 s, doubling, capped at 3600 s, with jitter (half fixed, half random) |
| Deferral wait | 900 s |
| LinkedIn posts per run / per UTC day | 50 / 1000 |
| Google Chat spacing | 1 message per second |

There is no HTTP-level retry on LinkedIn posts or the Chat webhook, because a retry after a lost response could post twice. The outbox retries instead (ADR-025).

Kill switches live in `config.app_setting`: `sharing.enabled` and `announcements.enabled`. Turning one off defers its rows. Nothing is lost.

## Safety rules

- A handler re-reads its aggregate before any external call, so `POST /runs` is safe to call at any time and from several places at once.
- Tokens, commentary and the webhook URL are never logged or audited.
- Database access goes through a breaker (opens at 3 transient failures in 60 s, tries again after 30 s). LinkedIn and Google Chat each have their own breaker and connection pool. LinkedIn and Chat trouble defers or retries rows; only the database makes the service unready.
- The correlation id travels with each row from the request that created it, through the handler, into audit and outbox writes and outbound calls.

## Files

| File | What |
| --- | --- |
| `service.bal` | The HTTP endpoints |
| `run.bal` | The Run: lock, stale release, sweep, claim batches, settle, run log |
| `handlers.bal` | One handler per event, plus the LinkedIn failure rules |
| `outcome.bal` | The four outcomes and the backoff |
| `ports.bal` | Ports (`RunStore`, `Store`, `RunLock`, `ChatPort`) and their Postgres or webhook implementations. Tests use in-memory fakes (`tests/fakes.bal`) |
| `outbound.bal`, `config.bal` | LinkedIn adapter, Chat webhook, token cipher and all tuning settings |
| `database.bal` | Lazy database client with its breaker, plus the single-connection lock client |
| `ready.bal` | The readiness report |

## Build and test

Publish `amplify_common`, then `amplify_domain`, to the local Ballerina repository first. Then, from this folder:

```sh
bal build
bal test
AMPLIFY_IT=true bal test --groups integration   # needs a migrated Postgres 18 and mock_linkedin
```

The listener port is the `port` setting (default 9091). Integration test setup: `docs/migrations/README.md`.
