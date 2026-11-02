# ADR-024: amplify-api M5 boundary choices (cross-context unit of work, idempotency, degraded dependencies)

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan M5, M9; phase1-data-model › Domain events

## Context

Building the published API (M5) hit five places where the design docs left the mechanics open.

## Decision

1. **S3 → C2 in one transaction.** The event catalogue says approve / amplified award points "same transaction in api". `ExternalShareRepository.updateWithAward` writes the claim, its outbox row, its audit row and the ledger row (via `scoring:appendInTransaction`, which also applies the row to `recognition`, B12) in one `transaction`. This is the second deliberate cross-schema write after B12; `amplify_api` already has the grants. M6 jobs handlers for `ExternalShareApproved` / `ExternalShareAmplified` must stay idempotent (`ON CONFLICT DO NOTHING` on the same reference) and therefore become no-ops.
2. **Admin announcement retry re-queues the outbox row.** `amplify_api` can only read `announcement.announcement` (V008). `POST /admin/announcements/{id}/retry` resets the `CampaignRegistered:<id>` outbox row to `PENDING` (attempts 0) and audits `AnnouncementRetried`; the jobs worker clears `failed_at` when the card is sent (M6 handler requirement).
3. **Idempotency-Key.** Optional on every POST, stored per caller in `messaging.idempotency_key` for 24 h with a SHA-256 request fingerprint. Same key + same request replays the stored status and body (`Idempotent-Replayed: true`); different request → 422 `IDEMPOTENCY_KEY_REUSED`; still running → 409 `IDEMPOTENCY_IN_PROGRESS`; 5xx outcomes are released so a retry can run. The key row is not in the business transaction: a crash between the two leaves a "running" key until it expires (24 h), the safe direction. Purging expired keys joins the M6 maintenance pass. POST resources therefore return `http:Response` (a replay can carry any status), a documented exception to the "full union return type" rule.
4. **Non-fatal dependencies.** The amplify-jobs trigger (`shareNow`, settings `leaderboard.top_n` rebuild, announcement retry) is fire-and-forget behind a circuit breaker; when it's open or unconfigured the response says `run: DEFERRED` and Cron catches up. The team roster (D13) is behind a breaker with an in-memory cache (3 days since 2026-10-19, see item 5); when it fails, `teamStatus: UNAVAILABLE` and a non-PO caller's Team page shrinks to themselves (never widens). `/ready` fails only on the database or an open JWKS breaker; the jobs and roster breakers are reported, not fatal, so a jobs outage doesn't pull the API out of rotation.
5. **Roster source.** ~~Assumed contract `GET <rosterUrl>?email=<viewer>` → `{teamName, members}`.~~ Superseded 2026-10-19: `amplify-api` reads people-app's `GET /employees/basic-info` (`peopleDirectoryUrl`, optional OAuth2 client credentials), groups everyone by sub-team (team when there is none), and caches the index for `rosterCacheSeconds` (3 days). A failed refresh keeps the old index.

## Consequences

- Published stable codes: `DUPLICATE_ACTION`, `LINKEDIN_NOT_CONNECTED`, `NEEDS_RECONNECT`, `CAMPAIGN_CLOSED` are API names for the domain codes `SHARE_ALREADY_*`, (no connection), `CONNECTION_NEEDS_RECONNECT`, `CAMPAIGN_NOT_OPEN`; the full list is `Problem.code.x-stable-codes` in `openapi.yaml`.
- The dashboard tiles run in one transaction (READ COMMITTED, so tiles can differ by in-flight writes); move to REPEATABLE READ if PO sees drift.
