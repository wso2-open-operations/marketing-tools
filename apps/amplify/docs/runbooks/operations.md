# WSO2 Amplify — Operations Runbook

Operational procedures for the Amplify phase 1 pilot. Every procedure gives the exact command or console action. Written 2026-10-17.

Owner: Developer. Escalation: PO team for product impact, WSO2 platform for Choreo/Aiven.

**Companion runbooks** (linked, not duplicated): [choreo-deploy.md](choreo-deploy.md) · [identity-setup.md](identity-setup.md) · [google-chat-webhook.md](google-chat-webhook.md) · [data-deletion-interim.md](data-deletion-interim.md) · [resilience-targets.md](resilience-targets.md) · checklist exception: data deletion.

Paths: `apps/…` = `apps/amplify/…`. Local commands run from `apps/amplify/`. In Choreo the same work is a console action (no shell) — those steps are marked **[console]**.

## 0. Quick reference

| What | How |
| --- | --- |
| Health / readiness | `GET /health` (always UP), `GET /ready` (api: DB + JWKS gated; jobs: DB gated) — not through the proxy |
| Run now (manual) | `POST {jobs}/runs` (Project-only, header `X-Amplify-Internal-Key` with either key) or wait for the scheduler |
| Maintenance now | `POST {jobs}/maintenance/partitions` (either key; also rotates token keys: `token_rotation` in the response) |
| Scheduler sync now | `POST /admin/scheduler/sync` (admin) |
| Retry one announcement | `POST /admin/announcements/{id}/retry` (admin) |
| Kill switches | `PUT /admin/settings` `sharing.enabled` / `announcements.enabled` |
| DB shell (local) | `docker compose exec postgres psql -U postgres -d amplify` |
| Refresh team rosters now | Restart Amplify Backend (the people-directory index lives in memory, §13) |

Alert list that pairs with these procedures: [choreo-deploy.md](choreo-deploy.md) §alerts (outbox `FAILED`, share failure rate, breaker `OPEN`, 5xx rate, scheduler job failures, `schedulerSync: PENDING`, partition-maintenance failures), plus **sessions idle in transaction > 30 s** (§11).

## 1. Reprocess FAILED outbox rows

The outbox is `messaging.outbox`, status ∈ {`PENDING`,`IN_PROGRESS`,`DONE`,`FAILED`} (`amplify-database/migrations/V008__announcement_messaging_audit_config.sql:55`). Rows reach `FAILED` when `settle` sees a `FAIL` or `RETRY` past `maxAttempts=8` (`amplify-jobs/run.bal:197-210`; `amplify-jobs/config.bal`).

**Gap — there is no generic "reprocess FAILED outbox" endpoint.** The only built-in retry is per-announcement (below). A generic reprocess is a **manual SQL** step; ADR-025 (§Consequences) requires this runbook to say so.

**1a. Retry one failed announcement (built-in).**
1. Find the id: the PO dashboard "Share health"/announcements view, or
   ```sql
   SELECT id, aggregate_id, event_type, attempts, last_error
   FROM messaging.outbox
   WHERE status='FAILED' AND event_type='CampaignRegistered'
   ORDER BY created_at DESC;
   ```
2. `POST /admin/announcements/{campaignId}/retry` (admin token). This resets that row to `PENDING`/`attempts=0` and audits `AnnouncementRetried` (`amplify-domain/modules/announcements/repository.bal`, `requeue`).

**1b. Manual reprocess of FAILED rows (gap — use with care).** Shape mirrors the announcement `requeue`; scope it by `event_type`/`aggregate_id` — **never reset all FAILED rows blindly** (some fail permanently).
1. Inspect first:
   ```sql
   SELECT event_type, count(*), max(last_error)
   FROM messaging.outbox WHERE status='FAILED' GROUP BY event_type;
   ```
2. Reset the rows you have decided to retry:
   ```sql
   UPDATE messaging.outbox
   SET status='PENDING', attempts=0, next_attempt_at=now(),
       locked_by=NULL, locked_until=NULL, last_error=NULL, processed_at=NULL
   WHERE status='FAILED' AND event_type='RepostRequested';   -- scope!
   ```
3. Trigger a run: `POST {jobs}/runs` (Project-only), or wait for `run.schedule`.
4. Confirm drain: re-run the §1 step 1 query; rows should move to `DONE`.

**Backstop:** `DONE` rows older than 30 days are purged by `messaging.purge_done_outbox(30)` in the nightly maintenance job (`V009`).

## 2. Rotate the token-encryption key

Keys live in the Choreo secret `TOKENKEYS` (`keyId:base64Key[,keyId:base64Key…]`) with `TOKENCURRENTKEYID` selecting the sealing key; both `amplify-api` and `amplify-jobs` read them (`amplify-api/outbound.bal`, `amplify-jobs/config.bal`).

**Rotation re-encrypts automatically (deep review 2026-10-17).** Old-key rows move to the active key in two ways (token-and-oauth-notes.md §1): `amplify-jobs` re-seals a token right after it opens it for a share, and the nightly `POST /maintenance/partitions` re-seals every remaining old-key row, up to 10,000 per pass. So an old key can leave the ring as soon as no row needs it; you don't have to wait for partitions to drop.

1. Generate a new 32-byte key: `openssl rand -base64 32`.
2. Append it to `TOKENKEYS`, e.g. `prod-1:<old>,prod-2:<new>`, and set `TOKENCURRENTKEYID=prod-2` **[console]** for **both** `amplify-api` and `amplify-jobs`, then redeploy both. (Keep the two in step: if api still seals with `prod-1`, new rows keep landing on the old key.)
3. Run the rotation pass: wait for the nightly maintenance, or call `POST {jobs}/maintenance/partitions` (Project-only). Read `token_rotation` in the response:
   - `DONE` with `failed = 0`: every row is on `prod-2`.
   - `PARTIAL`: the row cap stopped it; call it again.
   - `failed > 0`: some rows don't open with the ring (key missing, or tampered). They are left as they are; look at them before going on.
   - `NOT_CONFIGURED` / `FAILED`: token keys aren't set on jobs / the database refused. Fix that and rerun.
4. Confirm nothing still needs the old key:
   ```sql
   SELECT key_id, count(*) FROM connection.provider_token GROUP BY key_id;   -- must not list prod-1
   ```
5. Remove `prod-1` from `TOKENKEYS` **[console]** on both components and redeploy. (Always back the old secret value up somewhere safe first... a key removed too early makes every row it sealed unreadable, and those employees have to reconnect.)

**If a key is suspected compromised:** do steps 1-5 right away rather than on a schedule; the pass moves live rows off the bad key in minutes. Backups still hold ciphertext sealed with it until backup retention ends (threat model AMP-R2), so record the incident with that window. If the key may also have exposed plaintext tokens, have the affected employees reconnect (`DELETE /connections/linkedin`, then connect again) so LinkedIn issues new tokens.

## 3. Rotate the LinkedIn client secret

The LinkedIn developer app has one client id/secret; it is stored in Choreo secrets and read as `linkedinClientSecret` (`amplify-api/outbound.bal`, `amplify-jobs/config.bal`).

1. LinkedIn developer portal **[console, LinkedIn app admin]**: rotate the client secret.
2. Update the Choreo secret for `amplify-api` and `amplify-jobs` **[console]**.
3. Redeploy both components.
4. Smoke test: connect (real account in non-prod), share a campaign, confirm `POST /rest/posts` succeeds. Watch the run log `breakers` for `linkedinOAuth`/`linkedinApi`.
5. A `401` on share revokes the connection (`NEEDS_RECONNECT`) — after a secret change, affected users reconnect.

## 4. Rotate the Google Chat webhook

Full procedure: [google-chat-webhook.md](google-chat-webhook.md). Summary:

1. Chat space **[console]**: create a new incoming webhook ("Amplify").
2. Update the `CHATWEBHOOKURL` secret **[console]**, redeploy `amplify-jobs`.
3. Verify: `Save & Share Now` on a test campaign → card posts to the space.
4. **Delete the old webhook** (delete first if the old URL leaked).
5. A `404` on every card means the webhook was deleted — rotate. The URL is a bearer secret: never logged, never in `announcement.last_error`.

## 5. Bump `LinkedIn-Version`

The version is data: `LinkedIn-Version: 202610` (`amplify-common/modules/linkedin/types.bal:25`; `linkedinApiVersion` default in `amplify-jobs/config.bal:49`). No code change. Watch/sunset plan: [pilot-readiness.md](../requirements/pilot-readiness.md) §1.

1. Pick the target `YYYYMM` (newest stable, not current).
2. Dev: set `LINKEDIN_VERSION` for `amplify-jobs` **[console]** (and `BAL_CONFIG_VAR_LINKEDINVERSION` in `local/.env` for the mock). Redeploy.
3. Smoke test in dev (share a campaign; confirm `published_at` set).
4. Prod: same **[console]**, redeploy, one real share.
5. Record old→new + date in the plan and pilot-readiness §1.
6. **Risk if it slips:** every share fails 4xx (`PROVIDER_REJECTED`); no data lost (shares stay retryable).

## 6. Change the run schedule

Settings `run.schedule` (default `@every 5m`, min `minRunIntervalSeconds=60`), `run.enabled`, `maintenance.schedule` (default `0 2 * * *` UTC) live in `config.app_setting` and are pushed to the scheduler by `amplify-api` (`amplify-api/scheduler_sync.bal`).

1. `PUT /admin/settings` (admin) with `{"run.schedule":"@every 10m"}` etc.
2. The save commits, then `amplify-api` pushes to the scheduler (`changeSettings` → `touchesSchedule` → `syncScheduler`). The response carries `schedulerSync`.
3. **If `schedulerSync: PENDING`** (scheduler unreachable), force a reconcile: `POST /admin/scheduler/sync` (admin). Returns `{schedulerSync, jobs}` or `503 SCHEDULER_UNAVAILABLE`.
4. Verify: scheduler UI **[console/Project-only]** shows `amplify-run` with the new cron; or `GET {scheduler}/jobs`.
5. `NOT_CONFIGURED` means `schedulerUrl` is empty (local only).

## 7. Scheduler image bump + job-history purge

The scheduler is the pinned image `akorn/scheduler:1.7.8@sha256:07462c…`, UID 10014 (`amplify-scheduler/Dockerfile:23`). Bump **tag and digest together**.

1. Bump the pin in `amplify-scheduler/Dockerfile` (and `scripts/it-scheduler.sh`).
2. `make test-all` runs the scheduler tier against the real image (`scripts/it-scheduler.sh`).
3. Redeploy the scheduler **[console]**.
4. **Job-history retention.** `job_history` never trims itself upstream, so `amplify-scheduler/history-retention.sql` installs a trigger on the scheduler's **own** database that deletes rows older than 30 days after every insert the scheduler makes (no new caller, no Amplify code). Local Compose applies it with the `scheduler-retention` one-shot. In Choreo, run it once **[console, scheduler DB, as the scheduler user]** after the scheduler's first start (it creates `job_history`), and again after every scheduler version bump; `scripts/it-scheduler-history.sh` checks it against the pinned image. Verify: `SELECT count(*) FROM pg_trigger WHERE tgname = 'amplify_trim_job_history'` → 1. A one-off manual purge still works: `curl -X DELETE "http://scheduler:8080/jobs/amplify-run/history?before=<RFC 3339>"` (Project-only; no `before` deletes everything).

## 8. Restore the database

**Gap — no backup/restore automation in the repo.** The DB is a Choreo-managed PostgreSQL 18 on a plan **with backups** (Hobbyist has none) — [choreo-deploy.md](choreo-deploy.md) B1/B4. Confirm the plan has backups before the pilot.

1. Identify the restore target (latest good snapshot/PITR point) **[console, Aiven/Choreo]**.
2. Restore into a **new** database or the dev instance first; verify schemas/rows (employees, campaigns, ledger, connections) and `SELECT version FROM public.schema_version ORDER BY version` (the last `V###` the snapshot had).
3. If restoring in place: pause writes first — set `run.enabled=false` (procedure §6) or scale the scheduler to 0, so no run writes during the swap.
4. Run **Amplify DB Migrate** against the restored database **[console: Manual Task; locally `make seed`]** — optionally first with `BAL_CONFIG_VAR_DRYRUN=true` to list what it will apply. It applies only the `V###`/`S###` scripts newer than the snapshot (checksums in `public.schema_version`; a changed applied script stops it), then re-sets the `amplify_api`/`amplify_jobs`/`amplify_readonly` passwords from the current secrets, so the services log in even if the snapshot carries older role passwords.
5. Run partition upkeep once before re-enabling runs: `POST {jobs}/maintenance/partitions`. An old snapshot may lack today's token partition (created 7 days ahead) or this month's audit partition; until then OAuth connects and audit writes fail.
6. Re-enable runs; verify `GET {jobs}/ready` and amplify-api `/ready` UP, then a manual `POST {jobs}/runs` drains the outbox. `IN_PROGRESS` rows from the snapshot are released as stale by that run (lease expired).
7. **Double-post risk:** a share published after the snapshot point is `QUEUED` again in the restored data and its `RepostRequested` row is pending, so the run posts it to LinkedIn a second time (same risk class as ADR-025). For a restore older than a few minutes, list `sharing.share_request_v WHERE status = 'QUEUED' AND requested_at < <snapshot time>` and decide with the PO before re-enabling `sharing.enabled`.
8. Note: dropped token partitions survive in backups until **backup retention** ends — this is the true max time token ciphertext exists at rest.

**Restore test (plan M3/B4, still to do):** restore one backup into dev once and record the result here.

## 9. Data-deletion request

Phase 1 defers the built-in deletion path (audit C3; ADR-016). Use the **manual interim process**: [data-deletion-interim.md](data-deletion-interim.md). The pilot runs under an exception: checklist exception: data deletion (awaiting Security + Legal approval).

Key points: Remove Connection deletes tokens at once; the interim process anonymizes the employee row and drops provider identity; backups retain deleted data until backup retention ends. Record every request as an audit `EMPLOYEE_DATA_DELETION_MANUAL` row with the ticket id.

## 10. Kill switches

`sharing.enabled` and `announcements.enabled` (default **true**, `amplify-api/settings.bal:42-44`; seeded `amplify-database/seed/S003__app_settings.sql:31-32`).

1. Pause sharing: `PUT /admin/settings` `{"sharing.enabled":false}` (admin). API returns 409 `FEATURE_DISABLED` on new shares; `amplify-jobs` **defers** pending `RepostRequested` rows (not lost).
2. Pause announcements: `{"announcements.enabled":false}` — `retryAnnouncement` 409; jobs defer `CampaignRegistered` rows.
3. Resume by setting `true`. Settings cache is ~5 s, so the change takes effect within ~5 s on each replica (a local save invalidates that replica's cache; others pick it up within `settingsCacheSeconds`).
4. Use when: LinkedIn outage storm, Chat spam, or a PO request to stop the pilot's posting.

## 11. Routine monitoring

- **Run log:** each `POST /runs` returns a `RunReport` (`amplify-jobs/run.bal:29`): `claimed/succeeded/retried/deferred/failed`, `linkedinPosts`, `connections`, `breakers`, `durationMs`. Health of the pipeline is "failed=0 and deferred small".
- **Duplicate publish:** if a post went out but the employee's engagement for that target was already recorded (an earlier round), the share settles `PUBLISHED` on the existing engagement (row note "published; engagement already recorded"), with no second engagement or award. If no engagement of that employee matches, the share fails `PROVIDER_REJECTED` with `DUPLICATE_ENGAGEMENT`. Either way it never sits in `QUEUED` (ADR-025 amendment). A few `DUPLICATE_ENGAGEMENT` failures are worth a look but need no action; the employee can't be paid twice.
- **Readiness:** `GET /ready` → `database`, `breakers`. api: DB + JWKS gate readiness; jobs/roster (people directory)/LinkedIn (incl. `linkedinIdTokenJwks`) are reported, not fatal. jobs: DB gates; LinkedIn/Chat breakers and `runInProgress` are reported. Repeated pool timeouts ("Connection is not available") open the DB breaker, so a leaked pool fails readiness and the replica gets restarted.
- **Breakers:** `amplify_breaker_state{component,dependency}` gauge (0=closed, 1=half-open, 2=open, -1=unknown) — exported on `/ready`, viewed in Choreo metrics.
- **Outbox backlog:** gauges `amplify_outbox_pending`, `amplify_outbox_failed` and `amplify_outbox_oldest_pending_seconds` (-1 when nothing is pending), and an `outbox` block on amplify-jobs' `GET /ready` (`pending`, `inProgress`, `failed`, `oldestPendingSeconds`, `alerting`). **Alert when `amplify_outbox_oldest_pending_seconds` is over 3600** (`outboxAlertSeconds`) **or `amplify_outbox_failed` is above 0.** A row that waits that long means Novera, the Chat webhook or LinkedIn is unconfigured or down and every retry is deferring; nothing else reports it. Jobs also logs `Outbox backlog needs attention` (at most every 5 minutes) with the numbers. Fix the dependency, then see section 1 for failed rows.
- **Token partition runway:** gauge `amplify_token_partition_days_ahead` (days past today with a `provider_token` partition; -1 when unknown) and a `tokenPartitions` block on amplify-jobs' `GET /ready` (`daysAhead`, `alerting`). **Alert when it is below 3** (`tokenPartitionAlertDays`). The partitions are two weeks ahead (V009), jobs creates them at start-up and the daily maintenance run keeps them going; a connect on a day with no partition fails, so a falling number means the maintenance schedule is off or failing. Check the scheduler job `amplify-maintenance-partitions` and `POST /maintenance/partitions` on jobs; running it by hand restores the runway.
- **Partition upkeep:** nightly `POST /maintenance/partitions`; each drop audits `PARTITION_DROPPED`; `oauth_state` swept by `connection.sweep_oauth_state()`. The response's `token_rotation` should read `DONE` (or `NOT_CONFIGURED` where no keys are set); `failed > 0` needs a look (§2).
- **Sessions idle in transaction (alert, R-13).** On Ballerina 2201.13.x a runtime race can leave a session `idle in transaction` holding locks ([R-13 write-up](../reviews/2026-10-17-r13-transaction-race.md), [ADR-032](../../architecture/decisions/ADR-032-transaction-gate-ballerina-2201-13.md)). The transaction gate should stop it, and V013's 30 s `idle_in_transaction_session_timeout` on `amplify_api`/`amplify_jobs` ends such a session, so any hit means something got past both. Alert when this returns a row (run as the admin user, every few minutes):
  ```sql
  SELECT pid, usename, state_change, now() - state_change AS idle_for
  FROM pg_stat_activity
  WHERE state = 'idle in transaction' AND usename IN ('amplify_api', 'amplify_jobs')
    AND now() - state_change > interval '30 seconds';
  ```
  Also alert on bursts of 500s with `ConcurrentModificationException` in the api log right after a deploy (the start-up race the gate doesn't cover). Neither alert goes away until the upgrade to Ballerina 2201.14.1+.
- **Alerts:** [choreo-deploy.md](choreo-deploy.md) §alerts.
- **Pilot success metrics:** [pilot-readiness.md](../requirements/pilot-readiness.md) §5.

## 12. Database TLS (CA file per environment)

`amplify-api`, `amplify-jobs` and **Amplify DB Migrate** default `dbSslMode` to `VERIFY_FULL`, which checks the server certificate against a CA file and the host name. Each one logs a start-up warning when the host isn't local and the server isn't verified. Compose sets `BAL_CONFIG_VAR_DBSSLMODE: DISABLE` (local only).

Per environment (dev, prod), for each of the three components **[console]**:

1. Download the managed Postgres CA certificate (Aiven console: the service's **CA certificate**).
2. Choreo: **Configs & Secrets > File Mount**, mount it as a file, e.g. `/home/choreo/db-ca/ca.pem`.
3. Set `BAL_CONFIG_VAR_DBSSLROOTCERT` to that path (it's in every component's descriptor as "DB CA certificate file path (file mount)"). Leave `BAL_CONFIG_VAR_DBSSLMODE` unset so the `VERIFY_FULL` default applies.
4. Redeploy, then check the logs: no `Database TLS mode ... doesn't verify the server` warning, and `/ready` is UP (api, jobs). For DB Migrate (a dry run doesn't connect, so it can't test this): on its next run, check the log has no TLS warning. A bad CA path or host name fails the run at its first query, before any script is applied.
5. When the provider rotates its CA, replace the mounted file and redeploy all three.

## 13. People directory (team rosters)

My Team and the Team page's team scope come from people-app's `GET /employees/basic-info` (ADR-019). Amplify Backend fetches the whole directory once, groups everyone by sub-team (team when there's none) and keeps that index (teams, names and houses) in memory for 24 hours (`ROSTERCACHESECONDS`, default 86400). Nothing is written to the database or the logs.

- **Someone moved team and still sees the old one.** Expected for up to 24 hours. To pick it up now, restart Amplify Backend; the next leaderboard read fetches the directory again.
- **`teamStatus: NO_TEAM` for one person.** They aren't in the directory (only Active and Marked leaver employees are), their people-app record has no team, or their Amplify email doesn't match their people-app `workEmail`. Compare the two emails first.
- **`teamStatus: UNAVAILABLE` for everyone.** The directory has never loaded since the last start. Check, in order:
  1. The Backend log for `People directory not configured`: the `PEOPLEDIRECTORY*` settings are empty (choreo-deploy C5/C7).
  2. `People directory answered 500`: people-app doesn't recognise the client. Its `directoryClientIds` doesn't list Amplify's client id, or `clientIdClaim` names the wrong claim. People-app's log says "Malformed Invoker info object!".
  3. `People directory answered 403`: the URL isn't `/employees/basic-info`.
  4. `/ready` shows the `roster` breaker `OPEN`: people-app or the gateway is down. It closes by itself after 30 s once they're back.
- **A refresh fails after a good load.** Amplify keeps serving the old index and logs `People directory refresh failed; using the cached teams`. Nothing to do unless it lasts; teams just stop updating.
- **Rotating the client secret.** New secret on the Choreo connection, update `PEOPLEDIRECTORYCLIENTSECRET`, redeploy the Backend. People-app needs no change: it lists the client id, not the secret.

## 14. Rotate the internal key and the scheduler key (ADR-039)

Two secrets guard amplify-jobs: `INTERNALAPIKEY` (full access; amplify-api's own triggers) and `SCHEDULERAPIKEY` (only `POST /runs` and `POST /maintenance/partitions`; set by amplify-api as a header on the two scheduler jobs). Each is the same value on Amplify Backend and Amplify Jobs, at least 32 characters, and the two must differ (both components refuse to start otherwise). Rotate on a leak, an owner change or yearly.

1. Generate a new value: `openssl rand -hex 24`.
2. **Scheduler key:** set `SCHEDULERAPIKEY` on Amplify Jobs and on Amplify Backend and redeploy both. Order does not matter much: a run missed while they disagree is caught by the next tick.
3. **Then force a scheduler sync** so the registered jobs carry the new value: `POST /admin/scheduler/sync` (admin); the Backend also syncs at start-up. Check the response lists both jobs as `UPDATED`. Until then the scheduler still sends the old key and Jobs answers 401 (`Internal call refused` in the Jobs log, `keySent=true`).
4. **Internal key:** set `INTERNALAPIKEY` on both and redeploy. No scheduler sync needed (the scheduler never holds it). "Save & Share Now" falls back to the scheduled run while the two disagree.
5. A `403` in the Jobs log (`scheduler key on a route it may not call`) means something other than `/runs` or `/maintenance/partitions` was called with the scheduler key: check the job URIs in the scheduler.
