# ADR-025: amplify-jobs Run delivery semantics, deferral and outbound resilience

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan M6, M9; ADR-003, ADR-018, ADR-024

## Context

Building the Run (M6) needed answers the plan and data model left open: what `POST /runs` returns, how one run at a time holds across replicas, what "retry" means for calls that post things (LinkedIn, Google Chat), what to do with rows that can't run yet, and where the HTTP breakers live.

## Decision

1. **`POST /runs` runs synchronously** and returns the structured run log (run id, correlation id, claimed, succeeded, retried, deferred, failed, stale locks released, LinkedIn posts, connection sweep counts, breaker states, duration). A caller that arrives while a run is in progress gets **202 `SKIPPED` / `RUN_IN_PROGRESS`**, which is not a failure. DB down → 503. Any scheduler can call it: the owner chose `akornatskyy/scheduler` to replace amplify-cron in a follow-up milestone, so `POST /runs` and `POST /maintenance/*` stay plain HTTP endpoints.
2. **One run at a time:** an in-process flag plus a PostgreSQL **session** advisory lock (`pg_try_advisory_lock`) held on a dedicated single-connection client, so lock and unlock share a session. If that session dies the lock goes with it; `FOR UPDATE SKIP LOCKED` still keeps two runs off the same rows.
3. **Claim and lease:** a claim sets `IN_PROGRESS`, `locked_by` = run id, `locked_until` = now + lease (300 s) and counts the attempt. Only the lock holder can settle a row. Each run first releases rows whose lease ran out back to `PENDING`, **keeping the counted attempt**, so a row that keeps killing runs still reaches `FAILED`.
4. **No HTTP-level retry on calls that create things** (`POST /rest/posts`, the Chat webhook). A retry after a lost response would post twice. They retry through the outbox: exponential backoff with **equal jitter** (half of `min(max, base·2^(n-1))` fixed, half random; base 30 s, cap 1 h), `FAILED` after `maxAttempts` (8). Retry stays configurable (`HttpResilience.retryCount`) for idempotent calls.
5. **At-least-once, guarded.** Before posting, the handler re-reads the aggregate: an announcement already `SENT`, or a share already `PUBLISHED`/`FAILED`, or an event from an older share round (`attempts` mismatch) is acknowledged without a call. The engagement unique key and the ledger reference (`ON CONFLICT DO NOTHING`) stop a second engagement or award. **Residual risk, accepted:** if LinkedIn or Chat accepted the call and the process died (or the DB write failed) before the result was stored, the next attempt posts again. LinkedIn's duplicate-content check usually refuses an identical repost (422 → share `FAILED`, `PROVIDER_REJECTED`).
6. **Deferral costs no attempt.** Kill switch off (`sharing.enabled`, `announcements.enabled`), LinkedIn or Chat not configured, the per-run / per-day LinkedIn ceiling reached, or a campaign not open yet (card waits for `opens_at`) → the row goes back to `PENDING` with its attempt given back. Closed or archived campaigns are not announced.
7. **Handler outcomes:** LinkedIn 401 → `connection.revoked_at` + `ConnectionRevoked`, share `FAILED` `NEEDS_RECONNECT`; 429/5xx/timeout/open breaker → retry, share stays `QUEUED` (B14), `RETRIES_EXHAUSTED` on the last attempt; other 4xx → share `FAILED` `PROVIDER_REJECTED`. A connection that isn't `ACTIVE`/`EXPIRING` or a missing token row fails the share with `NEEDS_RECONNECT` without a call. Chat 429/5xx → retry; 400 or retries spent → `announcement.failed_at` (admin retry re-queues, ADR-024).
8. **Jobs creates the `announcement` row** on the first `CampaignRegistered` it handles (`amplify_api` can only read the table).
9. **`ExternalShareApproved` / `ExternalShareAmplified` are acknowledged without scoring.** amplify-api already wrote the award in the decision transaction (ADR-024 item 1); checked, so there is no double award. `EngagementRecorded` is scored in jobs at the rule **in force when the engagement happened**, `ON CONFLICT (reference) DO NOTHING`, with the recognition upkeep in the same transaction (B12).
10. **LinkedIn ceilings:** `linkedinMaxPostsPerRun` (50) and `linkedinMaxPostsPerDay` (1000, counted from shares published since 00:00 UTC). No separate per-member ceiling: phase 1 allows one share per campaign per employee, far below the member daily limit.
11. **Outbound resilience** (`amplify_common.resilience`): every dependency gets its own `http:Client` with its own pool (bulkhead), a circuit breaker (rolling window 60 s, threshold 0.5, reset 30 s, counts 429/5xx and timeouts) and a timeout, all from config. The LinkedIn adapter keeps separate API and OAuth clients, so amplify-api gets the OAuth breaker too. Breaker states go into the run log.
12. **Correlation id** travels outbox row → handler → audit/outbox writes (`store:Actor.correlationId`) → `X-Correlation-ID` on the LinkedIn and Chat calls. Rows without one use the run id.
13. **Not built in phase 1:** the pre-coin verification pass (ADR-018: no read scope; points stay `HELD`) and the share-metrics pass (phase 2). The connection sweep **reports** expiring / needs-reconnect counts in the run log; the employee sees the reconnect banner from `GET /me` (derived status). Sending reminders waits for the reminder channel decision (phase1-domains open question 3), so `last_reminded_at` isn't written yet.

## Consequences

- A scheduler should treat `POST /runs` 2xx (200 or 202) as success and anything else as failure.
- A share or card can still go out twice in the narrow window in item 5; the runbook for "reprocess FAILED outbox rows" must say so.
- `amplify_common` is 0.4.0 (new `resilience` module, `ShareCommand.correlationId`, `WebhookClient.post(…, correlationId)`).

## Amendment (2026-10-17)

From deep review rounds 1-2 ([round 2 handoffs](../../docs/reviews/2026-10-17-round2-handoffs.md)). The decisions above stand; these add to them.

- **Maintenance rotates token keys.** `POST /maintenance/partitions` also re-seals `provider_token` rows sealed under an older key with the active one and reports `token_rotation {status, resealed, skipped, failed}`; the step is never fatal to the call. A share also re-seals its token right after opening it (best effort, never fails the share).
- **A duplicate publish settles; it never stays `QUEUED`.** If the post went out but `recordPublish` hits the engagement unique key, jobs calls `PgShareRepository.recordDuplicatePublish`: the request is linked to the same employee's existing engagement and marked `PUBLISHED`, with no new engagement and no `EngagementRecorded`, so nothing is scored twice. With no matching engagement for that employee, the share fails `PROVIDER_REJECTED` / `DUPLICATE_ENGAGEMENT`. A database error during that step is retried through the outbox like any other.
- **The run lock is released on panic.** `runOnce` traps a panic in `tryAcquire` and `execute`, so the in-process flag and the session advisory lock are always released; before, one panic left every later `POST /runs` answering `202 SKIPPED` until restart. `validateRunConfig` also refuses, at startup, tuning where `runMaxSeconds` plus the longest call doesn't fit inside the lease (item 3).

## Amendment (2026-11-01): the publish path, as verified

Checked against `amplify-jobs/handlers.bal` (`handleRepostRequested`) and `sharing/repository.bal` (`recordPublish`), and pinned by tests.

- **Pending until LinkedIn accepts.** The outbox row and the share stay pending (`QUEUED`) through every refusal. A 429 or a 5xx that LinkedIn answered (`UNAVAILABLE`, retryable) clears the in-flight marker and requeues the row with backoff; the retry posts once.
- **One transaction right after acceptance.** `recordPublish` writes the engagement, the published share row (marker cleared) and `EngagementRecorded` in one store-gate transaction. The outbox row itself is settled `DONE` by the run loop in a later, separate write: a crash between the two redelivers the row, finds the share already published and does nothing (no second post).
- **The marker covers the lost write.** `PUBLISH_IN_FLIGHT` is written (version bump) before the call and cleared only by the published write or by a provider error that proves nothing was posted. If the post is accepted and the record write fails, the marker stays and the row fails for manual review; a redelivery or retry never posts again. Test: `aFailedMarkSentWriteAfterAnAcceptedPostGivesExactlyOnePostAcrossAllRetries`.
- **Timeouts retry (owner decision, 2026-11-01).** A timeout, dropped connection or 502/504 on the create call is `OUTCOME_UNKNOWN`: the adapter does not call it retryable because the post may be live. The handler now treats it like a 5xx anyway: the marker is cleared, the share stays `QUEUED`, the outbox row stays pending and retries with backoff, and the share fails `RETRIES_EXHAUSTED` on the last attempt. **Accepted window:** if LinkedIn took the post and only the answer was lost, the retry posts a second time (at most `maxAttempts` posts). That is ADR-025 item 5, and it is the price of "it stays in the outbox until sent". Before this change the share failed at once with `PROVIDER_REJECTED` / `OUTCOME_UNKNOWN`. Tests: `aTimeoutLeavesTheRowPendingAndTheRetryPostsOnce`, `aLostAnswerKeepsRetryingUntilTheLastAttemptThenFailsTheShare`.

## Amendment (2026-11-02): Novera notifications favour a duplicate over a miss

If `saveAnnouncement` fails after Novera accepted the notification, the outbox retries the handler and Novera is notified again. The notification carries no id Novera could dedupe on. Owner decision: a duplicate announcement is better than a missed one, so the retry stands. A marker like the publish path's `PUBLISH_IN_FLIGHT` is not added.
