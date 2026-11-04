# amplify_domain

Bounded contexts shared by `amplify-api` and `amplify-jobs` (ADR-021): per context, the pure domain model
(`types.bal`, `service.bal`, `events.bal`), its repository port, and the PostgreSQL repository
(`repository.bal`). Plus `store`: client, outbox and audit writers, SQL error mapping, partition upkeep call.

Depends on `amplify_common` (publish that first). Publish to the local repository before building a consumer:

```sh
bal pack && bal push --repository=local
```

Integration tests (group `integration`) need a migrated PostgreSQL 17; see `docs/migrations/README.md`.

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
            ┃  │ Novera post cards       │  │ 3 leaderboards · my points   │                                     ┃
            ┃  │ notifier in jobs        │  │ PO dashboard                 │                                     ┃
            ┃  └────────────┬────────────┘  └──────────────────────────────┘                                     ┃
            ┗━━━━━━━━━━━━━━━┿━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
                            │ ACL: Novera client                S2 and C1 ──► LinkedIn (ACL: OAuth/OIDC, provider adapter)
            ┌───────────────▼──────────┐                         ┌──────────────────────────────────────────────┐
EXTERNAL    │ NOVERA        [EXTERNAL] │                         │ LINKEDIN                          [EXTERNAL] │
            │ Google Chat assistant    │                         │ Sign In with LinkedIn (OIDC: sub → person)   │
            │ POST                     │                         │ Share on LinkedIn: POST /rest/posts          │
            │ /internal/notifications  │                         │ self-serve · w_member_social · no approval   │
            └──────────────────────────┘                         └──────────────────────────────────────────────┘

            ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
LATER         Engagement Tracking (Community Mgmt API) · Rewards (Coin issuer) · Org data (HR Entity)
            │ Agent (Novera, classifier, LLM gateway, AMP, ThunderID) · queue service · other platforms           │
            └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘

C = core subdomain   S = supporting subdomain   OHS/PL = open host service + published language   ACL = anti-corruption layer
```

### Contexts and where they live

All contexts share one database schema. Table and view names carry the context as a prefix, `<context>_<name>` (ADR-043); the configured schema comes from `store:DbConfig.schema`. The tables a module owns are listed in its README.

| Context | Type | Module here | Table prefix | What it owns |
| --- | --- | --- | --- | --- |
| C1 Sharing | Core | [`sharing`](modules/sharing/README.md) | `sharing_` | `ShareRequest` (one per campaign per employee, retry reuses the row), `Engagement` (verified facts), the provider adapter port |
| C2 Scoring & Points Ledger | Core | [`scoring`](modules/scoring/README.md) | `scoring_` | `PointRule` (versioned tiers), the append-only `PointsLedger` (once per action per post per person), allocations and adjustments |
| S1 Campaign | Supporting | [`campaign`](modules/campaign/README.md) | `campaign` | Registry of official WSO2 posts: category, priority, active window, derived status |
| S2 LinkedIn Connection | Supporting | [`connection`](modules/connection/README.md) | `connection_` | OAuth consent, the encrypted token vault (daily partitions), 60-day expiry, remove connection |
| S3 External Sharing | Supporting | [`external_sharing`](modules/external_sharing/README.md) | `external_sharing_` | Evidence-URL claims for actions outside Amplify, PO review |
| S4 Recognition | Supporting | [`recognition`](modules/recognition/README.md) | `recognition_` | Pre-built leaderboard, team, my-points and PO dashboard tables, rebuildable from the ledger |
| S5 Announcements | Supporting | [`announcements`](modules/announcements/README.md) | `announcement` | The Novera announcement for a campaign, sent at most once unless an admin resends (ADR-047; `attempted_at` marker, V022) |
| Shared | | [`identity`](modules/identity/README.md), [`store`](modules/store/README.md) | `identity_`, `messaging_`, `audit_`, `config_` | Employee directory snapshot; the client, outbox and audit writers, SQL error mapping, partition upkeep |
| Read only | | [`reporting`](modules/reporting/README.md) | none | Dashboard aggregates (ADR-036). Reads other contexts' views, writes nothing |

A context writes only its own tables (no cross-context foreign keys, ADR-005). One exception by design: the ledger append (`PgLedgerRepository.append` in `scoring`) applies the row to the `recognition` tables in the same transaction (B12). A few queries read another context's tables or views read-only: `campaign` (`hasActivity` before a post id change), `reporting` (all dashboards), `recognition` (the ledger and `identity_employee`), `sharing` (`messaging_outbox`). Contexts talk through events in the outbox: `CampaignRegistered`, `RepostRequested`, `EngagementRecorded`, `ConnectionReady` / `ConnectionRevoked`, `ExternalShareApproved`, and the `Points*` family. The full event catalogue is in [phase1-data-model](../architecture/solution/Phase%201/phase1-data-model.md). Which deployable runs which context is in the domain doc's "Mapping to the phase 1 deployables" table.

## Module layout

Each context module has the same files where they apply:

| File | Holds |
| --- | --- |
| `types.bal` | Aggregate records, the derived-status enum, the repository port |
| `service.bal` | Pure rules and use cases that take a port |
| `events.bal` | Outbox event builders (wrap `amplify_common.events`) |
| `repository.bal` | `Pg...Repository` classes over `postgresql:Client` |
| `queries.bal` | Read-only page and dashboard queries (some modules) |
| `<module>.bal` | `MODULE` constant for log context |

Exceptions: `identity` has no `events.bal`; `reporting` has only `snapshot.bal` and `queries.bal`; `recognition` has no repository port and exposes plain functions; `store` is plumbing.

## Config

The package declares these `configurable` values. Values come from the consuming component's `Config.toml`.

| Name | Module | Default |
| --- | --- | --- |
| `oauthStateTtlSeconds` | `connection` | 600 |
| `dashboardCampaignWindowDays` | `reporting` | 90 |
| `dashboardCampaignLimit` | `reporting` | 200 |
| `dashboardMonthlyMonths` | `reporting` | 6 |
| `dashboardCardsWindowDays` | `reporting` | 30 |

Database settings are the `store:DbConfig` record, filled by each component.

## Tests

- `bal test` runs the module unit tests (`modules/<m>/tests/`, in-memory repositories) and the package `tests/lock_order_test.bal`.
- The `integration` group (`tests/integration_*.bal`) needs `AMPLIFY_IT=true` and a migrated PostgreSQL; see `docs/migrations/README.md`.

Details for agents are in [CLAUDE.md](CLAUDE.md).
