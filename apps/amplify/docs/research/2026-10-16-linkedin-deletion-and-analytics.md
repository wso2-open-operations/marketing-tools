# LinkedIn deletion check and share analytics (M0b research)

- **Date:** 2026-10-16
- **Owner:** Lead Developer
- **Plan items:** M0b "Investigate the deletion API" and "Research the analytics API"; feeds M6 pre-coin verification (C6) and the share-metrics pass
- **Decision record:** [ADR-018](../../architecture/decisions/ADR-018-share-verification-and-metrics-need-community-management.md)
- **Docs version checked:** LinkedIn Marketing API `li-lms-2026-09` on Microsoft Learn

## Summary

| Question | Verdict | Phase |
|---|---|---|
| Can a `w_member_social` token `GET /rest/posts/{urn}` for the member's own post or reshare? | **No.** Reading member posts needs `r_member_social`, which is restricted and **closed** to new requests. | Not possible in phase 1 |
| Can we read per-share metrics (impressions, reactions, comments, reshares) for a member's post? | **Yes, with the Community Management API** and the member permission `r_member_postAnalytics` (`GET /memberCreatorPostAnalytics?q=entity`). | Phase 2 (needs a vetted product) |

So with the phase 1 scope (`w_member_social` only), Amplify can't confirm that a repost still exists. **Pre-coin verification stays a target design, not a phase 1 capability.** That's fine for the pilot because no points turn into Coins in phase 1.

## 1. Deletion check: can `w_member_social` read its own post?

### What the docs say

- The Posts API permissions table lists `w_member_social` as "Post, comment, and like posts on behalf of an authenticated member" (write only). Reading is `r_member_social`: "Retrieve posts, comments, and likes on behalf of an authenticated member. This permission is **restricted** and is available to **approved users only**." [1]
- `GET /rest/posts/{encoded ugcPostUrn|shareUrn}` is the "Get Posts by URN" call [2]. The page doesn't break permissions down per method, so the table in [1] is what applies: a member-authored post is read with `r_member_social`.
- The author finder says it outright: "To retrieve all posts authored by a person, `r_member_social` permission is required." [3]
- The legacy UGC Post API has the same rule for member posts [4].
- Community Management FAQ #6: "`r_member_social` is a **closed** permission. We're not accepting access requests at this time due to resource constraints." [5]

### Local evidence

- `apps/amplify/linkedin/resources/openapi/openapi/member-posts-management.openapi.yaml` (`getAMemberAuthoredPost`, `/posts/{postUrn}`): GET of a person-authored post goes through `getPartnerAccessRestrictionsToPass()`, which checks `r_member_social`. BATCH_GET of member posts returns `400 "Member permissions must be used when using member as author"` without it.
- `apps/amplify/linkedin/README.md` capability table: `/rest/posts` GET, BATCH_GET and FINDER marked ❌ "Needs r_member_social (restricted) or r_organization_social". The scopes our Community Management dev app lists also exclude `r_member_social`.
- The mock (`apps/amplify/linkedin/apps/mock_linkedin/api_service.bal`) implements create, partial update and DELETE on `/rest/posts`, and **no GET**. That matches the real permission model, so we haven't been hiding a gap.

### Verdict

**No.** A `w_member_social` token can create, edit and delete its own posts but can't read them back, and the read permission is closed. Nothing in the docs gives a "does this share still exist?" check to a write-only token.

What we can't settle from docs alone (needs a live call, phase 2): whether `GET /memberCreatorPostAnalytics?q=entity&entity={shareUrn}` with `r_member_postAnalytics` returns 404 (or an empty result) for a deleted post. If it does, that's a workable existence probe without `r_member_social`. **Pending live test.**

### What it means for C6 (pre-coin verification)

- Phase 1 can't run the "check the repost still exists" step. The M6 pass stays in the plan as the target design, gated on Community Management access (ADR-018).
- Phase 1 points stay `HELD`. Coins are phase 2, so nothing gets paid out on an unchecked share.
- The anti-farming guard that *does* work in phase 1 is the DB one: `UNIQUE (provider, target_resource_urn, employee_id, action)` on `sharing.engagement` and ledger PK `reference` with `ON CONFLICT DO NOTHING` ([phase1-data-model.md](../../architecture/solution/Phase%201/phase1-data-model.md) lines ~417 and ~534). Delete-and-repost of the same campaign can't score twice. A deleted share keeping its points is the gap until verification lands.
- The reversal path (`EngagementDeleted` → `REV-…` row, reason `ENGAGEMENT_DELETED`) stays modelled, so it can be switched on without a schema change.
- Not a fix: listening for our own `DELETE` calls only catches deletes made through Amplify. Members delete on linkedin.com.

## 2. Share analytics: can a cron pull per-share metrics?

### What the docs say

- **Endpoint:** `GET /rest/memberCreatorPostAnalytics?q=entity&entity={ugcPost or share URN}&queryType={metric}` returns one post's stats; `q=me` returns all of the member's posts aggregated [6].
- **Metrics:** `IMPRESSION`, `MEMBERS_REACHED`, `RESHARE`, `REACTION`, `COMMENT`, `POST_SAVE`, `POST_SEND`, `LINK_CLICKS`, plus a few more [6]. Aggregation `TOTAL` (default) or `DAILY` (no `DAILY` for `MEMBERS_REACHED` or `LINK_CLICKS`). With no `dateRange`, you get the lifetime of the post, so there's no short look-back window to design around (relevant to C7).
- **Caveats:** "RESHARE, REACTION, COMMENT are not consistent with UI at the moment" (noted on the `q=me` finder), and counts are "best-effort accurate and shouldn't be used for billing purposes" [6]. Our take: fine for a display tile, not for points.
- **Scope and product:** `r_member_postAnalytics`, a 3-legged member permission, "Community Management API (in API versions starting from 202506)" [7][8].
- **Getting Community Management:** a vetted product. It's only for registered legal organizations with commercial use cases. The request must come from a developer app that has no other products (you can attach it to an existing app later). Development tier: 500 calls/app/day, 100/member/day, no BATCH_GET, no webhooks, 12 months to finish building. Standard tier: no limits, but it needs a privacy policy and a screen recording of the full OAuth flow and every feature that uses member data [9][10][11].

### Verdict

**Yes, but not in phase 1.** Per-share metrics exist for the member's own posts through `memberCreatorPostAnalytics` with `r_member_postAnalytics` under Community Management. Phase 1 runs on `w_member_social` only, so the share-metrics pass is **phase 2**. Keep the UI slot.

Open points for a live test once Community Management is approved:

1. Does `q=entity` return metrics for a **plain repost** URN (no commentary)? The docs only say the entity is a `ugcPost` or `share` owned by the current member. A plain repost may have little or no reach of its own. **Pending live test.**
2. Does `q=entity` on a deleted post give a clean 404 (see section 1)? **Pending live test.**
3. How much of the dev-tier budget a daily pass uses: one call per `queryType` per share, and no BATCH_GET in dev tier. Five metrics × N shares adds up fast against 500/app/day.

### What it means for the share-metrics pass

- M6 "Share metrics pass" stays **future phase**, as planned. `sharing.engagement_metric` stays a *future* table in the data model.
- When it lands: one snapshot row per engagement per day per metric, `TOTAL` aggregation, rate-limited per member and per app.
- Use metrics for display and reports, never as point inputs, because LinkedIn calls them best-effort.

## Sources

1. Posts API, Permissions: https://learn.microsoft.com/linkedin/marketing/community-management/shares/posts-api?view=li-lms-2026-09#permissions
2. Posts API, Get Posts by URN: https://learn.microsoft.com/linkedin/marketing/community-management/shares/posts-api?view=li-lms-2026-09#get-posts-by-urn
3. Posts API, Find Posts by Authors: https://learn.microsoft.com/linkedin/marketing/community-management/shares/posts-api?view=li-lms-2026-09#find-posts-by-authors
4. UGC Post API, Retrieve UGC Posts: https://learn.microsoft.com/linkedin/compliance/integrations/shares/ugc-post-api#retrieve-ugc-posts
5. Community Management Overview, FAQ: https://learn.microsoft.com/linkedin/marketing/community-management/community-management-overview?view=li-lms-2026-09#versioning
6. Member Post Statistics: https://learn.microsoft.com/linkedin/marketing/community-management/members/post-statistics?view=li-lms-2026-09
7. Increasing Access, API Products and Permissions: https://learn.microsoft.com/linkedin/marketing/increasing-access?view=li-lms-2026-09#api-products-and-permissions
8. Recent Marketing API Changes, June 2025 (202506): https://learn.microsoft.com/linkedin/marketing/integrations/recent-changes?view=li-lms-2026-09#june-2025---version-202506
9. Increasing Access, access tiers: https://learn.microsoft.com/linkedin/marketing/increasing-access?view=li-lms-2026-09#how-to-upgrade-your-access-tier
10. Community Management App Review: https://learn.microsoft.com/linkedin/marketing/community-management-app-review?view=li-lms-2026-09
11. LinkedIn API Partner Support FAQ (Community Management must be the only product): https://learn.microsoft.com/linkedin/shared/linkedin-api-partner-support-guide#faqs-and-troubleshooting

Local: `apps/amplify/linkedin/README.md`, `apps/amplify/linkedin/resources/openapi/openapi/member-posts-management.openapi.yaml`, `apps/amplify/linkedin/resources/openapi/openapi/w-member-social.openapi.yaml`, `apps/amplify/linkedin/apps/mock_linkedin/api_service.bal`.
