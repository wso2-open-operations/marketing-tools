# amplify_common.events

Domain event payloads and outbox row builders. One payload record and one builder per row of the event catalogue in [phase1-data-model](../../../architecture/solution/Phase%201/phase1-data-model.md). The builders only build rows. `amplify_domain.store` writes them to `messaging_outbox` in the producer's transaction.

File: `modules/events/events.bal` (single file).

## Event types and aggregates

- Event type constants (outbox `event_type`): `CAMPAIGN_REGISTERED`, `CAMPAIGN_ANNOUNCED`, `CONNECTION_READY`, `CONNECTION_REVOKED`, `CONNECTION_REMOVED`, `REPOST_REQUESTED`, `ENGAGEMENT_RECORDED`, `REPOST_FAILED`, `EXTERNAL_SHARE_SUBMITTED`, `EXTERNAL_SHARE_APPROVED`, `EXTERNAL_SHARE_REJECTED`, `EXTERNAL_SHARE_AMPLIFIED`, `POINTS_AWARDED`, `POINTS_ADJUSTED`, `POINTS_REVERSED`. `EventType` is their union.
- Aggregate type constants (outbox `aggregate_type`): `AGG_CAMPAIGN`, `AGG_ANNOUNCEMENT`, `AGG_MEMBER_CONNECTION`, `AGG_SHARE_REQUEST`, `AGG_ENGAGEMENT`, `AGG_EXTERNAL_SHARE`, `AGG_POINTS_LEDGER`.

## Payload records and builders

- One record per event (`CampaignRegistered`, `CampaignAnnounced`, `ConnectionReady`, `ConnectionRevoked`, `ConnectionRemoved`, `RepostRequested`, `EngagementRecorded`, `RepostFailed`, `ExternalShareSubmitted`, `ExternalShareApproved`, `ExternalShareRejected`, `ExternalShareAmplified`) and one shared `PointsChanged` for the three `Points*` events. `EventPayload` is their union.
- Builders: `newCampaignRegistered`, `newCampaignAnnounced`, `newConnectionReady`, `newConnectionRevoked`, `newConnectionRemoved`, `newRepostRequested`, `newEngagementRecorded`, `newRepostFailed`, `newExternalShareSubmitted`, `newExternalShareApproved`, `newExternalShareRejected`, `newExternalShareAmplified`, `newPointsChanged`.
- `newPointsChanged(types:LedgerEntry)` picks `PointsAdjusted`, `PointsReversed` or `PointsAwarded` from the entry's `sourceType`.
- Times in payloads are RFC 3339 UTC strings.

## Idempotency keys

- `OutboxEvent` holds `aggregateType`, `aggregateId`, `eventType`, `payload` and `idempotencyKey`.
- `idempotencyKey(eventType, ...parts)` returns `<event_type>:<part>[:<part>]`. The event-type prefix stops two events of one aggregate (for example `RepostRequested` and `RepostFailed`, both keyed `share_request.id` + `attempts`) from colliding on the unique outbox key.
- Catalogue keys: `campaign.id` (CampaignRegistered), `outbox.id` (CampaignAnnounced), `member_urn` + time (the three connection events), `share_request.id` + `attempts` (RepostRequested, RepostFailed), `engagement.id`, `external_share.id` (submitted, approved, rejected), `external_share.id` + `AMPLIFIED`, and the ledger `reference` for `Points*`.

## Depends on

`amplify_common.types` (`LedgerEntry`, ids and enums). `ballerina/time`.

## Does not do

- No database writes (the outbox writer is `amplify_domain.store`).
- No `EngagementDeleted` (future phase, ADR-018) and no `EmployeeErased` (not in phase 1).
- Payloads never hold tokens or commentary.

## Tests

`modules/events/tests/events_test.bal`. Run `bal test` from `amplify-common`.
