# amplify_domain.announcements

Supporting context: the Novera announcement for a campaign, sent once (ADR-047). Table: `announcement` (view `announcement_v`). The table has no `announcements_` prefix.

## Types and ports

File: `modules/announcements/types.bal`.

- `Announcement` (primary key `campaignId`, so a campaign is announced once), `CampaignCardSource`, `NoveraNotification`.
- `Announcement.attemptedAt` (column `attempted_at`, V022): set before the Novera call, cleared when the failure proves nothing was delivered or by the admin retry. A `QUEUED` row with `attemptedAt` set is never sent again automatically (ADR-047).
- `AnnouncementStatus`: `QUEUED`, `SENT`, `FAILED`.

## Service and use cases

File: `modules/announcements/service.bal`.

- State changes: `announcementStatus`, `queueAnnouncement` (`ALREADY_ANNOUNCED` if one exists), `markSent` and `markFailed` (both need `QUEUED`), `retryAnnouncement` (only from `FAILED`; clears `failedAt` and `attemptedAt`). Attempt marker: `markAttempted` and `clearAttempt` (both need `QUEUED`), `hasUnfinishedAttempt` (`QUEUED` with `attemptedAt` set), `markDeliveryUnknown` (fails the row with `lastError` starting `DELIVERY_UNKNOWN`, keeps `attemptedAt` as evidence).
- A failure whose outcome is unknown is a `FAILED` row with `lastError` starting "Delivery unknown:". There is no extra status value.
- Card builder: `buildNoveraNotification`, a post summary with an Amplify button. The button URL is the configured template (`noveraButtonUrl` in `amplify-jobs`) with `{campaignId}` replaced; it opens the One WSO2 Celebrate page at that post's share dialog. The label is `CARD_BUTTON_TEXT`. Every `BUTTON_URL_PLACEHOLDER` (`{campaignId}`) is replaced. `checkButtonUrlTemplate` checks a template (https, or http when allowed; must contain `{campaignId}`); a bad one is `INVALID_BUTTON_URL`. Text is cut to Novera's field limits, not rejected. `NOVERA_SOURCE` (`amplify`) is in `announcements.bal`.

## Events

File: `modules/announcements/events.bal`. `campaignAnnouncedEvent(announcement)`.

## Repository and tables

File: `modules/announcements/repository.bal`.

- `AnnouncementRepository` port: `findByCampaign`, `list`, `requeue`. `PgAnnouncementRepository(db, actor)` implements it. `requeue` also resets the matching `messaging_outbox` row.
- `PgAnnouncementWriter(db, actor)` (`insertQueued`, `save`) is used by the announcement handler in `amplify-jobs`. `save` writes `attempted_at` too.
- `requeue` (the admin retry) resets the `FAILED` outbox row. On the next run the handler calls `retryAnnouncement`, which clears `failed_at` and `attempted_at` before sending.
- Columns of `announcement`: `campaign_id` (PK), `outbox_id`, `space`, `thread_key` (idempotency key `amplify:<campaignId>`), `chat_message_name` (`novera:<campaignId>` marker), `chat_thread_name` (unused), `queued_at`, `attempted_at` (V022), `sent_at`, `failed_at`, `last_error`.
- `statusesOf(db, campaignIds)` returns status by campaign id from `announcement_v`.

## Config

None.

## Depends on

`amplify_common.types`, `amplify_common.events`, `amplify_domain.store`.

## Does not do

- No Novera call. The handler in `amplify-jobs` sends the notification and records the result.
- No retry loop. Retry is an outbox concern and an admin action (`retryAnnouncement`). After an ambiguous outcome only the admin retry sends again.
- Never stores a credential or URL secret (`lastError` is safe text).

## Tests

`modules/announcements/tests/announcements_test.bal`.
