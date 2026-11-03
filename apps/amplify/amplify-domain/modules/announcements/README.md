# amplify_domain.announcements

Supporting context: the Club chat card for a campaign, sent once. Table: `announcement` (view `announcement_v`). The table has no `announcements_` prefix.

## Types and ports

File: `modules/announcements/types.bal`.

- `Announcement` (primary key `campaignId`, so a campaign is announced once), `CampaignCardSource`, `NoveraNotification`.
- `AnnouncementStatus`: `QUEUED`, `SENT`, `FAILED`.

## Service and use cases

File: `modules/announcements/service.bal`.

- State changes: `announcementStatus`, `queueAnnouncement` (`ALREADY_ANNOUNCED` if one exists), `markSent` and `markFailed` (both need `QUEUED`), `retryAnnouncement` (only from `FAILED`).
- Card builders: `buildCard` (cardsV2 through `amplify_common.googlechat:buildCampaignCard`), `buildNoveraNotification` (text is cut to Novera's field limits, not rejected). `NOVERA_SOURCE` (`amplify`) is in `announcements.bal`.

## Events

File: `modules/announcements/events.bal`. `campaignAnnouncedEvent(announcement)`.

## Repository and tables

File: `modules/announcements/repository.bal`.

- `AnnouncementRepository` port: `findByCampaign`, `list`, `requeue`. `PgAnnouncementRepository(db, actor)` implements it. `requeue` also resets the matching `messaging_outbox` row.
- `PgAnnouncementWriter(db, actor)` (`insertQueued`, `save`) is used by the chat notifier job.
- `statusesOf(db, campaignIds)` returns status by campaign id from `announcement_v`.

## Config

None.

## Depends on

`amplify_common.types`, `amplify_common.events`, `amplify_common.googlechat`, `amplify_domain.store`.

## Does not do

- No webhook call. The chat notifier in `amplify-jobs` posts the card and records the result.
- No retry loop. Retry is an outbox concern and a PO action (`retryAnnouncement`).
- Never stores the webhook URL (`lastError` is safe text).

## Tests

`modules/announcements/tests/announcements_test.bal`.
