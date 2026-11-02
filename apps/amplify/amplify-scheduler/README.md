# amplify-scheduler

The pinned `akorn/scheduler` image (v1.7.8) that triggers Amplify's background work. It has no code of its own. It calls two `amplify-jobs` endpoints on a schedule (ADR-026). See [CLAUDE.md](CLAUDE.md) for the rules (internal network only, own Postgres database, version bump steps).

## Jobs

amplify-api owns both jobs (`amplify-api/scheduler_sync.bal`) and pushes them into the scheduler collection `amplify` at startup and on `POST /admin/scheduler/sync`. The schedules come from `config.app_setting`. A manual edit in the scheduler UI is overwritten by the next sync, so change the setting instead.

```
┌────────────────────────────────┬────────────────┬──────────────────────────────┬────────────────────────────┬────────────┬──────────┐
│             Job id             │      Name      │      Schedule (default)      │           Calls            │   Retry    │ Deadline │
├────────────────────────────────┼────────────────┼──────────────────────────────┼────────────────────────────┼────────────┼──────────┤
│                                │                │ @every 5m (setting           │                            │ 1 retry,   │          │
│ amplify-run                    │ Amplify Run    │ run.schedule, min 60s;       │ amplify-jobs POST /runs    │ 30s apart  │ 300s     │
│                                │                │ run.enabled toggles it)      │                            │            │          │
├────────────────────────────────┼────────────────┼──────────────────────────────┼────────────────────────────┼────────────┼──────────┤
│                                │ Amplify        │ 0 2 * * * (daily 02:00;      │ amplify-jobs POST          │ 2 retries, │          │
│ amplify-maintenance-partitions │ partition      │ setting                      │ /maintenance/partitions    │  60s apart │ 180s     │
│                                │ maintenance    │ maintenance.schedule)        │                            │            │          │
└────────────────────────────────┴────────────────┴──────────────────────────────┴────────────────────────────┴────────────┴──────────┘
```

### amplify-run

The main worker pass. Every call to `amplify-jobs POST /runs` does one synchronous Run: it sweeps for stale work, claims a batch of outbox events (`FOR UPDATE SKIP LOCKED`) and settles each one as done, retry, defer or fail. The handlers do the sharing, announcements and scoring:

- `CampaignRegistered` posts the Chat card.
- `RepostRequested` makes the LinkedIn repost.
- `EngagementRecorded` awards points.

It returns the run log in the response.

- **Overlap:** only one Run holds the lock at a time. If a Run is still going, the call returns `202 SKIPPED`, and the scheduler counts that as success.
- **Deadline:** 300s, which must stay above amplify-jobs `runMaxSeconds` (240). Otherwise the scheduler cancels a healthy run.
- **Retry:** one retry, for a 5xx or a dropped connection.
- **Switch it off:** set `run.enabled` to `false`. This stops the sharing, announcements and scoring pass.

### amplify-maintenance-partitions

The nightly housekeeping call to `amplify-jobs POST /maintenance/partitions`. It does three things:

- Runs the messaging partition maintenance (`messaging.run_partition_maintenance()`), which keeps the daily token and event partitions rolling forward.
- Purges expired `Idempotency-Key` rows.
- Rotates the token encryption key. A token on an old key is also re-sealed on use, so this is best effort.

The response carries a report, including `token_rotation`. A missed night is safe, because the next call picks up whatever is left.

## Sample history

The scheduler records each call in its own database, table `job_history`. These are the five newest `amplify-run` rows from the local stack on 2026-10-21 (times in UTC):

| Started | Job | Status | Secs | Retries | Message |
|---|---|---|---|---|---|
| 10-21 19:32:57 | amplify-run | completed | 0.87 | 0 | |
| 10-21 19:27:57 | amplify-run | completed | 2.80 | 0 | |
| 10-21 19:22:57 | amplify-run | completed | 0.27 | 0 | |
| 10-21 19:17:57 | amplify-run | completed | 0.22 | 0 | |
| 10-21 19:12:57 | amplify-run | completed | 0.15 | 0 | |

Look at it yourself (local Compose):

```sh
docker compose --env-file local/.env exec -T scheduler-db psql -U scheduler -d scheduler -c \
  "select h.started, h.job_id, s.name as status, h.finished - h.started as took, h.retry_count, h.message
     from job_history h join job_history_status s on s.id = h.status_id
    order by h.started desc limit 25"
```

`history-retention.sql` trims `job_history` to 30 days. Compose applies it with the `scheduler-retention` one-shot. Choreo needs it run once by hand (operations runbook §7).
