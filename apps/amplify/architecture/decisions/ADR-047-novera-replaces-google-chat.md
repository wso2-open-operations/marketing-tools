# ADR-047: Novera replaces the Club Chat space as the channel that announces new posts

- **Status:** Accepted
- **Date:** 2026-11-03
- **Source:** owner decision 2026-11-03 ("Delete the Club Chat space everywhere and replace it with Novera. Requirements changed since the business doc came out.")
- **Supersedes in part:** [ADR-020](ADR-020-amplify-common-local-package.md) (`googlechat` module), [ADR-025](ADR-025-jobs-run-delivery-and-resilience.md) (Chat webhook as a delivery target), [ADR-026](ADR-026-akornatskyy-scheduler.md) (Chat breaker on `GET /ready`), [ADR-034](ADR-034-share-is-a-repost.md) (Chat card button), [ADR-035](ADR-035-open-leaderboards-and-employee-count.md) and [ADR-036](ADR-036-dashboards-for-amplify-roles.md) (Chat card status)

## Context

The business requirements doc named the WSO2 Club Google Chat space as the place where new posts are announced. Amplify built that path: an incoming-webhook URL held as a secret, a cardsV2 card builder (`amplify_common.googlechat`), a local `chat-stub`, a 1 request per second throttle, its own breaker and metrics, and the `amplifyOnWebhook` kill switch. Novera, the Google Chat assistant, was added later as a second channel and planned as phase 2 (accepted blocker MT-09).

Requirements changed after the business doc came out. The owner wants one channel, and it is Novera.

## Decision

1. **Novera is the only channel that announces new posts, in phase 1.** `amplify-jobs` handles `CampaignRegistered` by sending one notification to Novera's `POST /internal/notifications` (`amplify-jobs/novera.bal`). The card is a post summary with an Amplify button (`buildNoveraNotification` in `amplify_domain.announcements`). The button opens the One WSO2 Celebrate page, which shows that post's share dialog. That is intended (owner, 2026-11-03). The button URL comes from configuration, see "Button URL" below. The label is the constant `CARD_BUTTON_TEXT`.
2. **Google Chat is removed from Amplify.** The Club Chat space, its incoming webhook URL secret, the card builder module `amplify_common.googlechat`, `local/chat-stub`, the `amplifyOnWebhook` kill switch, the Chat breaker and the Chat metrics all go. There is no second channel and no fallback.
3. **Novera's phase 2 items move to phase 1.** The announcement card, an idempotency key on the notification and the egress allow-list entry for Novera are phase 1 work. Accepted blocker MT-09 ("Novera phase 2") no longer holds.
4. ~~**Until Novera dedupes on a key, the [ADR-025](ADR-025-jobs-run-delivery-and-resilience.md) amendment of 2026-11-02 stands.** A failed save after Novera accepted the notification retries the handler, and Novera may send the card twice. A duplicate is preferred to a miss.~~ **Superseded (2026-11-03)** by "Amplify prevents duplicate cards" below. Novera will not dedupe on `Idempotency-Key`, and Amplify no longer depends on it.

## Button URL (owner decision, 2026-11-03)

- One setting, `noveraButtonUrl` in `amplify-jobs` (env `NOVERABUTTONURL`, local compose variable `NOVERA_BUTTON_URL`), holds the button URL. It replaces `sharePageBaseUrl` (env `SHAREPAGEBASEURL`, compose `AMPLIFY_SHARE_PAGE_BASE_URL`).
- It is a URL template and must contain `{campaignId}`. Example: `https://one.wso2.com/amplify/celebrate?share={campaignId}`. The handler puts the campaign id in place of `{campaignId}`.
- There is no default in code. The URL is never hardcoded.
- It must use https. http is allowed only on the local stack, together with the Novera allow-insecure-http setting.
- `amplify-jobs` validates it at start-up. A value that is set but invalid stops start-up.
- Empty means not configured: `CampaignRegistered` rows are deferred with "Novera button URL is not configured". Amplify never sends a card without a button.

## Amplify prevents duplicate cards (owner decision, 2026-11-03)

Novera will not dedupe on `Idempotency-Key`. Amplify prevents duplicates itself. This reverses the 2026-11-02 rule ("a duplicate is better than a miss") for Novera announcements.

- Migration `V022__announcement_attempted_at.sql` adds a nullable `attempted_at timestamptz` column to the `announcement` table.
- The handler saves `attempted_at` before it calls Novera.
- The header `Idempotency-Key: amplify:<campaignId>` is still sent. It does no harm, and Novera can use it if it ever honours the key.
- No new status value and no API contract change. The uncertain case is a `FAILED` row whose `last_error` starts with "Delivery unknown:".

| Outcome of the call | What Amplify does |
|---|---|
| Success (202 or 200) | Saves the announcement `SENT`. |
| Definitely not delivered: token endpoint or client build unreachable before any request was sent, Novera connection refused or host unresolved, Novera breaker open, 401, 403, 429, 503 | Clears `attempted_at`. The outbox retries automatically with backoff. `FAILED` after the last attempt. |
| Rejected: any other 4xx | `FAILED` once. No retry. |
| Ambiguous: no response after the request was sent (timeout, connection reset), 500, 502, 504 or any 5xx except 503 | Not retried automatically. `FAILED` with `last_error` starting "Delivery unknown:". |
| Row is `QUEUED` with `attempted_at` already set when the handler starts (a crash, or the `SENT` save failed after Novera accepted) | Not sent again. `FAILED` with "Delivery unknown: an earlier attempt may have reached Novera; check Novera before retrying". |

- The admin retry (`POST /admin/announcements/{id}/retry`) clears both `failed_at` and `attempted_at` (the API re-queues the outbox row; the handler clears both on the next run with `retryAnnouncement`). That is the explicit human decision to send again.
- Result: at most one card per campaign, unless an admin chooses to resend. In the uncertain case a card may be missed instead of duplicated, and an admin sees it in the failed announcements list.
- The runbook steps for "Delivery unknown" are in `docs/runbooks/operations.md`.

## What is left in the database

- Applied migrations are never edited. `V008__announcement_messaging_audit_config.sql` and `V011__announcement_thread_name.sql` still mention Chat (`space`, `thread_key`, `chat_message_name`, `chat_thread_name`).
- The columns stay and keep their names. Novera rows store `space = 'novera'`, the idempotency key `amplify:<campaignId>` in `thread_key` and the delivery marker in `chat_message_name`. `chat_thread_name` is no longer read or written. Older rows keep `club` or `dev-test` and their Chat values.
- No migration drops or renames these columns as part of this decision. If one is needed later, it is a new versioned migration.

## Consequences

- Novera's availability is now the announce path. A failure that proves nothing was delivered (unreachable token endpoint, 401, 403, 429, 503) retries through the outbox with backoff (ADR-025). An ambiguous failure is not retried and needs an admin decision (see the outcome table). After the last attempt, or after an ambiguous failure, the announcement is `FAILED` and the admin retry applies (ADR-024).
- A card can be missed, but not sent twice, unless an admin resends it.
- There is no second channel. If Novera is not configured, announcements defer.
- One less secret per environment (the webhook URL) and one less stub in the local stack. Novera's client secret stays a secret.
- The Novera notify URL and token endpoint are the only announce egress. The egress allow-list names them instead of `chat.googleapis.com`.
- Docs that described the webhook, the Club space or the chat stub are updated or deleted. Dated reviews keep their text and carry a one-line note.

## Links

- `amplify-jobs/novera.bal`, `amplify-jobs/handlers.bal`, `amplify-jobs/config.bal`
- `amplify-database/migrations/V022__announcement_attempted_at.sql`
- [operations.md](../../docs/runbooks/operations.md) (Delivery unknown, button URL not configured)
- `amplify-domain/modules/announcements/README.md`
- [TestNovera.md](../../docs/HowToTestLocally/TestNovera.md), `local/novera-mock/README.md`
