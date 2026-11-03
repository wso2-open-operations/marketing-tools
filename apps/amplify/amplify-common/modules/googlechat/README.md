# amplify_common.googlechat

The Club-space card and the incoming-webhook client (anti-corruption layer for Google Chat).

## Card builder

File: `modules/googlechat/card.bal`.

- `CampaignCard`: `campaignId`, `title`, `summary`, `imageUrl`, `sharePageUrl`, `isPriority`, `avatarUrl`, `defaultImageUrl`.
- `buildCampaignCard(card)` returns the cardsV2 JSON or a `DomainError`. The priority flag changes the subtitle. The image widget is left out unless the image URL is public HTTPS.
- `threadKey(campaignId)` returns `campaign-<id>` (`announcement.thread_key`).
- `isPublicHttpsUrl`, `escapeHtml`. Limits and labels: `CARD_SUMMARY_MAX_LENGTH`, `CARD_TITLE_MAX_LENGTH`, `CARD_BUTTON_TEXT`, `CARD_AVATAR_ALT_TEXT`, `CARD_SUBTITLE`, `CARD_SUBTITLE_PRIORITY`.

## Webhook client

File: `modules/googlechat/client.bal`.

- `WebhookClient` (`WebhookConfig`: `webhookUrl`, `allowInsecureHttp`, `timeoutSeconds`, `resilience`). `post(message, threadKey, correlationId)` returns a `ChatMessage` (`name`, `threadName`) or a `ChatError`. `breaker()` returns the breaker state.
- Plain `http` is accepted only for `localhost` and `127.0.0.1`, or any host when `allowInsecureHttp` is set (local compose only).
- `ChatErrorCode`: `INVALID_CONFIG`, `REJECTED`, `RATE_LIMITED`, `UNAVAILABLE`, `BAD_RESPONSE`. A response timeout is `UNAVAILABLE` with `retryable = false`, because Chat may already have posted the card.
- Retry stays 0 (a repeated call posts the card twice).

## Transport

File: `modules/googlechat/transport.bal`. The call goes through the JDK `java.net.http` client by Java interop, not `ballerina/http`. The webhook URL holds the space key and token as query parameters, and the Ballerina HTTP client puts the URL on trace spans when observability is on. External functions are not instrumented, so the URL stays off spans, metrics and logs. This file also holds a small private breaker (window, volume, ratio, reset time, failure statuses). Retry and pool size from `HttpResilience` do not apply here.

## Depends on

`amplify_common.types` (`DomainError`), `amplify_common.resilience` (`HttpResilience`, `BreakerState`).

## Does not do

- No announcement state or retry. `amplify_domain.announcements` and the jobs own that.
- No message updates or deletes.
- Never logs or returns the webhook URL, the query or a Java exception message.

## Tests

`modules/googlechat/tests/googlechat_test.bal`, `modules/googlechat/tests/client_timeout_test.bal`. Run `bal test` from `amplify-common`.
