# LinkedIn Resources

## Learn API details
[LinkedIn Learn MCP Server Install Directions](https://learn.microsoft.com/en-us/training/support/mcp)

## APIs

### OpenID Connect
[Sign In With LinkedIn Using OpenID Connect Docs](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/sign-in-with-linkedin-v2?context=linkedin/consumer/context)

### Share on LinkedIn - w_member_social
[Share on LinkedIn Docs](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/share-on-linkedin?context=linkedin/consumer/context)

<details>
<summary>Click to expand</summary>

Here are the resources that w_member_social covers, pulled from LinkedIn's docs on Microsoft Learn. There are two sources, and they don't fully agree. The official permission-to-resource mapping page was last updated on 2020-10-23 and covers the legacy /v2 endpoints. Each current /rest (versioned) API page also has its own permissions table. I've merged them below, and the Status column calls out where they conflict.

Versioned /rest APIs (current)

```
┌────────────────────────────────────┬─────────────────────────────┬─────────────────────────┬─────────────────────────────────────────────────────────────────────────┬────────────────────────┐
│              Resource              │           Methods           │      Status with        │                                  Notes                                  │    Amplify Phase 1     │
│                                    │                             │  w_member_social only   │                                                                         │                        │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/posts                        │ CREATE                      │ ✅ Listed               │ Text, image, video, document, article, multi-image and poll posts, all  │ Core. Repost and       │
│                                    │                             │                         │ as author: urn:li:person:{me}                                           │ repost with thoughts   │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/posts +                      │ CREATE                      │ ⚠️ Not stated           │ The reshare example only appears on the Marketing Posts API page        │ Day-one spike          │
│ reshareContext.parent              │                             │                         │                                                                         │                        │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/posts/{urn}                  │ PARTIAL_UPDATE              │ ⚠️ Not stated           │ The page lists w_member_social as a general permission, but no table    │ Nice to have (edit or  │
│                                    │ (commentary), DELETE        │                         │ breaks it down by method                                                │ undo)                  │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/posts                        │ GET, BATCH_GET, FINDER      │ ❌                      │ Needs r_member_social (restricted) or r_organization_social             │ Can't verify shares    │
│                                    │ author                      │                         │                                                                         │ afterwards             │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/images                       │ ACTION initializeUpload +   │ ✅ Listed               │ Write-only. A token with only w_member_social can't GET /rest/images on │ Only for original      │
│                                    │ upload                      │                         │  the versioned API. The owner must be the calling member                │ posts with images      │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/videos                       │ ACTION initializeUpload,    │ ✅ Listed               │ MP4, 3 seconds to 30 minutes, 75 KB to 500 MB. Owner must be the caller │ Out of scope           │
│                                    │ finalizeUpload              │                         │                                                                         │                        │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/documents                    │ ACTION initializeUpload     │ ✅ Listed               │ PDF, DOC(X) or PPT(X), up to 100 MB and 300 pages. Owner must be the    │ Out of scope           │
│                                    │                             │                         │ caller                                                                  │                        │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ MultiImage (inline in /rest/posts) │ CREATE                      │ ✅ Listed               │ 2 to 20 images, organic posts only                                      │ Out of scope           │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ Poll (inline in /rest/posts)       │ CREATE                      │ ✅ Listed               │ Organic posts only                                                      │ Out of scope           │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ Article (inline in /rest/posts)    │ CREATE                      │ ✅ Listed               │ No URL scraping. You set the title, description and thumbnail yourself  │ Fallback if the        │
│                                    │                             │                         │                                                                         │ reshare spike fails    │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ Celebration posts                  │ CREATE                      │ ❌                      │ No external app can create them (returns 400). Read only, with          │ —                      │
│                                    │                             │                         │ r_*_social                                                              │                        │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/reactions                    │ CREATE, DELETE              │ ❌                      │ Needs w_member_social_feed (Community Management API)                   │ Phase 2                │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/socialActions/{urn}/comments │ CREATE, DELETE              │ ❌                      │ Moved to w_member_social_feed in June 2023                              │ Phase 2                │
├────────────────────────────────────┼─────────────────────────────┼─────────────────────────┼─────────────────────────────────────────────────────────────────────────┼────────────────────────┤
│ /rest/socialMetadata               │ PARTIAL_UPDATE              │ ❌                      │ w_member_social_feed                                                    │ —                      │
└────────────────────────────────────┴─────────────────────────────┴─────────────────────────┴─────────────────────────────────────────────────────────────────────────┴────────────────────────┘

Legacy /v2 APIs (from the 2020 mapping)

┌─────────────────────────────────────┬───────────────────────────────────────────────┬──────────────┬───────────────────────────────────────────────────────────────────────────────────────────┐
│              Resource               │                    Methods                    │ Status today │                                           Notes                                           │
├─────────────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ /v2/ugcPosts                        │ CREATE, DELETE /{id}                          │ ✅           │ The only endpoint documented on the self-serve "Share on LinkedIn" page. Covers text,     │
│                                     │                                               │              │ article and image shares. Its docs don't cover reshares                                   │
├─────────────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ /v2/shares                          │ CREATE, DELETE /{shareId}                     │ ⚠️ Legacy    │ LinkedIn says the Posts API replaces Shares                                               │
├─────────────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ /v2/assets                          │ ACTION registerUpload,                        │ ⚠️ Legacy    │ Replaced by the Images and Videos APIs. Still used by the Share on LinkedIn image flow    │
│                                     │ completeMultipartUpload, GET /{assetId}       │              │                                                                                           │
├─────────────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ /v2/assets (live)                   │ ACTION registerLiveEvent, endLiveEvent,       │ ⚠️ Legacy    │ Live video. Out of scope                                                                  │
│                                     │ FINDER playableStreams                        │              │                                                                                           │
├─────────────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ /v2/socialActions/{target}/comments │ CREATE, DELETE                                │ ❌ Since     │ Moved to w_member_social_feed                                                             │
│                                     │                                               │ June 2023    │                                                                                           │
├─────────────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────────────────┤
│ /v2/socialActions/{target}/likes    │ CREATE, DELETE                                │ ❌ Since     │ Moved to w_member_social_feed                                                             │
│                                     │                                               │ June 2023    │                                                                                           │
└─────────────────────────────────────┴───────────────────────────────────────────────┴──────────────┴───────────────────────────────────────────────────────────────────────────────────────────┘

Also needed alongside it

┌───────────────────────────────────────┬─────────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────────────────────────┐
│                 Scope                 │                         Product                         │                                       Why                                        │
├───────────────────────────────────────┼─────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────┤
│ openid, profile (and email if wanted) │ Sign In with LinkedIn using OpenID Connect (self-serve) │ You need the person URN for author. w_member_social alone doesn't give it to you │
└───────────────────────────────────────┴─────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────┘
```

Limits

- Rate limits (from the Share on LinkedIn page): 150 requests per member per day and 100,000 per app per day, reset at UTC midnight.
- Tokens: access tokens last 60 days, and self-serve apps get no programmatic refresh tokens.
- Headers: all versioned calls need LinkedIn-Version: YYYYMM (use 202610) and X-Restli-Protocol-Version: 2.0.0.

</details>



### Community Management API
> 2026-10-14: Application under review by LinkedIn

<details>
<summary>Click to expand</summary>

Here's the Community Management API for 202610, put together from the Microsoft Learn pages. All of these pages list li-lms-2026-10 as a supported version. The search index still serves the 202609 copies, but I couldn't find any Community Management changes in 202609 or 202610. The latest change to these endpoints was in 202605, when metricType on the member analytics endpoints became a string.

Base URL: https://api.linkedin.com/rest, with the headers LinkedIn-Version: 202610 and X-Restli-Protocol-Version: 2.0.0.

#### 🏢 Page management (organizations)

```
┌────────────────────────────────────────────────────────────┬──────────────────────────┬───────────────────────────────┬─────────────────────────────────────────────────────────┬───────────────┐
│                          Resource                          │         Methods          │             Scope             │                      Role / notes                       │    Amplify    │
├────────────────────────────────────────────────────────────┼──────────────────────────┼───────────────────────────────┼─────────────────────────────────────────────────────────┼───────────────┤
│ /organizations/{id}, ?ids=List(...)                        │ GET, BATCH_GET           │ rw_organization_admin         │ Full fields only for ADMINISTRATOR. Non-admins only get │ Confirm WSO2  │
│                                                            │                          │                               │  id, name, vanityName, logo, locations and type         │ org           │
├────────────────────────────────────────────────────────────┼──────────────────────────┼───────────────────────────────┼─────────────────────────────────────────────────────────┼───────────────┤
│                                                            │                          │                               │ Showcase pages are reached with parentOrganization. The │               │
│ /organizations?q=vanityName, ?q=parentOrganization         │ FINDER                   │ rw_organization_admin         │  Brand API is deprecated, so organizationBrand maps to  │ —             │
│                                                            │                          │                               │ organization                                            │               │
├────────────────────────────────────────────────────────────┼──────────────────────────┼───────────────────────────────┼─────────────────────────────────────────────────────────┼───────────────┤
│ /networkSizes/{orgUrn}?edgeType=COMPANY_FOLLOWED_BY_MEMBER │ GET                      │ rw_organization_admin         │ Total follower count                                    │ Dashboard     │
├────────────────────────────────────────────────────────────┼──────────────────────────┼───────────────────────────────┼─────────────────────────────────────────────────────────┼───────────────┤
│ /organizationAcls                                          │ FINDER roleAssignee,     │ rw_organization_admin,        │ PUT only lets you request DSC_POSTER for yourself       │ Gate the      │
│                                                            │ FINDER organization, PUT │ r_organization_admin          │                                                         │ admin screen  │
├────────────────────────────────────────────────────────────┼──────────────────────────┼───────────────────────────────┼─────────────────────────────────────────────────────────┼───────────────┤
│                                                            │ GET, BATCH_GET,          │                               │ Checks permissions instead of roles. LinkedIn           │ Gate the      │
│ /organizationAuthorizations                                │ BATCH_FIND               │ rw_organization_admin         │ recommends it over Acls. The docs still show a /v2 base │ admin screen  │
│                                                            │                          │                               │  path                                                   │               │
└────────────────────────────────────────────────────────────┴──────────────────────────┴───────────────────────────────┴─────────────────────────────────────────────────────────┴───────────────┘
```

#### 📝 Content (posts and media)

```
┌────────────────────────────┬───────────────────────────────┬─────────────────────────────────────────┬───────────────────────────────────────────────────────────────┬────────────────────────┐
│          Resource          │            Methods            │                  Scope                  │                         Role / notes                          │        Amplify         │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /posts                     │ CREATE                        │ w_organization_social (org),            │ Org posting needs ADMINISTRATOR, CONTENT_ADMIN or DSC_POSTER  │ Repost (member)        │
│                            │                               │ w_member_social (member)                │                                                               │                        │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /posts +                   │ CREATE                        │ same                                    │ Repost, or repost with thoughts                               │ Core                   │
│ reshareContext.parent      │                               │                                         │                                                               │                        │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /posts/{urn}               │ GET, BATCH_GET                │ r_organization_social / r_member_social │ r_member_social is closed. LinkedIn isn't accepting requests  │ Read org posts ✅,     │
│                            │                               │                                         │ for it                                                        │ member posts ❌        │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /posts?q=author            │ FINDER                        │ same                                    │ Up to 100 per page, sorted with sortBy                        │ List WSO2 posts        │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /posts?q=dscAdAccount      │ FINDER                        │ r_organization_social                   │ Sponsored posts                                               │ —                      │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /posts/{urn}               │ PARTIAL_UPDATE, DELETE        │ write scopes                            │ Only these fields can be changed: commentary, CTA label,      │ Undo a repost          │
│                            │                               │                                         │ landing page, lifecycleState, adContext                       │                        │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /images                    │ ACTION initializeUpload, GET  │ w_*_social                              │ Owner must be the caller. A token with only w_member_social   │ —                      │
│                            │                               │                                         │ can't GET                                                     │                        │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /videos                    │ ACTION initializeUpload,      │ w_*_social                              │ MP4, up to 500 MB and 30 minutes                              │ —                      │
│                            │ finalizeUpload                │                                         │                                                               │                        │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ /documents                 │ ACTION initializeUpload       │ w_*_social                              │ PDF or Office files, up to 100 MB and 300 pages               │ —                      │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ MultiImage, Poll, Article  │ inline in /posts              │ w_*_social                              │ Organic only. Articles get no URL scraping                    │ —                      │
├────────────────────────────┼───────────────────────────────┼─────────────────────────────────────────┼───────────────────────────────────────────────────────────────┼────────────────────────┤
│ Celebration                │ GET only                      │ r_*_social                              │ Can't be created through the API (returns 400)                │ —                      │
└────────────────────────────┴───────────────────────────────┴─────────────────────────────────────────┴───────────────────────────────────────────────────────────────┴────────────────────────┘
```

#### 💬 Social actions (engagement)

```
┌────────────────────────────────────┬────────────────────────┬──────────────────────────────────────────┬────────────────────────────────────────────────────────────┬──────────────────────────┐
│              Resource              │        Methods         │                  Scope                   │                        Role / notes                        │         Amplify          │
├────────────────────────────────────┼────────────────────────┼──────────────────────────────────────────┼────────────────────────────────────────────────────────────┼──────────────────────────┤
│ /reactions?actor={urn}             │ CREATE                 │ w_member_social_feed /                   │ LIKE, PRAISE, EMPATHY, INTEREST, APPRECIATION,             │ In-app react             │
│                                    │                        │ w_organization_social_feed               │ ENTERTAINMENT (MAYBE is deprecated)                        │                          │
├────────────────────────────────────┼────────────────────────┼──────────────────────────────────────────┼────────────────────────────────────────────────────────────┼──────────────────────────┤
│ /reactions/(actor:…,entity:…)      │ GET, DELETE            │ r_*_social_feed / w_*_social_feed        │ Org read needs ADMINISTRATOR or DSC_POSTER                 │ Verify a react           │
├────────────────────────────────────┼────────────────────────┼──────────────────────────────────────────┼────────────────────────────────────────────────────────────┼──────────────────────────┤
│ /reactions/(entity:…)?q=entity     │ FINDER                 │ r_organization_social_feed               │ Sort by chronological, reverse or relevance                │ Who reacted to the WSO2  │
│                                    │                        │                                          │                                                            │ post                     │
├────────────────────────────────────┼────────────────────────┼──────────────────────────────────────────┼────────────────────────────────────────────────────────────┼──────────────────────────┤
│ /socialActions/{urn}/comments      │ GET_ALL, BATCH_GET,    │ r_*_social_feed / w_*_social_feed        │ Nested comments go through urn:li:comment:(…)              │ In-app comment and       │
│                                    │ CREATE                 │                                          │                                                            │ verification             │
├────────────────────────────────────┼────────────────────────┼──────────────────────────────────────────┼────────────────────────────────────────────────────────────┼──────────────────────────┤
│ /socialActions/{urn}/comments/{id} │ GET, edit (POST),      │ same                                     │ Edit and delete take ?actor=                               │ —                        │
│                                    │ DELETE                 │                                          │                                                            │                          │
├────────────────────────────────────┼────────────────────────┼──────────────────────────────────────────┼────────────────────────────────────────────────────────────┼──────────────────────────┤
│ /socialMetadata/{urn}              │ GET, BATCH_GET         │ r_organization_social_feed               │ Reaction and comment counts                                │ Card counts              │
├────────────────────────────────────┼────────────────────────┼──────────────────────────────────────────┼────────────────────────────────────────────────────────────┼──────────────────────────┤
│ /socialMetadata/{urn}              │ POST (turn comments on │ w_*_social_feed                          │ Turning comments off deletes the existing ones             │ —                        │
│                                    │  or off)               │                                          │                                                            │                          │
└────────────────────────────────────┴────────────────────────┴──────────────────────────────────────────┴────────────────────────────────────────────────────────────┴──────────────────────────┘
```

#### 📊 Page analytics (ADMINISTRATOR)

```
┌────────────────────────────────────────────────────────────────┬───────────────────────────────┬───────────────────────┬───────────────────────────────────────────────────┬────────────────────┐
│                            Resource                            │            Methods            │         Scope         │                       Notes                       │      Amplify       │
├────────────────────────────────────────────────────────────────┼───────────────────────────────┼───────────────────────┼───────────────────────────────────────────────────┼────────────────────┤
│ /organizationalEntityFollowerStatistics?q=organizationalEntity │ FINDER                        │ rw_organization_admin │ Lifetime (by demographic) or by time window (day, │ Dashboard          │
│                                                                │                               │                       │  week or month)                                   │                    │
├────────────────────────────────────────────────────────────────┼───────────────────────────────┼───────────────────────┼───────────────────────────────────────────────────┼────────────────────┤
│ /organizationPageStatistics?q=organization                     │ FINDER                        │ rw_organization_admin │ Views and clicks, by day or month                 │ —                  │
├────────────────────────────────────────────────────────────────┼───────────────────────────────┼───────────────────────┼───────────────────────────────────────────────────┼────────────────────┤
│ /organizationalEntityShareStatistics?q=organizationalEntity    │ FINDER (+ shares=List(),      │ rw_organization_admin │ Organic only. Rolling 12 months, no paging        │ Reshare count per  │
│                                                                │ ugcPosts[])                   │                       │                                                   │ post               │
├────────────────────────────────────────────────────────────────┼───────────────────────────────┼───────────────────────┼───────────────────────────────────────────────────┼────────────────────┤
│ /videoAnalytics?q=entity                                       │ FINDER                        │ r_organization_social │ Watch time, views and viewers                     │ —                  │
└────────────────────────────────────────────────────────────────┴───────────────────────────────┴───────────────────────┴───────────────────────────────────────────────────┴────────────────────┘
```

###👤 Member analytics (the logged-in member)

```
┌─────────────────────────────────────────┬─────────┬───────────────────────────┬───────────────────────────────────────────────────────────────────────────────┬────────────────────────────────┐
│                Resource                 │ Methods │           Scope           │                                     Notes                                     │            Amplify             │
├─────────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────────────────────────────────────────────┼────────────────────────────────┤
│ /memberCreatorPostAnalytics?q=me /      │         │                           │ IMPRESSION, MEMBERS_REACHED, RESHARE, REACTION, COMMENT, POST_SAVE,           │ Impressions on an employee's   │
│ ?q=entity                               │ FINDER  │ r_member_postAnalytics    │ POST_SEND, LINK_CLICKS, plus a few more. RESHARE, REACTION and COMMENT counts │ repost, which could drive      │
│                                         │         │                           │  don't always match the UI                                                    │ points                         │
├─────────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────────────────────────────────────────────┼────────────────────────────────┤
│ /memberCreatorVideoAnalytics?q=entity   │ FINDER  │ r_member_postAnalytics    │ VIDEO_PLAY, VIDEO_VIEWER, VIDEO_WATCH_TIME                                    │ —                              │
├─────────────────────────────────────────┼─────────┼───────────────────────────┼───────────────────────────────────────────────────────────────────────────────┼────────────────────────────────┤
│ /memberFollowersCount?q=me /            │ FINDER  │ r_member_profileAnalytics │ Lifetime or daily follower counts                                             │ —                              │
│ ?q=dateRange                            │         │                           │                                                                               │                                │
└─────────────────────────────────────────┴─────────┴───────────────────────────┴───────────────────────────────────────────────────────────────────────────────┴────────────────────────────────┘
```

#### 📣 Employee advocacy

```
┌───────────────────────────────────────────────────────────────────────────┬──────────────────────────────┬──────────────────────────┬──────────────────────────────────────────┬────────────────┐
│                                 Resource                                  │           Methods            │          Scope           │                  Notes                   │    Amplify     │
├───────────────────────────────────────────────────────────────────────────┼──────────────────────────────┼──────────────────────────┼──────────────────────────────────────────┼────────────────┤
│                                                                           │                              │                          │ LIKE, COMMENT, SHARE, SHARE_MENTION,     │                │
│ /organizationalEntityNotifications?q=criteria                             │ FINDER                       │ rw_organization_admin    │ ADMIN_COMMENT, COMMENT_EDIT,             │ Find reshares  │
│                                                                           │                              │                          │ COMMENT_DELETE. Kept for 60 days. PUBLIC │ of WSO2 posts  │
│                                                                           │                              │                          │  posts only                              │                │
├───────────────────────────────────────────────────────────────────────────┼──────────────────────────────┼──────────────────────────┼──────────────────────────────────────────┼────────────────┤
│                                                                           │ PUT, GET, DELETE, FINDER     │                          │ Webhook push. Turned off on Development  │ Live tracking  │
│ /eventSubscriptions/(…eventType:ORGANIZATION_SOCIAL_ACTION_NOTIFICATIONS) │ subscriberAndEventType       │ rw_organization_admin    │ tier                                     │ (Standard      │
│                                                                           │                              │                          │                                          │ tier)          │
├───────────────────────────────────────────────────────────────────────────┼──────────────────────────────┼──────────────────────────┼──────────────────────────────────────────┼────────────────┤
│ /peopleTypeahead?q=organizationFollowers                                  │ FINDER                       │ r_organization_followers │ Restricted. Returns up to 10 followers,  │ —              │
│                                                                           │                              │                          │ for @mentions                            │                │
├───────────────────────────────────────────────────────────────────────────┼──────────────────────────────┼──────────────────────────┼──────────────────────────────────────────┼────────────────┤
│ /vanityUrl?q=vanityUrlAsOrganization                                      │ FINDER                       │ r_organization_followers │ Looks up a person URN by vanity URL      │ —              │
└───────────────────────────────────────────────────────────────────────────┴──────────────────────────────┴──────────────────────────┴──────────────────────────────────────────┴────────────────┘
```

### 🔐 Scopes the product grants

r_basicprofile, r_1st_connections_size, r_organization_followers, r_organization_social, r_organization_social_feed, rw_organization_admin, w_member_social, w_member_social_feed, w_organization_social, w_organization_social_feed, r_member_profileAnalytics, r_member_postAnalytics.

Not granted: r_member_social, which is closed.

#### ⚠️ Tier limits
```
┌─────────────┬──────────────────────────────────────────────────────────────────────────────────────────────────┐
│    Tier     │                                              Limits                                              │
├─────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Development │ 500 calls per app per day, 100 per member per day. No BATCH_GET. No webhooks. 12 months to build │
├─────────────┼──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ Standard    │ No restrictions. Needs a privacy policy and a screen-recording review                            │
└─────────────┴──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

What this means for Amplify Phase 2: with Community Management we could verify reactions (the /reactions FINDER), verify comments, track reshares (notifications) and score impressions on employee reposts (memberCreatorPostAnalytics). We still couldn't read a member's own posts directly.

Sources:
- Community Management Overview
- Organizations Overview
- Organization Lookup
- Org Access Control
- Org Authorizations
- Follower Stats
- Share Stats
- Page Stats
- Posts API
- Reactions
- Comments
- Social Metadata
- Member Post Stats
- Member Video Stats
- Member Follower Stats
- Org Social Action Notifications
- People Typeahead
- Increasing Access
- Recent Changes

</details>