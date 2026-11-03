# amplify_domain.campaign

Registry of official WSO2 posts: category, priority, tags, active window and the derived status. Tables: `campaign`, `campaign_category`, `campaign_tag`, view `campaign_v`.

## Types and ports

File: `modules/campaign/types.bal`.

- `Campaign`, `CampaignDraft`, `CampaignPatch`, `CampaignPolicy` (allowed link origins, default window).
- `CampaignStatus`: `SCHEDULED`, `OPEN`, `CLOSED`, `ARCHIVED`. Status is derived from timestamps and the clock, as `campaign_v` computes it.
- Limits: `TITLE_MAX_LENGTH`, `TAG_MAX_LENGTH`, `SUMMARY_MAX_LENGTH`, `DEFAULT_WINDOW_DAYS`, `DEFAULT_POST_LINK_ORIGINS`.
- `CampaignRepository` port: `findById`, `findByResource`, `insert(campaign, outbox)`, `update(campaign, expectedVersion)`, `hasActivity`.

## Service and use cases

File: `modules/campaign/service.bal`.

- Pure rules: `campaignStatus`, `isOpen`, `newCampaign` (valid post URN, title, category, HTTPS links, unique lowercase tags, `closesAt > opensAt`), `applyPatch` (archived campaigns cannot change; once opened, only `closesAt` can move), `ensurePostChangeAllowed` (the post id may change only while no share, engagement, claim or ledger row exists), `archive`, `normalizeTags`.
- Use cases: `registerCampaign` (Save, Save and Share Now; queues `CampaignRegistered`), `updateCampaign` (optimistic `expectedVersion`), `archiveCampaign`.

## Events

File: `modules/campaign/events.bal`. `campaignRegisteredEvent(campaign, shareNow)` wraps `events:newCampaignRegistered`.

## Repository and tables

File: `modules/campaign/repository.bal`. `PgCampaignRepository(db, actor)` writes `campaign` and `campaign_tag` with the outbox and audit rows in one transaction. `hasActivity` also reads `sharing_share_request`, `sharing_engagement`, `external_sharing_external_share` and `scoring_points_ledger` (read only, no foreign keys, ADR-005).

## Queries

File: `modules/campaign/queries.bal`. `listCampaigns(db, CampaignQuery, now)` returns a `CampaignPage` (`MAX_PAGE_SIZE` 50), `listTags`, `listCategories` (`Category`), `dashboardCampaigns`.

## Config

None. `campaign.bal` holds `MODULE`.

## Depends on

`amplify_common.types`, `amplify_common.events`, `amplify_domain.store`.

## Does not do

- No Club card and no announcement state (`announcements` does that).
- No share or scoring logic.
- No image upload (the campaign holds image URLs only).

## Tests

`modules/campaign/tests/campaign_test.bal` (in-memory repository). Integration tests are in the package `tests/` directory (see the component README).
