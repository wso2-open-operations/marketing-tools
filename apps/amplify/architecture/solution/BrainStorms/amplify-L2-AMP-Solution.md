# NEW APPROACH - WSO2 AGENT MANAGER
# WSO2 Amplify — L2 Solution Architecture (AMP variant)

Builds on: [L0](../High%20Level/amplify-L0-solution.md) · [L1](../High%20Level/amplify-L1-solution.md) · [L2](amplify-L2-Choreo-Solution.md)
Inputs: the L2 design plus these changes: agents run in the WSO2 Agent Management Platform (AMP), every LLM call goes through the AMP LLM gateway, a classifier agent is added, LinkedIn pulls go through a queue service, and amplify-api posts Google Chat cards itself.

Boundary numbers B1–B11 keep their L2 meaning where they still apply. B12–B14 are new.

```text
              WSO2 AMPLIFY · L2 SOLUTION ARCHITECTURE (WITH AMP)
                ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐
PEOPLE          │      Employees     │    │    Marketing & PO  │    │       PO Admin     │    │         SLT        │
                │     830+, opt-in   │    │    register posts  │    │    points & fixes  │    │       reports      │
                └────────────────────┘    └────────────────────┘    └────────────────────┘    └────────────────────┘
                           │                         │                         │                         │
                           └──┬──────────────────────┴──────────────┬──────────┴─────────────────────────┘
                              │                                     │
                              ▼                                     ▼                          ┏━━ AMP · AGENT MANAGER  [AMP platform] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
              ┌────────────────────────────────┐    ┌────────────────────────────────┐         ┃  ┌───────────────────────────────────┐                                  ┃
              │ ONE WSO2  React app    [ADD]   │    │ GOOGLE CHAT        [EXISTING]  │         ┃  │ NOVERA  po-agent · TS   [UPDATE]  │                                  ┃
CHANNELS      │ Amplify app: own menu icon     │    │ Amplify space · user DMs       │◄────────┃─►│ tools: amplify_ask,               │                                  ┃
              │ leaderboards · points · admin  │    │ cards: announcements           │         ┃  │        amplify_submit_post        │                                  ┃
              │ preview flag · gate: GET /me   │    └─▲──────────────────────────────┘         ┃  │ calls amplify-agent in AMP        │                                  ┃
              │ Bearer Asgardeo access token   │      │                                        ┃  │ ThunderID token                   │                                  ┃
              └───────────────┬────────────────┘      │                                        ┃  └──────────────┬────────────────────┘                                  ┃
                              │ B1 REST/JSON          │                                        ┃                 │ B2 POST /query                                        ┃
                              │                       │ B7 Chat API: cards                     ┃                 │                                                       ┃
              ┏━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━┿ CHOREO PROJECT: wso2-amplify [NEW] ┓   ┃                 |                                                       ┃
              ┃  ┌────────────▼───────────────────┐   │                                    ┃   ┃  ┌──────────────▼─────────────────┐   ┌───────────────────────────────┐ ┃
              ┃  │ CHOREO API GATEWAY             │   │                                    ┃B14┃  │ AMPLIFY-AGENT  TS      [AMP]   │   │ AMPLIFY-CLASSIFIER TS  [AMP]  │ ┃
              ┃  │ apis.wso2.com · Asgardeo keys  ┤◄──┼────────────────────────────────────╂───╂──┤ POST /query · Novera tools     │   │ topic: rules·FAQ·posts·stats  │ ┃
              ┃  │ Bearer → x-jwt-assertion       │   │                                    ┃   ┃  │ 1 classify (classifier)        ├──►│ tag: own-post category        │ ┃
              ┃  └────────────┬───────────────────┘   │                                    ┃   ┃  │ 2 context via amplify-api      │   │ returns label + confidence    │ ┃
              ┃  ┌────────────▼───────────────────┐   │  ┌──────────────────────────────┐  ┃   ┃  │ 3 answer + cite (gateway)      │   │ small, fast model (gateway)   │ ┃
WSO2 AMPLIFY  ┃  │ AMPLIFY-API  TS · Express      │   │  │ QUEUE SERVICE         [NEW]  │  ┃   ┃  │ read-only · per-user quota     │   │ stateless · no tools          │ ┃
              ┃  │ REST · OpenAPI 3               ├───┘  │ broker: TBD (Choreo-hosted)  │  ┃   ┃  └───────────────┬────────────────┘   └───────────────┬───────────────┘ ┃
              ┃  │ /me /posts /submissions        │      │ linkedin-fetch   tasks       │  ┃   ┃                  │ B4                                 │ B4              ┃
              ┃  │ /profile/linkedin/link         │      │ engagement-in    events      │  ┃   ┃                  │                                    │                 ┃
              ┃  │ /leaderboards /me/history      │      │ retry · dead-letter · replay │  ┃   ┃  ┌───────────────▼────────────────────────────────────▼───────────────┐ ┃
              ┃  │ /reports /admin/* /agent/*     │      │ at-least-once · dedupe in DB │  ┃   ┃  │ AMP LLM GATEWAY  [AMP]                                             │ ┃
              ┃  │ verify assertion (JWKS)        │      └────────▲───────────┬─────────┘  ┃   ┃  │ one endpoint for every agent and service · model set in config     │ ┃
              ┃  │ groups → capabilities          │               │           │            ┃   ┃  │ provider keys · quotas · rate limits · guardrails · usage logs     │ ┃
              ┃  │ outbox → Google Chat cards     │       publish │    B12    │ consume    ┃   ┃  │ any configured LLM (not fixed by Amplify) · no LLM key in Amplify  │ ┃
              ┃  └────────────┬───────────────────┘               │           │            ┃   ┃  └──────────┬──────────────────────────────────────────────────────▲──┘ ┃
              ┃               │ B9 rw                    ┌────────┴───────────▼─────────┐  ┃   ┃             │ B13 validate                                         │    ┃
              ┃  ┌────────────▼───────────────────┐      │ AMPLIFY-JOBS  TS  4 tasks    │  ┃   ┃  ┌──────────▼─────────────────────┐                                │    ┃
              ┃  │ POSTGRES        Choreo DB      │      │ a sync   LinkedIn → queue    │  ┃   ┃  │ THUNDERID   AMP identity [AMP] │    All Amplify agents run in   │    ┃
              ┃  │ post · employee_link           │ B9   │          every 30 min        │  ┃   ┃  │ apps: Novera, Amplify Link     │    AMP: built, deployed,       │    ┃
              ┃  │ engagement_event  (uniq)       │◄────►│ b ingest + score  (consumer) │  ┃   ┃  │ LinkedIn federated login       │    traced and logged via       │    ┃
              ┃  │ submission · point_rule        │      │ d issue coins   daily [off]  │  ┃   ┃  │ B3 link: auth code + PKCE      │    Agent Manager.              │    ┃
              ┃  │ points_ledger  (uniq ref)      │      │ e team/location  daily       │  ┃   ┃  │ authenticates agents + callers │                                │    ┃
              ┃  │ coin_issue · outbox            │      │ shared lib · rerun-safe      │  ┃   ┃  │ issues agent tokens            │                                │    ┃
              ┃  │ audit_log · org_dim            │      └┬───────────────────────┬───┬─┘  ┃   ┃  │ B13 identity for B2, B4, B14   │                                │    ┃
              ┃  │ sync_cursor                    │       │                       │   │    ┃   ┃  └────────────────────────────────┘                                │    ┃
              ┃  └────────────────────────────────┘       │                       │   │    ┃   ┃                                                                    │    ┃
              ┃                                           │                       │   │    ┃   ┃                                                                    │    ┃
              ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━┿━━━┿━━━━┛   ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┿━━━━┛
                                                          │ B5                 B6 │   │                 B8                                                          │ B4
                                                          │                       │   └─────────────────────────────────────┐                                       │
              ┌────────────────────────────┐  ┌───────────▼───────────────────┐  ┌▼────────────────────────────┐ ┌──────────▼───────────────────┐  ┌────────────────┴────┐
SYSTEMS       │ ASGARDEO WSO2 prod [CONFIG]│  │ LINKEDIN REST API  [EXTERNAL] │  │ HR ENTITY GRAPHQL [EXISTING]│ │ WSO2 COIN          [DEPEND]  │  │ OTHER WSO2 SERVICES │
              │ apps: One WSO2             │  │ Community Management:         │  │ getEmployee(email)          │ │ transaction-service          │  │ also use the LLM    │
              │ groups: amplify-admin,     │  │ GET /reactions?q=entity       │  │ email → team, location      │ │ POST /wallets/master/transfer│  │ gateway (B4)        │
              │   amplify-content, -slt    │  │ GET /socialActions/{urn}/     │  └─────────────────────────────┘ │ ⚠ needs email→wallet +       │  │ no keys of their own│
              │ Choreo key manager         │  │      comments                 │                                  │   caller reference (ask)     │  └─────────────────────┘
              │ B11 sign-in + tokens for   │  │ ⚠ approval: mock in dev       │                                  │ client creds · org network   │
              │ channels, amplify, systems │  └───────────────────────────────┘                                  └──────────────────────────────┘
              └────────────────────────────┘
```

B# = boundary, see table   ⚠ tracked risk   [NEW]/[ADD]/[UPDATE]/[CONFIG] change type   [DEPEND] other-team system   [AMP] runs on or is provided by AMP
Lanes: PEOPLE (who) · CHANNELS (where they work) · WSO2 AMPLIFY (the Choreo project we build) · SYSTEMS (what it connects to). The AMP boundary reaches up into CHANNELS because Novera runs in AMP
Later (alignment addition): LinkedIn ORGANIZATION_SOCIAL_ACTION_NOTIFICATIONS webhook → amplify-api, persist and publish to the queue, 202 (B10)

## Components

| Component | Where | Stack | Responsibility |
| --- | --- | --- | --- |
| `amplify-api` | Choreo Service, public via `apis.wso2.com` | TypeScript, Express, Postgres | Posts, profile linking, submissions, leaderboards, history, reports, admin, plus `/agent/*` read endpoints for the agent. Writes outbox rows. Its announcement dispatcher claims outbox rows and sends Chat cards (B7). |
| `amplify-agent` | AMP Agent Manager | TypeScript | `POST /query`. Calls the classifier, pulls context from amplify-api, answers with citations through the gateway. Also handles the `amplify_submit_post` tool by calling `POST /submissions`. |
| `amplify-classifier` | AMP Agent Manager | TypeScript | Stateless, no tools. Returns `{label, confidence}` for chat questions (rules, FAQ, posts, my stats) and a category tag for own-post submissions to help the PO review queue. Uses a small, fast model chosen in the gateway. |
| AMP LLM gateway | AMP | Platform | One endpoint for every agent and service. Holds provider keys, routes by model alias (for example `amplify-classify`, `amplify-answer`), enforces quotas, rate limits and guardrails, logs usage. |
| ThunderID | AMP | Platform | Authenticates agents and callers on AMP and issues agent tokens. |
| Queue service | Choreo or platform-managed (broker TBD) | TBD | Two queues: `linkedin-fetch` (tasks) and `engagement-in` (events), each with retry, dead-letter and replay. |
| `amplify-jobs` | 4 Choreo components, one shared library | TypeScript | (a) sync: every 30 min, plans per-post fetch tasks, fetches from LinkedIn (B5), publishes engagement events. (b) ingest + score: queue consumer, inserts `engagement_event` and writes `points_ledger`. (d) issue coins, daily, flag off. (e) refresh team/location, daily. |
| Postgres | Choreo-managed | PostgreSQL | System of record, same tables as L2. |
| One WSO2 Amplify app | Existing web app (add) | React | Unchanged from L2. |
| Novera | Existing service (update), runs in AMP | TypeScript | Two new tools, `amplify_ask` and `amplify_submit_post`, that call `amplify-agent` in AMP. It no longer carries Amplify announcements. |

## Boundaries

Checklist key: **Auth** · **Corr** = correlation ID · **Idem** = idempotency · **Async** = persist-first.

| # | From → To | Call | Auth | Corr | Idem | Response / async |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | One WSO2 → amplify-api | Same as L2 | Asgardeo access token, gateway `x-jwt-assertion`, API verifies signature | `X-Correlation-ID` | `Idempotency-Key` on POSTs | 200/201, admin writes 202 |
| B2 | Novera → amplify-agent (both in AMP) | `POST /query` (ask and submit tools) | ThunderID token for Novera and the agent. **Open:** how the employee's identity rides along (see open item 1) | Novera turn ID as `X-Correlation-ID` | Submission key = `chat message name` | 200 answer, 202 submission |
| B3 | Browser ↔ ThunderID ↔ LinkedIn | OIDC auth code + PKCE, "Amplify Link" app and the LinkedIn federated connection both on ThunderID | ThunderID | `state` | Re-link replaces | amplify-api callback stores `urn:li:person:{id}`, consent time, scope |
| B4 | amplify-agent, amplify-classifier, other WSO2 services → AMP LLM gateway | Gateway's model API with a model alias, not a vendor model name | ThunderID agent token | Run ID passed as metadata | n/a (reads) | Timeout 30s. Per-user quota enforced in the gateway, user ID sent as metadata |
| B5 | amplify-jobs (sync) → LinkedIn | Same as L2: `/reactions?q=entity`, `/socialActions/{urn}/comments` | Org-admin 3-legged OAuth token | Per run + per post | `sync_cursor`; `UNIQUE(post_urn, actor_urn, action)` | Fetch workers draw from the `linkedin-fetch` queue, so queue concurrency caps the LinkedIn rate. Backoff on 429/5xx. Mock in dev |
| B6 | amplify-jobs → HR Entity GraphQL | Same as L2 | OAuth2 client credentials | Per run | Upsert by email | Daily refresh |
| B7 | amplify-api → Google Chat API | `spaces.messages.create` with a Cards v2 payload | Chat app credential. **Open:** Novera's Chat app or a new Amplify Chat app | Announcement ID | Client message ID = `announcement_outbox.id` | Outbox retries ×5, then `failed` → admin screen. `post` and outbox row are written in one transaction |
| B8 | amplify-jobs → WSO2 Coin | Same as L2, placeholder contract, feature flag off | Client credentials | Ledger reference | `reference` = ledger ref | 201 / 200 replay / 409 |
| B9 | amplify-api, amplify-jobs → Postgres | TLS SQL | Separate DB user per component | — | Unique constraints are the dedupe boundary | **The agents have no DB access** |
| B10 | LinkedIn → amplify-api *(later)* | `ORGANIZATION_SOCIAL_ACTION_NOTIFICATIONS` webhook | LinkedIn signature check | Event ID | Same unique key as B5 | Verify, publish to `engagement-in`, return 202. B5 stays as the reconciling backstop |
| B11 | Channels, Amplify and systems → Asgardeo | OIDC sign-in and token issuance for One WSO2, Choreo key manager at the gateway, client credentials for HR Entity and Coin | Asgardeo (WSO2 production) | `state` | Short-lived tokens, nothing to dedupe | Standard OIDC |
| B12 | amplify-jobs ↔ queue service | Publish `fetch` tasks and `engagement` events. Consume engagement events | Service credential from the queue | Run ID and post URN in message headers | Message ID = hash(post, actor, action). Redelivery is harmless because the DB unique key drops duplicates | At-least-once. Failed messages retry, then go to the dead-letter queue. Replay is a deliberate admin action |
| B13 | AMP LLM gateway, agents, Novera ↔ ThunderID | Token validation, agent token issuance, Novera and Amplify Link sign-in, LinkedIn federation | ThunderID | Request ID | Tokens are short-lived | Standard OIDC |
| B14 | amplify-agent → amplify-api | `GET /agent/search`, `GET /me/history`, `POST /submissions` via the Choreo gateway | User context (see B2 open item) plus the agent's own ThunderID identity | Same correlation ID as B2 | `Idempotency-Key` on POSTs | 200 / 202. API enforces per-user access, so the agent can't see other people's rows |

**Single writer and reader:** amplify-api and amplify-jobs are the only components that touch the Amplify DB. Coin balances are written only by the Coin transaction-service (B8). Novera, One WSO2 and the AMP agents never touch the DB directly.

## Data model (Postgres)

Same tables as [L2](amplify-L2-Choreo-Solution.md#data-model-postgres). Changes:

- `announcement_outbox` is now claimed by the amplify-api dispatcher, not a job.
- `engagement_event` is written by the ingest consumer (job b), not the sync job.
- No new tables. Queue state lives in the queue service, and LLM usage lives in the gateway logs.

## Key flows

1. **Publish.** Marketing/PO `POST /posts`. amplify-api writes `post` and `announcement_outbox` in one transaction and returns 201. The dispatcher sends a Cards v2 message to the Amplify space through the Google Chat API (B7).
2. **Link.** Same as L2 (B3).
3. **Track.** Job (a) runs every 30 min. It plans one `fetch` task per post where `now() < track_until`. Workers pull from LinkedIn (B5) and publish `engagement` events (B12). They don't touch the DB.
4. **Ingest and score.** Job (b) consumes `engagement` events, drops actors that don't match `employee_link`, inserts with `ON CONFLICT DO NOTHING` and writes `points_ledger` rows with the current `point_rule`. The ledger reference makes redelivery safe.
5. **Own post.** Employee submits through Novera (B2) or One WSO2 (B1). The classifier tags the submission, it goes to `PENDING`, the PO approves and a ledger row is written. If WSO2 or a listed senior leader later reacts to it, it moves to `AMPLIFIED` and pays the top tier.
6. **Reward.** Same as L2 (B8, flag off).
7. **Ask.** Chat message → Novera → `amplify-agent` in AMP (B2). The agent calls `amplify-classifier`, which asks the gateway for a label (B4). The agent pulls context from amplify-api (B14), then asks the gateway for a cited answer (B4).
8. **Celebrate.** Same as L2.

## Security and privacy

- Everything in L2's security section still applies, including verifying the JWT signature in amplify-api.
- **No LLM keys in Amplify.** Provider keys live only in the AMP gateway. Swapping or adding a model is a gateway config change.
- Agents run with their own ThunderID identity and can reach only the gateway (B4) and amplify-api (B14). They have no DB credentials.
- Only the question and the context amplify-api returns for that user go to the gateway. Comment text is never stored or sent.
- Chat card payloads carry titles and links only, with no personal data.
- Dead-letter messages hold LinkedIn actor URNs. Treat the queue with the same access rules as the DB.

## Decisions made in this variant

| Decision | Why |
| --- | --- |
| All agents run in AMP | One place to build, deploy, trace and log agents, and agents share the gateway and identity |
| Classifier is its agent | Keeps the cheap, fast classification model separate from the answer model, and lets other WSO2 services reuse it later. Connect using A2A protocal or MCP Service. |
| Agent reads through amplify-api instead of Postgres | AMP and Choreo are separate platforms. A DB credential outside Choreo widens exposure, and the API already enforces per-user access |
| Queue between LinkedIn and the DB | Queue concurrency sets the LinkedIn rate. Failures retry per post instead of rerunning a whole sync, and the later webhook feeds the same queue |
| amplify-api sends Chat cards directly | Cards belong to the content workflow and use the outbox that already exists. Novera stays focused on conversation |
| Model named by alias in the gateway | Amplify never names a vendor, so a gateway change swaps providers |

## Open items

| # | Item | Owner | Blocks |
| --- | --- | --- | --- |
| 1 | Identity bridge between ThunderID (Novera, Amplify Link, agents) and Asgardeo (One WSO2, Choreo gateway). amplify-api must resolve one employee from either token, and `employee_link` is keyed on `asgardeo_sub` today. Likely key on email or add a ThunderID `sub` | Developer with the AMP team | B2, B3, B14 |
| 2 | Which queue service and broker, and whether it is Choreo-hosted or platform-managed | WSO2 Digital | B12, jobs (a) and (b) |
| 3 | Which Google Chat app posts the cards (Novera's or a new Amplify app), and whether card buttons need a callback into amplify-api | Visal R. | B7 |
| 4 | Gateway model aliases, quotas and per-user metadata. Which models back `amplify-classify` and `amplify-answer` | AMP team | B4 |
| 5 | Classifier scope: confirm it tags own-post submissions as well as routing chat questions | PO | Flow 5 |
| 6 | Whether other WSO2 services call the classifier or only the gateway | AMP team | B4 sizing |
| 7 | Everything still open in L2 (repost detection, point values, Coin changes, One WSO2 app approval, Postgres availability) | See L2 | See L2 |
