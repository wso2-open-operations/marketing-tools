# WSO2 Amplify — Phase 1 Domain Model (DDD)

Builds on: [L0](../High%20Level/amplify-L0-solution.md) · [L1](../High%20Level/amplify-L1-solution.md) · [L2, Choreo approach (later phases)](../BrainStorms/amplify-L2-Choreo-Solution.md) · [Phase 1 solution architecture](phase1-solution-architecture.md)
Plan: [Phase 1 MVP plan and todos](../../../docs/requirements/phase1-planned-todos.md) · Data model: [phase1-data-model.md](phase1-data-model.md)
Audit mitigations applied 2026-10-16 ([requirements-map.md](requirements-map.md)). Phase labels follow its [Other phases](requirements-map.md#other-phases-refine-later) table (D5).
Inputs: requirements doc, the phase 1 scope change, the One WSO2 webapp review, LinkedIn's self-serve products ("Share on LinkedIn", "Sign In with LinkedIn using OpenID Connect", API version `202610`), and the Amplify screen wireframes.

## Phase 1 Scope 
ONE WSO2 app module, one Choreo project (the Amplify cell) fronted by an API proxy, two backend deployables (`amplify-api`, `amplify-jobs`) plus the scheduler (`akornatskyy/scheduler`, ADR-026) and one Postgres database. Employees connect LinkedIn once and share or repost WSO2 posts **through Amplify**, using the self-serve `w_member_social` permission. That needs no partner approval and costs nothing. Promotion done outside the app comes in as an **external share** (UI: "My Campaign"), reviewed by PO. 

New posts are announced in the **WSO2 Club Group** Google Chat space by webhook. Points are **held in the ledger**.

**Moved to later phases** (which phase: [requirements-map › Other phases](requirements-map.md#other-phases-refine-later)): the Amplify agent, classifier, LLM gateway, AMP and ThunderID; a separate queue service (phase 1 uses an outbox/jobs table in Postgres); engagement sync through the Community Management API (approval is still pending); the Coin issuer; HR Entity team and location sync; SLT reports; the employee data-deletion path (C3, ADR-016).

## Phase 1 decisions

Logged 2026-10-16. Details and todos are in the [plan](../../../docs/requirements/phase1-planned-todos.md). These D-numbers are local to this table; the [ADR register](../../decisions/README.md) maps them (B1).

| # | Decision | Why | ADR |
| --- | --- | --- | --- |
| D1 | **Ballerina** for `amplify-api` and `amplify-jobs` | Team standard. The LinkedIn mock is already Ballerina. Supersedes the L2's TypeScript | ADR-001 |
| D2 | **PostgreSQL**, one schema per bounded context; LinkedIn tokens in a **daily time-partitioned** table; a day is dropped once `max(expires_at)` in it + grace has passed (the only drop rule, B11). Needs `citext` and `pg_trgm` (B18) | Schemas keep context boundaries in the data. Dropping a partition deletes expired tokens in bulk, with no row-by-row deletes | ADR-002 |
| D3 | **`amplify-jobs` is a worker triggered over HTTP** (`POST /runs`, project visibility). The scheduler (`akornatskyy/scheduler`, ADR-026; amplify-cron and the Choreo Scheduled Task are retired) calls it on a schedule; "Save & Share Now" calls it right away | One worker, no internal timer. The schedule lives in one place, and the same image runs in Docker, Choreo and OpenChoreo | ADR-003 |
| D4 | **LinkedIn OAuth redirects to a One WSO2 route** (`/amplify/connect/callback`). The SPA posts `code` + `state` to `amplify-api` with its Asgardeo bearer token | No unauthenticated API resource. One WSO2 already keeps deep links across sign-in (`AuthGuard` + `postLoginRedirect`), but the route must not be mistaken for the Asgardeo sign-in callback (both carry `code`/`state`) | open |
| D5 | An **API proxy sits at the cell edge**: Choreo API Proxy in Choreo, WSO2 API Manager in local Docker. `amplify-api` is visible only inside the project | A single way in, with rate limits and subscriptions handled there. One WSO2 calls only the proxy | ADR-004 |
| D6 | **Data model:** PostgreSQL 18, `uuidv7()` keys, **no cross-context FKs** (virtual FKs documented), status **derived from fact timestamps**, provider-agnostic tables (Share on LinkedIn now, Community Management later), pre-built recognition tables for a fast One WSO2. See [phase1-data-model.md](phase1-data-model.md) | Contexts stay liftable; status can't drift; one schema serves any LinkedIn API | ADR-005 |
| D7 | **Phase 1 scoring:** in-app **reposts only** (plain or with thoughts, one per campaign per employee) plus PO-approved external shares. Comments and reactions are out of scope until a later phase | That's what the `w_member_social` API can verify | ADR-006 |

> The **Postgres outbox** is a design pattern used in distributed systems to ensure reliable message delivery by first storing messages in a local database table (the outbox) before sending them to a message broker. This pattern helps maintain atomicity, ensuring that both the business data and the message are saved in the same transaction, preventing data loss during failures.


```text
                                        WSO2 AMPLIFY · PHASE 1 CONTEXT MAP

PEOPLE      Marketing · registers posts        Employee · connects, shares, submits          PO team · reviews, allocates

            ┌─────────────────────────────────────────────────────────────┐    ┌──────────────────────────────┐
CHANNEL     │ ONE WSO2 · Amplify module                                   │    │ ONE WSO2 SSO       [GENERIC] │
no domain   │ register post · compose & share · external share · my points│───►│ Asgardeo identity and roles  │
logic       │ leaderboard · PO review · admin                             │    │ mktg · PO · SLT · admin grps │
            └──────────────────────────────┬──────────────────────────────┘    └──────────────────────────────┘
                                           │ OHS/PL: amplify-api REST
            ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
            ┃                              ▼                                                                     ┃
SUPPORTING  ┃  ┌─────────────────────────┐  ┌─────────────────────────┐  ┌─────────────────────────┐             ┃
            ┃  │ CAMPAIGN          [S1]  │  │ LINKEDIN CONNECTION[S2] │  │ EXTERNAL SHARING  [S3]  │             ┃
            ┃  │ register WSO2 posts     │  │ OIDC sign-in + consent  │  │ actions done outside    │             ┃
            ┃  │ category · priority     │  │ w_member_social token   │  │ the app · own posts     │             ┃
            ┃  │ save · save & share now │  │ 60-day expiry · remove  │  │ evidence URL · certify  │             ┃
            ┃  └──┬──────────────┬───────┘  └────────────┬────────────┘  │ PO review               │             ┃
            ┃     │              │CampaignRegistered     │ConnectionReady│                         │             ┃
            ┃     │              ▼                       ▼               └─────────────┬───────────┘             ┃
CORE        ┃     │  ┌───────────────────────────────────────────────────┐             │                         ┃
            ┃     │  │ SHARING                                    [C1]   │             │                         ┃
            ┃     │  │ share through Amplify                             │             │                         ┃
            ┃     │  │ ShareRequest · provider adapter (LinkedIn now)    │             │                         ┃
            ┃     │  └─────────────────────────┬─────────────────────────┘             │                         ┃
            ┃     │                            │SharePublished (verified)              │ExternalShareApproved    ┃
            ┃     │                            ▼                                       ▼                         ┃
            ┃     │  ┌──────────────────────────────────────────────────────────────────────────┐                ┃
            ┃     │  │ SCORING & POINTS LEDGER                                           [C2]   │                ┃
            ┃     │  │ rules · once per action per post per person · PO allocate and adjust     │                ┃
            ┃     │  │ append-only · audit log · points HELD (no Coin issue in phase 1)         │                ┃
            ┃     │  └──────────────────────────────────┬───────────────────────────────────────┘                ┃
            ┃     │CampaignRegistered                   │PointsAwarded / Adjusted / Reversed                     ┃
            ┃     ▼                                     ▼                                                        ┃
SUPPORTING  ┃  ┌─────────────────────────┐  ┌──────────────────────────────┐                                     ┃
            ┃  │ ANNOUNCEMENTS     [S5]  │  │ RECOGNITION            [S4]  │                                     ┃
            ┃  │ Club space cards        │  │ 3 leaderboards · my points   │                                     ┃
            ┃  │ chat notifier in jobs   │  │ PO dashboard                 │                                     ┃
            ┃  └────────────┬────────────┘  └──────────────────────────────┘                                     ┃
            ┗━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
                            │ ACL: incoming webhook             S2 and C1 ──► LinkedIn (ACL: OAuth/OIDC, provider adapter)
            ┌───────────────▼──────────┐                         ┌──────────────────────────────────────────────┐
EXTERNAL    │ GOOGLE CHAT   [EXTERNAL] │                         │ LINKEDIN                          [EXTERNAL] │
            │ Club space               │                         │ Sign In with LinkedIn (OIDC: sub → person)   │
            │ incoming webhook, cardsV2│                         │ Share on LinkedIn: POST /rest/posts          │
            └──────────────────────────┘                         │ self-serve · w_member_social · no approval   │
                                                                 └──────────────────────────────────────────────┘

            ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
LATER         Engagement Tracking (Community Mgmt API) · Rewards (Coin issuer) · Org data (HR Entity)
            │ Agent (Novera, classifier, LLM gateway, AMP, ThunderID) · queue service · other platforms           │
            └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘

C = core subdomain   S = supporting subdomain   OHS/PL = open host service + published language   ACL = anti-corruption layer
```

## Subdomains

| Subdomain | Type | Why |
| --- | --- | --- |
| Sharing (C1) | **Core** | This is how phase 1 knows, for certain, that an employee amplified a post. Amplify makes the share itself, so LinkedIn returns the new post's URN and there's nothing to infer. It replaces engagement sync until Community Management approval lands |
| Scoring & Points Ledger (C2) | **Core** | The programme's rules: tiers, "once per action per post per person", PO allocation and corrections, audit. That's what makes points fair |
| Campaign (S1) | Supporting | Registry of official WSO2 posts. Marketing writes and publishes them on LinkedIn |
| LinkedIn Connection (S2) | Supporting | Consent plus a token vault. Needed for sharing, but not the differentiator |
| External Sharing (S3) | Supporting | Intake for promotion Amplify can't see: an employee's own LinkedIn post, a Medium article, a blog. PO-reviewed |
| Recognition (S4) | Supporting | Read models: leaderboard, my points, PO views |
| Announcements (S5) | Supporting | Builds the Club card for a campaign. The webhook itself is generic |
| SSO, Google Chat, LinkedIn | Generic / external | Used as they are, behind clear boundaries |

## Bounded contexts

### C1 · Sharing (core)

Shares or reposts a campaign post on the employee's own LinkedIn, at their request.

| Aggregate | Key | Invariants |
| --- | --- | --- |
| `ShareRequest` (command) | `(campaign, employee)` unique (phase 1, B3; revisit with A4) | `kind ∈ {REPOST, REPOST_COMMENTARY}` (the D5 spike passed 2026-10-20, so the Amplify action is `REPOST`, [ADR-034](../../decisions/ADR-034-share-is-a-repost.md); `{SHARE, SHARE_COMMENTARY}` stay in the enums as the fallback, B4): **one share per campaign per employee** in phase 1, and the kind sets the tier. Can't be created without an active connection (S2). Facts `published_at` / `failed_at` (+ `failure_reason`); status `QUEUED / PUBLISHED / FAILED` is derived. **A retry after `FAILED` reuses the same row** (clear `failed_at`, bump `attempts`, re-queue; C2, ADR-015), so a failure never locks the employee out. Written to the outbox in the same transaction, so posting is asynchronous and idempotent. A rerun never posts twice |
| `Engagement` (fact) | `(provider, target resource, employee, action)` unique | What an employee **did** on a provider resource, from any source: `origin ∈ {IN_APP, API_SYNC, WEBHOOK}`, `provider_api ∈ {SHARE_ON_LINKEDIN, COMMUNITY_MANAGEMENT, …}`. Phase 1 writes only in-app reposts; Community Management sync writes the same table later. **Scoring reads engagements, never requests** |
| `ProviderAdapter` (port) | `linkedin` (later: other platforms) | The LinkedIn adapter calls `POST /rest/posts` with `author = urn:li:person:{id}`, `commentary` (optional), `reshareContext.parent = campaign post URN` for a repost, and headers `LinkedIn-Version: 202610`, `X-Restli-Protocol-Version: 2.0.0`. Reads `x-restli-id` as `provider_post_urn` |

Privacy: the employee's commentary is held only until the job posts it, then cleared. The record keeps the action, the URNs and the time, but not the text.
`EngagementRecorded` is a **verified** action: it's scored automatically, with no PO review.

### C2 · Scoring & Points Ledger (core)

| Aggregate | Key | Invariants |
| --- | --- | --- |
| `PointRule` | `(action, effective_from)` | Versioned; **the action is the tier**: repost (lowest), repost with thoughts (mid), own post (higher), own post amplified by WSO2 or a senior leader (highest). `SHARE` / `SHARE_COMMENTARY` price like their repost equivalents if the fallback is ever used. Maintained by `amplify_po` (A5, ADR-011). A change applies from the next scoring pass. Comment and reaction points are a future phase |
| `PointsLedger` (append-only facts) | `reference` = `AMP-` + base64url sha256(provider, resource, person, action), 47 chars (C1) | **Once per action per resource per person.** Corrections are reversal rows. The amplified (T4) award is a **top-up row** for the difference over the own-post award (C4). Settlement `status`: `HELD` (valid, waiting for Coins), `PAID` (phase 2), `null` (**action required**). Only the settlement columns are updatable |
| `Allocation` / `Adjustment` | ledger reference | A PO actor (`amplify_po`) and a **reason** are required, and both go to the audit log. `amplify-api` writes the ledger row and the `recognition` update in one transaction (B12) |

### S1 · Campaign

| Aggregate | Key | Invariants |
| --- | --- | --- |
| `Campaign` | `(provider, resource_urn)` unique, any resource type | The resource must be on the WSO2 company page. Registered by `amplify_marketing` or `amplify_po` (A6, ADR-012). Category, tags, priority flag, active window (`closes_at` defaults to `opens_at` + `campaign.default_window_days`, 30; C7). Status `SCHEDULED / OPEN / CLOSED / ARCHIVED` is **derived** from `opens_at`, `closes_at`, `archived_at`. **Save** queues the Club announcement for the next jobs run; **Save & Share Now** queues it right away. Announced exactly once (outbox) |

### S2 · LinkedIn Connection

| Aggregate | Key | Invariants |
| --- | --- | --- |
| `LinkedInConnection` | employee (SSO `sub`), `member_urn` unique | Created by OAuth 2.0 with the scopes `openid profile w_member_social` (Sign In with LinkedIn using OpenID Connect + Share on LinkedIn). `member_urn` = `urn:li:person:{sub}` from the ID token (B13). Stored as `connection.member_connection` (provider-agnostic; an `org_connection` for Community Management comes in a future phase). LinkedIn returns a plain bearer token; **we** encrypt it (AES-256-GCM, our key, the same approach as Novera and Coin) into the daily-partitioned `provider_token` table, and decrypt it in memory only to call LinkedIn. It expires in about 60 days. Expiry (time-derived, no event) or a 401 from LinkedIn (`ConnectionRevoked`) means `NEEDS_RECONNECT` (derived from `access_expires_at` / `revoked_at`), and the employee sees Link Me again. **Remove Connection** deletes the token and stops sharing |

Self-serve apps don't get programmatic refresh tokens, so expect a reconnect every 60 days. Plan a reminder (a card or banner) before expiry.

### S3 · External Sharing

| Aggregate | Key | Invariants |
| --- | --- | --- |
| `ExternalShare` | id; `(evidence_url, action)` unique across all employees, URL normalized first (C5, ADR-017) | `action ∈ {OWN_POST}` in phase 1 (later: article, comment). An evidence URL and the **"I certify this is related to WSO2"** checkbox are both required. Facts `decision` + `decided_at` + `decided_by`, and `amplified_at` (only on an approved claim, `CHECK`, C4); status `PENDING / APPROVED / REJECTED / AMPLIFIED` is derived. A URL someone already claimed returns `EVIDENCE_ALREADY_CLAIMED`. Phase 1 can't verify these on LinkedIn, so **PO reviews each one**. Approval allocates `OWN_POST` points through C2; `ExternalShareAmplified` adds the T4 top-up |

This merges the earlier **Submit Post** screen (own posts) with external shares for actions taken outside Amplify. In the UI it's called **My Campaign** (2026-10-15 review). The evidence URL can be any public HTTPS promotion (LinkedIn, Medium, a blog), not only LinkedIn. It is never fetched server-side.

### S4 · Recognition (read models)

Projections over the C2 ledger, stored as **pre-built tables** (`recognition.standing`, ranks precomputed) and updated in the same transaction as each ledger insert (by jobs for automatic awards, by `amplify-api` for PO decisions and corrections, B12), so One WSO2 reads are single indexed lookups with ETag caching. Nothing is written back; everything is rebuildable from the ledger.
- **Leaderboards** (B15, ADR-014; spec: [leaderboards.md](leaderboards.md)): three views. **Company top N** (`leaderboard.top_n`, default 3, B16), **personal** (own rank, points and `points_to_top_n`), and **My Team** (ranked within the viewer's team, team from One WSO2 data, ADR-009). There is no full company list for employees (2026-10-15 review: a long list reads as gossip, not motivation).
- **Team** (was Coins): searchable, paged, with an expandable history per person. Employees see their own team; `amplify_po` sees the whole company and is the only role that can adjust or reverse (ADR-010, [leaderboards.md](leaderboards.md#visibility)). Team and department data come from One WSO2, so Amplify stays HR-free in phase 1.
- **My points:** total, rank, monthly history across shares, external shares and adjustments, and the employee's own shares. **Points only, no Coin value** (A11). Per-share metrics are a future phase (ADR-018).
- **PO dashboard** (phase 1, B6, ADR-013; spec: [po-dashboard.md](po-dashboard.md)): external share queue, action-required ledger rows, participation per campaign, connections, recent corrections. SLT reports are phase 2.

**Pre-coin verification (future phase, ADR-018; C6):** before held points can ever become coins, a jobs pass will check that each engagement still exists on LinkedIn. If the employee deleted it, a reversal row (`ENGAGEMENT_DELETED`) removes those points; if it can't be checked, the ledger row's status becomes `null` (action required). This blocks the delete-after-earning trick. M0b research showed reading a member's post needs `r_member_social` (Community Management), so in phase 1 this is **designed, not running**: points simply stay `HELD`, and no Coins are issued until it works. Combined with "once per post per person per action", re-sharing can't earn twice.

### S5 · Announcements

| Aggregate | Key | Invariants |
| --- | --- | --- |
| `Announcement` | outbox id, per campaign | One card per campaign to the Club space through the **incoming webhook**: image, title, summary, and an openLink button to the campaign's **share page in One WSO2** (webhooks can't take button clicks). Retries with backoff, then `FAILED`, shown in admin |

## Context map relationships

| Upstream → Downstream | Pattern | Integration | Notes |
| --- | --- | --- | --- |
| One WSO2 SSO (Asgardeo) → amplify-api | **Conformist** | OIDC access token through the API proxy, signature verified (JWKS) | Roles come from groups: employee (no role), `amplify_marketing` (register campaigns), `amplify_po` (review, allocate, adjust, **point rules** A5, **campaigns** A6, PO dashboard), `amplify_slt` (reports, phase 2), `amplify_admin` (settings) |
| LinkedIn → S2 | **ACL** | OAuth 2.0 + OIDC (`openid profile w_member_social`) | Turns `sub` into a person URN and handles token expiry |
| C1 → LinkedIn | **ACL** (provider adapter) | `POST /rest/posts`, version `202610` | Hides LinkedIn's post model behind the port. 202511 sunsets on 2026-11-16 |
| S1 → C1 | Customer/Supplier | (none: C1 reads the derived `OPEN` status) | A post opens for sharing by its window; there's no `CampaignOpened` event (B9) |
| S1 → S5 | Customer/Supplier | `CampaignRegistered` | S5 queues and sends the Club card, then records `CampaignAnnounced` (B8) |
| S2 → C1 | Customer/Supplier | `ConnectionReady` / `ConnectionRevoked` / `ConnectionRemoved` | Reposts need an active connection |
| C1 → C2 | Customer/Supplier | `EngagementRecorded` (`EngagementDeleted` future, ADR-018) | Auto-scored / reversed |
| S3 → C2 | Customer/Supplier | `ExternalShareApproved` / `ExternalShareAmplified` | PO-allocated; T4 top-up |
| C2 → S4 | Published events | `PointsAwarded/Adjusted/Reversed` | |
| S5 → Google Chat | **ACL** | Incoming webhook, cardsV2 | |
| amplify-api → One WSO2 | **OHS + Published Language** | REST, OpenAPI 3, published through the API proxy at the cell edge | One WSO2 gates on `GET /me` capabilities and hides items a role doesn't allow |

## Domain events (outbox / jobs table)

**The event catalogue lives in one place: [phase1-data-model › Domain events](phase1-data-model.md#domain-events--which-table-changes)** (B9). It lists every phase 1 event with publisher, consumer, the tables each side writes and the idempotency key, including `ConnectionRevoked`, `ExternalShareAmplified` and the future `EngagementDeleted`. Campaign opening and connection expiry are time-derived, so there are no `CampaignOpened` or `ConnectionExpired` events, and `EmployeeErased` isn't in phase 1 (C3).

All of these are rows in Postgres. The single `amplify-jobs` worker claims them with `FOR UPDATE SKIP LOCKED` in bounded batches. There's no separate queue service in phase 1.

## Mapping to the phase 1 deployables (Choreo)

Schema-qualified names: one Postgres schema per context. A module writes only to its own schema. Full ERD: [phase1-data-model.md](phase1-data-model.md).

| Context | Deployable | Postgres |
| --- | --- | --- |
| S1 Campaign | `amplify-api` (`/campaigns`) | `campaign.campaign`, `campaign.campaign_tag`, `campaign.category`, `messaging.outbox` |
| S2 Connection | `amplify-api` (`/connections/linkedin`: start, complete, remove) | `connection.member_connection`, `connection.provider_token` (encrypted, daily partitions), `connection.oauth_state`; future: `connection.org_connection` |
| C1 Sharing | `amplify-api` (`/campaigns/{id}/shares`) + `amplify-jobs` LinkedIn provider adapter | `sharing.share_request`, `sharing.engagement`, `sharing.engagement_verification`, `messaging.outbox`; future: `engagement_metric`, `sync_cursor` |
| S3 External Sharing | `amplify-api` (`/external-shares`, `/po/external-shares`) | `external_sharing.external_share` |
| C2 Scoring | `amplify-api` (`/po/point-rules` A5, `/po/points`) + `amplify-jobs` score pass | `scoring.point_rule`, `scoring.points_ledger`, `audit.audit_log` |
| S4 Recognition | `amplify-api` (`/leaderboard`, `/team`, `/me/points`, `/po/dashboard`) + `amplify-jobs` score pass (both write, B12) | `recognition.standing`, `recognition.standing_version`, `recognition.employee_points_monthly`, `recognition.campaign_participation` (pre-built tables) |
| S5 Announcements | `amplify-jobs` chat notifier | `announcement.announcement`, `messaging.outbox` |
| (shared) | `amplify-api` | `identity.employee`, `config.app_setting` |

Deployables: **One WSO2 Amplify module** (UI), **Amplify API Proxy** (cell ingress), **Amplify Backend** (`amplify-api`, Choreo service), **Amplify Jobs** (`amplify-jobs`, one worker that runs the provider adapters, the chat notifier and scoring), **Amplify Scheduler** (`amplify-scheduler`, the pinned `akorn/scheduler` image with its own Postgres database; it triggers runs and the daily `/maintenance/partitions` call: token partitions, audit partitions, outbox purge, B10; amplify-api pushes the schedules from admin settings, ADR-026). One Choreo-managed **Postgres**.

## Ubiquitous language

| Term | Meaning |
| --- | --- |
| Campaign | A registered official WSO2 LinkedIn post that's open for sharing |
| Connect | Link a LinkedIn account by OAuth so Amplify can post for the employee |
| Share / repost / repost with thoughts | What Amplify publishes on the employee's LinkedIn. Verified and auto-scored |
| External share | An employee's claim for an action Amplify didn't see, submitted from My Campaign. PO-reviewed. (Replaces the old "check-in" wording, D2) |
| Own post | An external share for the employee's original WSO2-related post |
| Points | Ledger credits. Held in phase 1; shown as points only, no Coin value |
| Club space | The Google Chat space where new campaigns are announced |
| Run | One amplify-jobs pass: announce, publish shares, score |

## What changes from the Choreo L2

| L2 element | Phase 1 |
| --- | --- |
| `amplify-agent`, Novera tools, Anthropic | Later phase |
| 5 scheduled jobs, TypeScript | One Ballerina `amplify-jobs` worker (provider adapters + chat notifier + scoring), triggered by the scheduler (ADR-026) |
| `post` | `campaign.campaign` |
| `employee_link` | `connection.member_connection` + `identity.employee` |
| `announcement_outbox` | `messaging.outbox` + `announcement.announcement` |
| B5 engagement sync (Community Management API) | Later. Replaced by verified shares (C1) and external shares (S3) |
| B7 announcements through Novera | Club space incoming webhook (S5) |
| B8 Coin issuer, `coin_issue` | Later. Points held in `points_ledger` |
| B6 HR Entity, `org_dim` | Later. Team grouping for My Team comes from One WSO2's employee data instead (ADR-009) |
| No member tokens (org-admin token only) | Member `w_member_social` tokens, encrypted in the token store |
| `engagement_event`, `sync_cursor` | `sharing.engagement` (same idea, any API/origin), `sharing.sync_cursor` (future); `submission` becomes `external_sharing.external_share` |

## Open questions

| # | Question | Context |
| --- | --- | --- |
| 1 | **Prototype:** can a member token with `w_member_social` reshare an *organization* post (`reshareContext.parent`), or only create new posts that link to it? This decides whether REPOST is possible in-app or SHARE only. Both are in the enums already (B4), so either answer needs no migration | C1 |
| 2 | ~~Do comments and reactions earn points?~~ **Decided:** out of scope for phase 1 (ADR-006); revisit later | S3, C2 |
| 3 | 60-day reconnect: what reminder (Club card, One WSO2 banner) and how many days ahead? | S2 |
| 4 | Removing the connection: keep earned points, or reverse them? | S2, C2 |
| 5 | ~~Does the Club card's share link need the One WSO2 deep link to survive login?~~ **Answered:** yes, it survives. `AuthGuard` saves the path in sessionStorage before sign-in and restores it afterwards (`layouts/postLoginRedirect.ts`), within the same tab | S5 |
| 6 | Leaderboard period: all time, quarter, or campaign | S4 |
| 7 | Token store: encryption key in a Choreo secret, rotated how often? Needs a security review (new sensitive data: member tokens). Retention: daily partitions dropped once every token in them is past expiry + 5-day grace (ADR-002). Audit log kept 5 years | S2 |
