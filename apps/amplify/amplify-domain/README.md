# amplify_domain

Bounded contexts shared by `amplify-api` and `amplify-jobs` (ADR-021): per context, the pure domain model
(`types.bal`, `service.bal`, `events.bal`), its repository port, and the PostgreSQL repository
(`repository.bal`). Plus `store`: client, outbox and audit writers, SQL error mapping, partition upkeep call.

Depends on `amplify_common` (publish that first). Publish to the local repository before building a consumer:

```sh
bal pack && bal push --repository=local
```

Integration tests (group `integration`) need a migrated PostgreSQL 18; see `docs/migrations/README.md`.

## Domain map

One module per bounded context under `modules/`. The context map below is copied from the [Phase 1 domain model](../architecture/solution/Phase%201/phase1-domains.md) (the source of truth; refresh this copy when it changes). `C` = core subdomain, `S` = supporting, `OHS/PL` = open host service + published language, `ACL` = anti-corruption layer.

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

### Contexts and where they live

| Context | Type | Module here | Postgres schema | What it owns |
| --- | --- | --- | --- | --- |
| C1 Sharing | Core | `sharing` | `sharing` | `ShareRequest` (one per campaign per employee, retry reuses the row), `Engagement` (verified facts), the provider adapter port |
| C2 Scoring & Points Ledger | Core | `scoring` | `scoring` | `PointRule` (versioned tiers), the append-only `PointsLedger` (once per action per post per person), allocations and adjustments |
| S1 Campaign | Supporting | `campaign` | `campaign` | Registry of official WSO2 posts: category, priority, active window, derived status |
| S2 LinkedIn Connection | Supporting | `connection` | `connection` | OAuth consent, the encrypted token vault (daily partitions), 60-day expiry, remove connection |
| S3 External Sharing | Supporting | `external_sharing` | `external_sharing` | Evidence-URL claims for actions outside Amplify, PO review |
| S4 Recognition | Supporting | `recognition` | `recognition` | Pre-built leaderboard, team, my-points and PO dashboard tables, rebuildable from the ledger |
| S5 Announcements | Supporting | `announcements` | `announcement` | The Club chat card for a campaign, sent once |
| Shared | | `identity`, `store` | `identity`, `messaging`, `audit`, `config` | Employee directory snapshot; the client, outbox and audit writers, SQL error mapping, partition upkeep |

A context reads and writes only its own schema (no cross-context foreign keys, ADR-005). Contexts talk through events in the outbox: `CampaignRegistered`, `RepostRequested`, `EngagementRecorded`, `ConnectionReady` / `ConnectionRevoked`, `ExternalShareApproved`, and the `Points*` family. The full event catalogue is in [phase1-data-model](../architecture/solution/Phase%201/phase1-data-model.md). Which deployable runs which context is in the domain doc's "Mapping to the phase 1 deployables" table.

