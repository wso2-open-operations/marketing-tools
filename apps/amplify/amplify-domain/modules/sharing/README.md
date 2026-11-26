# amplify_domain.sharing

Core context: share through Amplify. One `ShareRequest` per campaign per employee, and the verified `Engagement` facts that scoring reads. Tables: `sharing_share_request` (view `sharing_share_request_v`), `sharing_engagement` (view `sharing_engagement_v`), `sharing_sync_cursor`, `sharing_api_usage`, `sharing_native_intent` (V025).

## Types and ports

File: `modules/sharing/types.bal`.

- `ShareRequest`, `Engagement`, `ShareCommand`, `PublishResult`, and the read-only snapshots `CampaignSnapshot` and `ConnectionSnapshot` (so this module does not import `campaign` or `connection`).
- `ShareStatus`: `QUEUED`, `PUBLISHED`, `FAILED`. `COMMENTARY_MAX_LENGTH` (3000).
- `ShareRepository` port: `findByCampaignAndEmployee`, `insert`, `update` (each with the outbox rows).

## Service and use cases

File: `modules/sharing/service.bal`.

- Pure rules: `shareStatus`, `newShareRequest` (campaign open, connection usable), `retryShare` (only a `FAILED` request, same row, bumps `attempts` and `version`), `ensurePublishable` (guard before calling LinkedIn: a rerun after a failed record write does not post again; a lost LinkedIn answer is retried by the outbox and can post twice, see the amplify-jobs README), `markPublished` (clears commentary, builds the engagement fact), `asDuplicatePublish`, `markFailed`, `failForLostConnection` (reaction to `ConnectionRevoked` / `ConnectionRemoved`).
- Use case: `requestShare`.

## Engagement sync (Community Management, phase 4)

File: `modules/sharing/engagement_sync.bal`. Ports: `EngagementSource` (reactions, comments and reshares the page token can read; amplify-jobs adapts `linkedin:CommunityPort`) and `SyncStore` (open campaigns, member matching, cursors, the call budget, the writes; amplify-jobs composes it from `campaign:openCampaignsOf`, `connection:employeesOfMembers` and `PgEngagementSyncRepository`, so each context stays on its own tables). Use case `syncEngagement`: per open campaign, reactions then comments from their offset cursors, then the page's share notifications since the last run (an hour's overlap); each call is counted first (`takeCall`) and the run stops at the budget, on a rate limit, an open breaker or a refused token, with the cursors kept. Actors that are not connected employees, and items outside the campaign window, are dropped. `syncedEngagement` builds the fact (`COMMUNITY_MANAGEMENT`, `API_SYNC`; `REACTION`, `COMMENT`, `REPOST` / `REPOST_COMMENTARY`; a reaction keeps no activity URN). Comment and reshare text never reaches this module.

File: `modules/sharing/sync_repository.bal`. `PgEngagementSyncRepository`: `cursor`, `saveCursor`, `takeCall` (one statement against `sharing_api_usage`), `recordSynced` (engagement, `EngagementRecorded` and audit in one transaction, `ON CONFLICT DO NOTHING`; a reshare is skipped when the employee already has a share of the post, and marks the native intent detected). `apiCallsOn(db, day)`.

File: `modules/sharing/native_intent.bal`. `NativeIntent`, `NativeStatus` (`LOOKING` under 24 h, `DETECTED`, `NOT_FOUND`), `nativeStatus`, `NativeIntentRepository` and `PgNativeIntentRepository` (`open`, `ofEmployee`).

## Events

File: `modules/sharing/events.bal`: `repostRequestedEvent`, `engagementRecordedEvent`, `repostFailedEvent`.

## Repository and tables

File: `modules/sharing/repository.bal`. `PgShareRepository(db, actor)`: `findByCampaignAndEmployee`, `insert`, `update`, `recordPublish`, `recordDuplicatePublish`. Writes commit the row, the outbox and the audit in one transaction.

## Queries

File: `modules/sharing/queries.bal`. `sharesOf(db, employeeId, limit)` returns `ShareView` rows, `shareHealth(db, since)` returns `ShareHealth`. Both read the views and `messaging_outbox` (when the current request was queued).

## Config

None. `sharing.bal` holds `MODULE`.

## Depends on

`amplify_common.types`, `amplify_common.events`, `amplify_domain.store`.

## Does not do

- No LinkedIn calls. The job (`amplify-jobs`) calls the adapter and then records the result here (the sync reads LinkedIn through the `EngagementSource` port).
- No scoring (`scoring` prices an `EngagementRecorded` fact).
- No storage of commentary after publish.

## Tests

`modules/sharing/tests/sharing_test.bal`. Integration tests are in the package `tests/` directory (see the component README).
