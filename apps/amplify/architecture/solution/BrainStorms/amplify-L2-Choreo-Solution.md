# OLD APPROACH - CHOREO / ASGARDEO
# WSO2 Amplify — L2 Solution Architecture

> **Superseded for phase 1 (2026-10-16). Later-phase reference only.** Phase 1 replaced much more than the stack. Read the full list in [phase1-domains › What changes from the Choreo L2](../Phase%201/phase1-domains.md#what-changes-from-the-choreo-l2) before relying on anything here. In short:
> - **TypeScript / Express → Ballerina.** `amplify-api`, `amplify-jobs` and `amplify-cron` are Ballerina (ADR-001).
> - **Five Choreo Scheduled Tasks → one worker plus a cron trigger.** A single `amplify-jobs` worker drains the Postgres outbox (provider adapters, chat notifier, scoring); `amplify-cron` triggers it, and "Save & Share Now" triggers it right away (ADR-003).
> - **An API proxy sits at the cell edge** (ADR-004); this L2 has none.
> - **Engagement sync (B5), Novera announcements (B7), the Coin issuer (B8), HR Entity `org_dim` (B6) and the agent** are all later phases. Phase 1 uses in-app shares through `w_member_social`, PO-reviewed external shares, a Google Chat incoming webhook, and points held in the ledger.
> - **Member tokens:** phase 1 stores encrypted `w_member_social` member tokens; this L2 assumed an org-admin token only.
> - **Tables renamed and split** (`post` → `campaign.campaign`, `employee_link` → `connection.member_connection`, `submission` → `external_sharing.external_share`, …). See [phase1-data-model.md](../Phase%201/phase1-data-model.md).
>
> Phase 1 scope and design: [phase1-domains.md](../Phase%201/phase1-domains.md) · plan: [phase1-planned-todos.md](../../../docs/requirements/phase1-planned-todos.md). The rest of this doc stays as the later-phase reference (engagement sync, Coin, HR Entity, agent).

Builds on: [L0](../High%20Level/amplify-L0-solution.md) · [L1](../High%20Level/amplify-L1-solution.md)
Inputs: requirements doc, weekly status report, and repo reviews of `projects/one-wso2`, `projects/wso2-digital-agents/po-agent`, `projects/wso2-coin`, `projects/people-ops-suite`, `apps/amplify/linkedin/resources/openapi`.

L2 adds communication patterns, component structure, data paths and error handling. Every arrow labelled `B#` is described in the boundary table below.

```text
              WSO2 AMPLIFY · L2 SOLUTION ARCHITECTURE

                ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐
PEOPLE          │     Employees      │    │   Marketing & PO   │    │      PO Admin      │    │        SLT         │
                │    830+, opt-in    │    │   register posts   │    │   points & fixes   │    │      reports       │
                └────────────────────┘    └────────────────────┘    └────────────────────┘    └────────────────────┘
                           │                         │                         │                         │
                           └────────┬────────────────┴────────────────────┬────┴─────────────────────────┘
                                    ▼                                     ▼                                 SYSTEMS ─────────────────────────────
                ┌────────────────────────────────────────┐    ┌────────────────────────────────┐            ┌───────────────────────────────────┐
CHANNELS        │ ONE WSO2  React web app          [ADD] │    │ GOOGLE CHAT         [EXISTING] │            │ ASGARDEO  WSO2 prod      [CONFIG] │
                │ Amplify app: own left-menu icon        │    │ Amplify space · user DMs       │            │ apps: One WSO2 · Novera           │
                │ leaderboards · my points · admin       │    └────────────────┬───────────────┘            │       Amplify Link (new)          │
                │ preview flag · gate: GET /me           │                     │                            │ LinkedIn federated connection     │
                │ Bearer Asgardeo access token           │                     ▼                            │ groups: amplify-admin,            │
                └───────────────────┬────────────────────┘    ┌────────────────────────────────┐            │   amplify-content, amplify-slt    │
                                    │                         │ NOVERA  po-agent · TS [UPDATE] │            │ Choreo key manager                │
                                    │                         │ tools: amplify_ask,            │            │ B3 link: browser redirect,        │
                                    │                         │        amplify_submit_post     │ B7         │    auth code + PKCE               │
                                    │                         │ /internal/notifications        │◄────┐      │ B11 sign-in + tokens, used by     │
                                    │B1 REST/JSON             │   + target space (new)         │     │      │      channels, amplify, systems   │
                                    │                         │ Bearer user id_token           │     │      └───────────────────────────────────┘
                                    │                         └────────────────┬───────────────┘     │
                                    │                                          │B2                   │
                                    ▼                                          ▼                     │
                ┌──────────────────────────────────────────────────────────────────────────────┐     │
                │ CHOREO API GATEWAY  apis.wso2.com · Asgardeo keys · Bearer → x-jwt-assertion │     │
                └───────────────────┬──────────────────────────────────────────┬───────────────┘     │
                                    │                                          │                     │
                                    │                                          │                     │
                ┏━━━━━━━━━━━━━━━━━━━┿━━━━━ CHOREO PROJECT: wso2-amplify  [NEW] ┿━━━━━━━━━━━━━━━━━━━━━┿┓
                ┃                   ▼                                          ▼                     │┃
WSO2            ┃  ┌────────────────────────────────────┐     ┌────────────────────────────────────┐ │┃
AMPLIFY         ┃  │ AMPLIFY-API  TS · Express  Service │     │ AMPLIFY-AGENT  TS          Service │ │┃     ┌───────────────────────────────────┐
                ┃  │ REST · OpenAPI 3                   │     │ POST /query                        │ │┃     │ ANTHROPIC CLAUDE       [EXTERNAL] │
                ┃  │ /me /posts /submissions            │     │ 1 classify topic (Haiku)           │ │┃     │ Haiku classify · Sonnet answer    │
                ┃  │ /profile/linkedin/link             │     │ 2 retrieve: Postgres FTS           ├─┼╂────►│ API key in Choreo secret          │
                ┃  │ /leaderboards /me/history          │     │   rules · FAQ · posts ·            │ │┃     │ B4 egress, timeout 30s            │
                ┃  │ /reports /admin/*                  │     │   my points & history              │ │┃     └───────────────────────────────────┘
                ┃  │ verify assertion (JWKS)            │     │ 3 answer + cite (Sonnet)           │ │┃
                ┃  │ groups → capabilities              │     │ read-only DB role                  │ │┃     ┌───────────────────────────────────┐
                ┃  │ writes outbox rows                 │     │ per-user daily token quota         │ │┃     │ LINKEDIN REST API      [EXTERNAL] │
                ┃  └────────────────┬───────────────────┘     └───────┬────────────────────────────┘ │┃     │ Community Mgmt:                   │
                ┃                   │B9 rw    ┌───────────────────────┘                              │┃     │   GET /reactions?q=entity         │
                ┃                   ▼         ▼   B9 ro                                              │┃     │   GET /socialActions/{urn}/       │
                ┃  ┌────────────────────────────────────┐     ┌────────────────────────────────────┐ │┃B5   │       comments                    │
                ┃  │ POSTGRES                 Choreo DB │     │ AMPLIFY-JOBS  TS    5 Sched. Tasks ├─┼╂────►│ ⚠ approval: mock in dev           │
                ┃  │ post · employee_link               │     │ own Choreo cron each (default):    ├─┘┃     └───────────────────────────────────┘
                ┃  │ engagement_event  (uniq)           │ B9  │ a sync engagement   every 30 min   │  ┃     ┌───────────────────────────────────┐
                ┃  │ submission · point_rule            │◄───►│ b score → ledger    30 min, +10    ├──╂────►│ HR ENTITY GRAPHQL      [EXISTING] │
                ┃  │ points_ledger  (uniq ref)          │     │ c announcements     every 5 min    │  ┃B6   │ email → team, location            │
                ┃  │ coin_issue · outbox                │     │ d issue coins       daily [off]    │  ┃     └───────────────────────────────────┘
                ┃  │ audit_log · org_dim                │     │ e team/location     daily          │  ┃
                ┃  │ sync_cursor                        │     │ shared lib · rerun-safe            │  ┃     ┌───────────────────────────────────┐
                ┃  │                                    │     │                                    ├──╂────►│ WSO2 COIN                [DEPEND] │
                ┃  └────────────────────────────────────┘     └────────────────────────────────────┘  ┃B8   │ transaction-service               │
                ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛     │ POST /wallets/master/transfer     │
                                                                                                            │ ⚠ needs email→wallet +            │
                                                                                                            │   caller reference (ask)          │
                                                                                                            │ client creds · org network        │
                                                                                                            └───────────────────────────────────┘

B# = boundary, see table   ⚠ tracked risk   [NEW]/[ADD]/[UPDATE]/[CONFIG] change type   [DEPEND] other-team system
Lanes: PEOPLE (who) · CHANNELS (where they work) · WSO2 AMPLIFY (what we build) · SYSTEMS (what it connects to)
Later (alignment addition): LinkedIn ORGANIZATION_SOCIAL_ACTION_NOTIFICATIONS webhook → amplify-api, persist + 202 (B10)
```

## Components

| Component | Choreo type | Stack | Responsibility | Pattern copied from |
| --- | --- | --- | --- | --- |
| `amplify-api` | Service (REST, public via `apis.wso2.com`) | TypeScript, Express, Postgres | Posts, profile linking, submissions, leaderboards, history, reports, admin. Writes outbox rows; never calls downstream systems in the request path. | Novera `src/index.ts` (helmet, rate limit), `wso2-coin` handler → service → repository layout |
| `amplify-agent` | Service (REST via gateway) | TypeScript, Anthropic SDK | `POST /query`: classify topic → retrieve from Postgres → answer with citations. Read-only DB role. | Novera `src/agent/claude.ts` (prompt caching, quota, `logAction`) |
| `amplify-jobs` | 5 Scheduled Tasks, each with its own cron | TypeScript, one shared library | (a) sync engagement, every 30 min · (b) score → ledger, every 30 min offset +10 · (c) send announcements, every 5 min · (d) issue coins, daily, flag off · (e) refresh team/location, daily. Each one can be scheduled, paused and rerun on its own. Every job is safe to rerun. | `people-ops-suite/apps/people-app/people-scheduler`, `leave-app/sabbatical-reminder` |
| Postgres | Choreo-managed database | PostgreSQL | System of record for posts, links, engagement, ledger, outboxes, audit | — |
| One WSO2 **Amplify app** | Existing web app (add) | React, TanStack Query, Oxygen UI | Amplify is its **own app with its own left-menu icon**: a new entry in `PERSPECTIVES` (`src/constants/perspectives.ts`) plus `src/constants/amplifyApps.ts` for its menu. It has leaderboards, my points/history, dashboards and admin screens, sits behind preview flag `amplify`, and checks access with `useAmplifyGate` → `GET /me`. | `one-wso2/webapp/src/features/til`, `useMarketingOpsGate.ts` |
| Novera | Existing service (update) | TypeScript | Two new tools, `amplify_ask` and `amplify_submit_post`. `/internal/notifications` gets an optional `space` target. | `po-agent/src/tools/releases.ts` |

**Repo layout for `apps/amplify`** (follows `wso2-coin`): `amplify-api/`, `apps/amplify-agent/`, `operations/amplify-jobs/{sync-engagement,score,announce,issue-coins,refresh-org}/` (one Choreo component per job) + `operations/amplify-jobs/shared/`. Each has its own `.choreo/component.yaml`, `openapi.yaml`, `.env.example`, `resources/*.sql` migrations, a README and the WSO2 Apache-2.0 header. The UI lives in the One WSO2 repo, not here.

## Boundaries

Checklist key: **Auth** · **Corr** = correlation ID · **Idem** = idempotency · **Async** = persist-first.

| # | From → To | Call | Auth | Corr | Idem | Response / async |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | One WSO2 → amplify-api | REST/JSON over HTTPS via Choreo gateway (`apis.wso2.com`, CSP requires `*.wso2.com`) | Asgardeo access token (One WSO2 client in audience); gateway issues `x-jwt-assertion`; API **verifies the signature** against the Choreo JWKS | `X-Correlation-ID` created by SPA, echoed back | `Idempotency-Key` header on POSTs | 200/201; admin writes 202 when an outbox row is created |
| B2 | Novera → amplify-agent, amplify-api | `POST /query`, `POST /submissions` via gateway | User's Asgardeo id_token (Novera's pattern), verified via gateway assertion | Novera passes its turn ID as `X-Correlation-ID` | Submission key = `chat message name` | 200 (answer); 202 for submissions |
| B3 | Browser ↔ Asgardeo ↔ LinkedIn | OIDC auth code + PKCE, "Amplify Link" app with LinkedIn federated connection | Asgardeo | `state` carries correlation ID | Re-linking replaces the existing link | amplify-api callback stores `urn:li:person:{id}`, consent time, scope |
| B4 | amplify-agent → Anthropic | HTTPS egress, Messages API | API key (Choreo secret) | Passed in request metadata | n/a (read only) | 30s timeout; per-user daily token quota |
| B5 | amplify-jobs → LinkedIn | Rest.li GET with `LinkedIn-Version` header: `/reactions?q=entity`, `/socialActions/{urn}/comments` | Org-admin 3-legged OAuth token for the WSO2 page (encrypted refresh token in DB) | Per run + per post | `sync_cursor` per post; `UNIQUE(post_urn, actor_urn, action)` | Backoff on 429/5xx, resumes from cursor; mock server in dev from `community-management.openapi.yaml` |
| B6 | amplify-jobs → HR Entity GraphQL | `getEmployee(email)` | OAuth2 client credentials | Per run | Upsert by email | Daily refresh into `org_dim` |
| B7 | amplify-jobs → Novera `/internal/notifications` | POST card `{source:"AMPLIFY", space, title, body, link}` | Client credentials via gateway (existing Novera inbound pattern) | Announcement ID | `announcement_outbox.id` | 202; outbox retries ×5, then `failed` → admin screen |
| B8 | amplify-jobs → WSO2 Coin transaction-service | `POST /wallets/master/transfer` **(placeholder contract)** | Client credentials; Amplify's client mapped to a `client_master_wallet` | Ledger reference | `reference` = ledger ref, `source="AMPLIFY"` | 201 / replay 200 / 409 conflict. **Feature flag off** until Coin is ready; points stay in `points_ledger` |
| B9 | api / agent / jobs → Postgres | TLS SQL | Separate DB user per component; agent is read-only | — | Unique constraints are the dedupe boundary | — |
| B10 | LinkedIn → amplify-api *(later)* | `ORGANIZATION_SOCIAL_ACTION_NOTIFICATIONS` webhook | LinkedIn signature check | Event ID | Same unique key as B5 | Persist + 202, jobs score it. B5 stays as the reconciling backstop |
| B11 | Channels, Amplify and systems → Asgardeo | OIDC sign-in and token issuance for One WSO2, Novera and the "Amplify Link" app (channels); Choreo key manager validating tokens at the gateway (Amplify); client credentials for Novera, HR Entity and Coin (systems) | Asgardeo (WSO2 production) | `state` / request ID | Tokens are short-lived and reissued, nothing to dedupe | Standard OIDC responses. Everything else in this table depends on it. B3 is the LinkedIn-link flow that runs on top of it |

**Single writer:** amplify-api and amplify-jobs are the only writers to the Amplify DB. Coin balances are written only by the Coin transaction-service (B8). Novera and One WSO2 never write to the DB directly.

## Data model (Postgres)

| Table | Key columns | Notes |
| --- | --- | --- |
| `post` | `post_urn` PK, category, priority, registered_by, registered_at, track_until | Registered by Marketing/PO. `track_until` defaults to +30 days |
| `employee_link` | `email` PK, asgardeo_sub, `linkedin_person_urn` UNIQUE, consent_at, unlinked_at | Opt-in. Unlinking stops tracking and removes the URN |
| `engagement_event` | id, post_urn, actor_urn, action (`REACTION`/`COMMENT`/`REPOST`/`REPOST_COMMENTARY`), occurred_at, **UNIQUE(post_urn, actor_urn, action)** | Engagement from people who haven't linked is **dropped, not stored**. No comment text is kept |
| `submission` | id, email, post_url/urn, status (`PENDING`/`APPROVED`/`REJECTED`/`AMPLIFIED`), reviewed_by | Own posts. PO review queue |
| `point_rule` | action, tier, points, effective_from | PO edits these. Old rules are kept for audit |
| `points_ledger` | `reference` PK (`AMP-` + hash of post+person+action, ≤66 chars to match Coin), email, points, rule_id, source_event, created_at, reversed_by | Append-only. Corrections are reversal rows |
| `coin_issue` | ledger_reference FK, status (`HELD`/`SENT`/`FAILED`), coin_reference, attempts, next_attempt_at | Every row is `HELD` until the flag is on |
| `announcement_outbox` | id, post_urn, space, status, attempts, next_attempt_at | Written in the same transaction as `post` |
| `org_dim` | email PK, team, sub_team, location, refreshed_at | From HR Entity; feeds the team/location reports |
| `sync_cursor` | post_urn, endpoint, cursor, last_run_at | Lets a sync resume after a failure |
| `audit_log` | id, actor, action, entity, before/after hash, correlation_id, at | Every admin change and every ledger reversal |

Outbox workers claim rows with `FOR UPDATE SKIP LOCKED` in bounded batches.

## Key flows

1. **Publish.** Marketing/PO `POST /posts` in One WSO2. amplify-api writes `post` and `announcement_outbox` in one transaction and returns 201. The announcements job (c, every 5 min) sends the card to the Amplify Chat space through Novera (B7).
2. **Link.** The employee clicks "Link LinkedIn" in One WSO2 → Asgardeo Amplify Link app → LinkedIn sign-in (B3). The callback stores `linkedin_person_urn` with the consent time.
3. **Track.** Job (a) loops over posts where `now() < track_until`, pulls reactions and comments (B5), keeps only actors that match `employee_link`, and inserts with `ON CONFLICT DO NOTHING`.
4. **Score.** Job (b) turns new `engagement_event` rows into `points_ledger` rows using the current `point_rule`. The ledger reference makes this safe to rerun.
5. **Own post.** Employee submits through Novera (`amplify_submit_post`, B2) or One WSO2 (B1) → `submission` PENDING → PO approves → ledger row. If WSO2 or a listed senior leader later reacts to it, the submission moves to `AMPLIFIED`, which pays the highest tier.
6. **Reward.** Job (d) is a no-op while `COINS_ENABLED=false`. When it's on, it sends `HELD` rows to Coin (B8) and stores `coin_reference`.
7. **Ask.** A Chat message goes to Novera → `amplify_ask` → amplify-agent `/query` (B2) → Haiku picks the topic (rules, FAQ, posts, my stats) → Postgres full-text search plus the user's own rows → Sonnet answers with citations (B4).
8. **Celebrate.** One WSO2 reads `/leaderboards`, `/me/history` and `/reports` (grouped by `org_dim` team/location and post). SLT sees reports through the `amplify-slt` group.

## Security and privacy

- **Verify the JWT signature in amplify-api.** Don't copy the decode-only interceptor from `people-ops-suite`. Verify one credential per deployment, the gateway assertion, as described in One WSO2 `projects/one-wso2/docs/ported-apps/event-platform.md` §6.
- Access tokens from One WSO2 carry no `email`. Key users on `sub` and resolve email once, or configure Asgardeo to add `email` to the access token.
- Capabilities come from `GET /me` (employee / content / admin / reports) based on the Asgardeo groups `amplify-content`, `amplify-admin` and `amplify-slt`. This follows One WSO2's gate-ladder convention.
- Data is minimised: Amplify stores only the person URN, action and timestamp for linked employees. Comment text isn't stored. Unlinking stops collection.
- LinkedIn and Anthropic keys are Choreo secrets. The LinkedIn refresh token is stored encrypted, AES-256-GCM, the same as Novera and Coin.

## Decisions made in this L2

| Decision | Why |
| --- | --- |
| The agent is its own service inside Amplify; Novera calls it as a tool | Agent Orchestrator is out of scope. This copies Novera's `releases.ts` "delegate to a domain backend" pattern and keeps the LLM key and quota out of the main API |
| Retrieval is Postgres full-text search, not Novera's whole-corpus prompt | Posts and history grow over time. pgvector can come later without changing anything at the boundary |
| Announcements go through Novera rather than a new Chat bot | Novera already owns the service account and is in the spaces. It needs one small change: a target `space` |
| Scheduled polling first, webhook later | Polling works with the mock before LinkedIn approval. The webhook (B10) cuts latency later, and the poll stays as a reconciliation backstop |
| Points held in our ledger, Coin call behind a flag | Coin's transfer API has no caller reference and no email → wallet lookup yet |

## Open items

| # | Item | Owner | Blocks |
| --- | --- | --- | --- |
| 1 | Prototype: can LinkedIn tell a plain repost from a repost with commentary, and who reposted? | Developer | `REPOST` / `REPOST_COMMENTARY` scoring tiers |
| 2 | **Points are only defined for reposts and own posts.** The requirements also track reactions and comments. Do those earn points? | PO | `point_rule` seed data |
| 3 | Coin changes: a caller `reference` + `source` on master/transfer, recipient by email (or a lookup), and what to do when the employee has no wallet yet | Nikeshala S. / Coin team | B8 go-live |
| 4 | Points → coin conversion rate | Business Team | B8 amount |
| 5 | Novera change: `space` target on `/internal/notifications`, plus the two Amplify tools | Visal R. | B2, B7 |
| 6 | Approval for Amplify to be its own One WSO2 app (new perspective and left-menu icon), and who reviews the upstream PR (`wso2-open-operations/one-wso2`) | One WSO2 owner | B1 UI |
| 7 | How to verify an employee's own-post submission is really theirs (can the API read member posts, or is it PO review only?) | Developer (prototype) | Flow 5 |
| 8 | Postgres and TypeScript differ from the team's usual MySQL/Ballerina. Confirm Choreo-managed Postgres is available in the target org | WSO2 Digital | Deployment L2 |
