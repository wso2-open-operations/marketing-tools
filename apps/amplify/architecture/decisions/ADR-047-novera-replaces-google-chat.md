# ADR-047: Novera replaces the Club Chat space as the channel that announces new posts

- **Status:** Accepted
- **Date:** 2026-11-03
- **Source:** owner decision 2026-11-03 ("Delete the Club Chat space everywhere and replace it with Novera. Requirements changed since the business doc came out.")
- **Supersedes in part:** [ADR-020](ADR-020-amplify-common-local-package.md) (`googlechat` module), [ADR-025](ADR-025-jobs-run-delivery-and-resilience.md) (Chat webhook as a delivery target), [ADR-026](ADR-026-akornatskyy-scheduler.md) (Chat breaker on `GET /ready`), [ADR-034](ADR-034-share-is-a-repost.md) (Chat card button), [ADR-035](ADR-035-open-leaderboards-and-employee-count.md) and [ADR-036](ADR-036-dashboards-for-amplify-roles.md) (Chat card status)

## Context

The business requirements doc named the WSO2 Club Google Chat space as the place where new posts are announced. Amplify built that path: an incoming-webhook URL held as a secret, a cardsV2 card builder (`amplify_common.googlechat`), a local `chat-stub`, a 1 request per second throttle, its own breaker and metrics, and the `amplifyOnWebhook` kill switch. Novera, the Google Chat assistant, was added later as a second channel and planned as phase 2 (accepted blocker MT-09).

Requirements changed after the business doc came out. The owner wants one channel, and it is Novera.

## Decision

1. **Novera is the only channel that announces new posts, in phase 1.** `amplify-jobs` handles `CampaignRegistered` by sending one notification to Novera's `POST /internal/notifications` (`amplify-jobs/novera.bal`). The card is a post summary with an Amplify button (`buildNoveraNotification` in `amplify_domain.announcements`). As built, the button opens the One WSO2 Celebrate page with `?share=<campaignId>`, which shows that post's share dialog (`sharePageBaseUrl`).
2. **Google Chat is removed from Amplify.** The Club Chat space, its incoming webhook URL secret, the card builder module `amplify_common.googlechat`, `local/chat-stub`, the `amplifyOnWebhook` kill switch, the Chat breaker and the Chat metrics all go. There is no second channel and no fallback.
3. **Novera's phase 2 items move to phase 1.** The announcement card, an idempotency key on the notification and the egress allow-list entry for Novera are phase 1 work. Accepted blocker MT-09 ("Novera phase 2") no longer holds.
4. **Until Novera dedupes on a key, the [ADR-025](ADR-025-jobs-run-delivery-and-resilience.md) amendment of 2026-11-02 stands.** A failed save after Novera accepted the notification retries the handler, and Novera may send the card twice. A duplicate is preferred to a miss.

## What is left in the database

- Applied migrations are never edited. `V008__announcement_messaging_audit_config.sql` and `V011__announcement_thread_name.sql` still mention Chat (`space`, `thread_key`, `chat_message_name`, `chat_thread_name`).
- The columns stay and keep their names. Novera rows store `space = 'novera'`, the idempotency key `amplify:<campaignId>` in `thread_key` and the delivery marker in `chat_message_name`. `chat_thread_name` is no longer read or written. Older rows keep `club` or `dev-test` and their Chat values.
- No migration drops or renames these columns as part of this decision. If one is needed later, it is a new versioned migration.

## Consequences

- Novera's availability is now the announce path. A Novera outage, a rejected token or a 5xx retries through the outbox with backoff (ADR-025). After the last attempt the announcement is `FAILED` and the PO retry applies (ADR-024).
- There is no second channel. If Novera is not configured, announcements defer.
- One less secret per environment (the webhook URL) and one less stub in the local stack. Novera's client secret stays a secret.
- The Novera notify URL and token endpoint are the only announce egress. The egress allow-list names them instead of `chat.googleapis.com`.
- Docs that described the webhook, the Club space or the chat stub are updated or deleted. Dated reviews keep their text and carry a one-line note.

## Links

- `amplify-jobs/novera.bal`, `amplify-jobs/handlers.bal`
- `amplify-domain/modules/announcements/README.md`
- [TestNovera.md](../../docs/HowToTestLocally/TestNovera.md), `local/novera-mock/README.md`
