# WSO2 Amplify — Phase 1 Requirements Traceability Matrix

Status: Draft v1 (2026-10-17)
Source of truth audited: [requirements-map.md](requirements-map.md) (map v2, mitigations agreed 2026-10-16)
Decision register: [architecture/decisions/README.md](../../decisions/README.md) (ADR-001 … ADR-031)
Plan: [phase1-planned-todos.md](../../../docs/requirements/phase1-planned-todos.md) (M0–M12)
Data model: [phase1-data-model.md](phase1-data-model.md) · Domains: [phase1-domains.md](phase1-domains.md)

This matrix takes **every requirement and decision row** in `requirements-map.md` — the requirement IDs (R/T/K/P/Q), every audit finding (**A#**, **B#**, **C#**, **D#**), the **Open items**, the **Other phases** table, and the plan/domains **D-number** decisions — and records:

- **Disposition** — what actually shipped (see legend),
- the **plan milestone** covering it,
- the **ADR** that records the decision,
- the **code path, test or document** that proves it.

Where no artefact exists yet, the row says **no artefact yet** — nothing here is invented. Every path cited was verified to exist in this tree (the One WSO2 UI lives in a submodule that is not initialised in this worktree, so M7 UI rows carry no code pointer).

## Disposition legend

| Value | Meaning |
| --- | --- |
| **Implemented** | Built in M0–M11 and proven by the cited artefact. |
| **Partial** | Part ships in phase 1; the remainder is deferred (stated in the row). |
| **Deferred** | Out of phase 1 by an explicit decision. |
| **Console-blocked** | Code/design done; the remaining step needs a Choreo / Asgardeo / GitHub / LinkedIn console action, or a PO / Legal / Security approval. Owner named in the row. |
| **No artefact yet** | An open build item in the plan with nothing in the tree yet. |
| **Docs applied** | The mitigation is a document/process change that has been applied (no code). |

## 1 · Requirements

| ID | Requirement | Disposition | Milestone | ADR | Evidence (code / test / doc) |
| --- | --- | --- | --- | --- | --- |
| R1 | Register official WSO2 LinkedIn posts (category, priority) | Implemented (API); M7 UI open | M5 S1, M7 | ADR-012 (A6) | `amplify-api/handlers.bal` (POST `/campaigns`), `amplify-database/migrations/V002__identity_campaign.sql`; `amplify-domain/tests/integration_m5_test.bal` `testM5RegisterListAndShare` |
| R2 | Share new posts to the Amplify Chat space automatically | Implemented (code); real webhook open | M6a | — (ADR-025 delivery) | `amplify-jobs/handlers.bal` (CampaignRegistered → Chat), `amplify-common/modules/googlechat/card.bal`; `amplify-jobs/tests/webhook_test.bal`; V011 chat thread columns |
| R3 | Link LinkedIn to the WSO2 account via SSO | Implemented (direct OAuth; A8 research open) | M5 S2, M7 | — (A8 research) | `amplify-api/handlers.bal` (`connections/linkedin/complete`), `amplify-domain/modules/connection/service.bal`; `amplify-common/modules/crypto/tests/token_cipher_test.bal`; `amplify-domain/tests/integration_m5_test.bal` `testM5OAuthStateIsSingleUseAndOwned` |
| R4 | Record who reacted/commented/reposted (or reposted with commentary) | Partial — in-app reposts only; reactions, comments, native reposts deferred | M6, ADR-018 | ADR-018 | `amplify-jobs/handlers.bal` (RepostRequested → `sharing.engagement`), V004 `engagement` table; `amplify-jobs/tests/integration_test.bal` `testM6RunAnnouncesSharesAndScores` |
| R5 | Let employees submit their own WSO2 posts for higher-tier points | Implemented (API); M7 UI open | M5 S3, M7 | ADR-017 | `amplify-api/handlers.bal` (`POST /external-shares`), `amplify-database/migrations/V005__external_sharing.sql`; `amplify-api/tests/endpoint_test.bal` `testExternalShareApproveAndAmplifyAwardPoints` |
| R6 | Apply points automatically, once per action per post per person | Implemented as deviation (one repost per campaign); PO sign-off open | M5 C1–C2, M6 | ADR-015 (C2) | `amplify-database/migrations/V004__sharing.sql` `UNIQUE (campaign_id, employee_id)`; V006 ledger PK + `ON CONFLICT`; `amplify-jobs/tests/integration_test.bal` rerun-safety test |
| R7 | PO edits point values, corrects records, removes invalid activity | Implemented | M5 C2 | ADR-011 (A5) | `amplify-api/handlers.bal` (`po/point-rules`, `po/points/adjustments`, `po/points/{reference}/reverse`); `amplify-domain/tests/integration_m5_test.bal` `testM5AdjustReverseUpdatesStanding` |
| R8 | Convert points into WSO2 Coins | Deferred (phase 2) | — | ADR-029 (settlement columns) | V006 `points_ledger_no_paid_phase1_ck` blocks `PAID`; V006 `coin_reference` column reserved for phase 2 |
| R9 | Show each employee their points, Coins and history | Partial — points only, no Coin value | M5 S4, M7 | — (A11) | `amplify-api/reads.bal` (`GET /me/points`), `amplify-api/handlers.bal`; `amplify-api/tests/endpoint_test.bal` `testEmployeeListsAndSharesWithStableCodes` |
| R10 | Individual and team leaderboards | Partial — three views built; My Team build depends on the D13 roster endpoint | M7, M0c | ADR-014, ADR-019 | `amplify-api/reads.bal` (`GET /leaderboard`, `GET /team`); [leaderboards.md](leaderboards.md); `amplify-domain/tests/integration_m5_test.bal` `testM5DashboardQueriesRun`; roster endpoint pending (D13) |
| R11 | Report participation, reach and points by team/location/post | Partial — PO dashboard ships; SLT reports + reach deferred | M0b, M0c, MVP #4 | ADR-013 (B6) | `amplify-api/reads.bal` (`GET /po/dashboard`); [po-dashboard.md](po-dashboard.md); `amplify-domain/tests/integration_m5_test.bal` `testM5DashboardQueriesRun` |
| T1 | Tier: repost/share of WSO2 content = lowest | Done — `REPOST` ships (D5 passed 2026-10-20, [ADR-034](../../decisions/ADR-034-share-is-a-repost.md)); `SHARE` stays as the fallback kind | M5 C1 | — (B4) | V006 `point_rule` action enum incl. `SHARE`, `SHARE_COMMENTARY`; seed S001 |
| T2 | Tier: repost/share with commentary = mid | Implemented | M5 C1 | — | V006 `REPOST_COMMENTARY`; seed `S001__point_rules.sql` |
| T3 | Tier: original employee post with meaningful WSO2 content = higher | Implemented | M5 S3 | — | V005 `external_share`, V006 `OWN_POST`; seed S001; `testExternalShareApproveAndAmplifyAwardPoints` |
| T4 | Tier: original content amplified by WSO2/senior leader = highest | Implemented (with C4 top-up) | M5 S3 | — (C4) | `amplify-api/handlers.bal` (`po/external-shares/{id}/amplified`), `amplify-domain/modules/scoring/service.bal` `amplifiedTopUp`; V005 `CHECK`; `amplify-domain/tests/integration_test.bal` `testExternalShareOneClaimPerUrlAndAmplifiedCheck` |
| K1 | Scale: 830+ employees, 10–30 posts/month | Implemented locally; Choreo load run open | M11 | — | V007 `recognition.standing`, V010 `apply_ledger_entry`/`rerank`; [load-test-2026-10.md](../../../docs/testing/load-test-2026-10.md); `scripts/load-test.sh` |
| K2 | Authentication: WSO2 SSO | Implemented; Asgardeo console steps open | M4 | ADR-022, ADR-023 | `amplify-api/interceptors.bal`, `amplify-api/modules/auth/token.bal`; `amplify-api/tests/auth_test.bal`; console: [identity-setup runbook](../../../docs/runbooks/identity-setup.md) |
| K3 | Data privacy: opt-in linking, capture only needed metrics | Console-blocked — Legal consent copy pending (A9) | M10, M0c | — (A9) | `amplify-domain/modules/connection/service.bal` `sealToken`; `amplify-common/modules/crypto/token_cipher_test.bal`; consent copy placeholder in plan M0c A9 |
| K4 | Governance: duplicate prevention, complete audit logging | Implemented | M2, M3 | ADR-029 (C1), ADR-005, ADR-017 | V006 ledger PK/unique keys, V008 `audit_log` (monthly partitions, 5 y); `amplify-domain/tests/integration_test.bal` `testFailedWriteRollsBackAggregateOutboxAndAudit` |
| P1 | Pilot launches 15 Oct 2026 (moved to 31 Oct 2026) | Partial — date set, dated milestones added; effort estimate open (Q6) | M0c | — (A1) | plan [Dated milestones](../../../docs/requirements/phase1-planned-todos.md#dated-milestones-to-go-live-31-oct-2026) |
| P2 | 15–25 Amplify Champions kick-start the pilot | Console-blocked — Asgardeo pilot group not created | M12 | — | no artefact yet (M12; Asgardeo pilot group + One WSO2 preview flag both open) |
| P3 | Design for additional social channels later (LinkedIn first) | Implemented | M2, M3 | ADR-005 | V002 `provider`/`resource_urn`; `amplify-common/modules/linkedin/adapter.bal` (`ProviderAdapter` port) |
| P4 | Match EveryoneSocial's Google Chat integration (two-way) | Partial — posts in Chat; two-way deferred | M6a | — (A12) | `amplify-common/modules/googlechat/client.bal` (one-way webhook); two-way deferred (open items) |
| P5 | Offer AI help for employees writing their own posts | Deferred (Novera, future phase) | — | — (A12) | no artefact yet |
| Q1 | Engagement data: which actions can Amplify see? | Answered — in-app reposts only (`w_member_social`) | M0b | ADR-018 | [research 2026-10-16](../../../docs/research/2026-10-16-linkedin-deletion-and-analytics.md) |
| Q2 | Plain vs commentary reposts | Answered — employee picks the kind; native reposts later | M5 C1 | — | V006 enum `REPOST`/`REPOST_COMMENTARY` |
| Q3 | Google Chat integration | Answered — one-way webhook to WSO2 Club Group | M6a | — (A7) | `amplify-jobs/handlers.bal`; [google-chat-webhook runbook](../../../docs/runbooks/google-chat-webhook.md) |
| Q4 | AI help | Deferred (future phase) | — | — (A12) | no artefact yet |
| Q5 | Coins connection | Deferred — held in ledger; Coin contract open | — | ADR-029 | V006 settlement columns; L2 open items 3–4 |
| Q6 | Effort and earliest go-live | Answered (date) — 31 Oct 2026; effort estimate open | M0c | — (A1) | plan [Dated milestones](../../../docs/requirements/phase1-planned-todos.md#dated-milestones-to-go-live-31-oct-2026) |

## 2 · Audit A — requirements gaps

| # | Sev | Finding (mitigation) | Disposition | Milestone | ADR | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| A1 | High | Launch date not addressed → go-live 31 Oct 2026 | Docs applied | M0c | — | plan dated milestones |
| A2 | High | Must vs should not marked | Console-blocked — PO to tag R1–R11 | M0c | — | no artefact yet (owner: PO) |
| A3 | High | Native LinkedIn reposts have no path | Deferred (future phase) | M0c | ADR-018 | plan MVP item 3; requirements-map A3 |
| A4 | Medium | One repost per campaign is stricter than "once per action" | Deferred — revisit with Community Management | M0b | ADR-015 (C2) | V004 `UNIQUE (campaign_id, employee_id)` |
| A5 | High | PO can't edit point values → point rules move to `amplify_po` | Implemented | M5 C2, M7 | ADR-011 | `amplify-api/modules/auth/matrix.bal` (`po/point-rules` writes) |
| A6 | Medium | PO can't register posts → `amplify_po` on campaign endpoints | Implemented | M5 S1, M7 | ADR-012 | `amplify-api/modules/auth/matrix.bal`; plan Roles table |
| A7 | Medium | Which Chat space → WSO2 Club Group | Console-blocked — webhook secret to create | M6a | — | [google-chat-webhook runbook](../../../docs/runbooks/google-chat-webhook.md) |
| A8 | Low | Connect isn't Asgardeo federation → keep direct OAuth, research | Console-blocked — research open | M0c | — | no ADR yet (owner: research; plan M0c A8) |
| A9 | Medium | Privacy scope grew (token can post as the employee) | Console-blocked — Legal consent copy pending | M10, M0c | — | consent copy placeholder in plan M0c A9; owner: Legal |
| A10 | Medium | No team leaderboard → My Team view added | Implemented (design; build depends D13) | M5 S4, M7 | ADR-019 | [leaderboards.md](leaderboards.md) |
| A11 | Medium | "Coins shown as held" has no rule → points only in phase 1 | Implemented (decision) | M5 S4 | — | plan M5 S4 / MVP item 5; V006 blocks `PAID` |
| A12 | Low | Chat two-way and AI help not matched | Deferred (future phase) | — | — | requirements-map A12 |
| A13 | Low | "Reach" may not be reachable | Deferred (future phase) | — | ADR-018 | [research 2026-10-16](../../../docs/research/2026-10-16-linkedin-deletion-and-analytics.md) |

## 3 · Audit B — document contradictions

| # | Sev | Finding (mitigation) | Disposition | Milestone | ADR | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | High | Decision IDs collide → one ADR register, cite `ADR-NNN` | Docs applied | M0c | — | [decisions/README.md](../../decisions/README.md) index + D-number map |
| B2 | Medium | Campaign states differ → use derived states | Docs applied | M3 | ADR-005 | V002 `campaign.campaign_v`; data model |
| B3 | Medium | ShareRequest key differs → `(campaign, employee)` for phase 1 | Implemented | M3 | ADR-015 | V004 `UNIQUE (campaign_id, employee_id)` |
| B4 | Medium | `SHARE` kind has no home → add to enums | Implemented | M3 | — | V004/V006 action enums incl. `SHARE`, `SHARE_COMMENTARY` |
| B5 | Medium | Comments and reactions: in or out → out of phase 1 | Deferred (ADR-018) | M0c | ADR-018 | plan D6; requirements-map B5 |
| B6 | Medium | PO dashboard: phase 1 or 2 → stays in phase 1, defined | Implemented | M0c, M5 S4 | ADR-013 | [po-dashboard.md](po-dashboard.md); `amplify-api/reads.bal` |
| B7 | Low | SLT report in phase 1 tests → removed | Docs applied | M11 | — | plan M11 E2E (SLT reports phase 2) |
| B8 | Medium | Announcement event wiring differs → consume `CampaignRegistered` | Implemented | M2, M6a | — | `amplify-jobs/handlers.bal` CampaignRegistered; `amplify-common/modules/events` |
| B9 | Medium | Event catalogue drift → one catalogue in the data model | Docs applied | M2 | — | [phase1-data-model.md](phase1-data-model.md) domain-events table; `amplify-common/modules/events` |
| B10 | Medium | Maintenance endpoint differs → one `/maintenance/partitions` | Implemented | M3, M6 | ADR-025 | V009 functions; `amplify-jobs/service.bal` POST `/maintenance/partitions`; `amplify-domain/tests/integration_test.bal` `testPartitionMaintenanceAsJobs` |
| B11 | High | Two token-drop rules → `max(expires_at) + grace` only | Implemented | M3 | ADR-002 | V009; `amplify-database/tests/integration_test.bal` `testTokenDayDropRuleAndAudit` |
| B12 | High | API can't update recognition but writes ledger → grant `amplify_api` write | Implemented | M3 | ADR-021, ADR-005 | V001 grant, V010 `apply_ledger_entry`; `amplify-domain/tests/integration_test.bal` `testLedgerAppendUpdatesRecognitionInOneTransaction` |
| B13 | Low | `person_urn` vs `member_urn` → `member_urn` everywhere | Implemented | M3 | — | V003 `member_urn`; `amplify-common/modules/types` |
| B14 | Low | Connection/share states differ → use derived states | Implemented | M3 | — | V003 `member_connection_v`, V004 `share_request_v` |
| B15 | Medium | "No full list" vs the Team page → three leaderboards | Implemented (My Team build depends D13) | M0c, M7 | ADR-014, ADR-019 | [leaderboards.md](leaderboards.md); `amplify-api/reads.bal` |
| B16 | Low | Leaderboard size fixed or configurable → configurable top N default 3 | Implemented | M3, M5 | ADR-014 | V007 `points_to_top_n`; seed `leaderboard.top_n = 3` |
| B17 | Low | Audit retention open → closed at 5 years | Implemented | M3 | ADR-002 | seed `audit.retention_months = 60`; V009 audit drop |
| B18 | Medium | Postgres extensions not checked → add `citext`/`pg_trgm` to D2 + portability rule | Console-blocked — Choreo/Aiven check pending | M0 D2, M3 | ADR-002 | V001 `CREATE EXTENSION citext, pg_trgm`; `amplify-database/checks/d2_extensions.sql`; run on a real Choreo DB still open |
| B19 | Low | Code layout vs ownership | Implemented — resolved by a shared `amplify_domain` | M2, M3 | ADR-021, ADR-031 | `amplify-domain/modules/`; `amplify-api/modules/` = auth/scheduler/utils only; `amplify-jobs/handlers.bal` imports `amplify_domain.*` |
| B20 | Low | Evidence URL rule → "host blocklist"; drop "URL hosts" from M5 | Docs applied | M5, M10 | — | M2/M10 URL rules; `amplify-common/modules/types/evidence_url.bal`; `amplify-common/modules/types/tests/evidence_url_test.bal` |
| B21 | Low | Deployables count → one phrase everywhere | Docs applied | M0c | ADR-007 | plan architecture-at-a-glance (one cell, six components) |

## 4 · Audit C — design defects

| # | Sev | Finding (mitigation) | Disposition | Milestone | ADR | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | High | Ledger reference too long (68 > 66) → deterministic base64url, 47 chars | Implemented | M2, M3 | **ADR-029** | `amplify-common/modules/types/ledger.bal`; `amplify-common/modules/types/tests/ledger_test.bal` `awardReferenceIsDeterministicAnd47Chars`; V006 `varchar(66)` |
| C2 | High | Failed share locks the employee out → retry reuses the row | Implemented | M2, M3 | ADR-015 | `amplify-domain/modules/sharing/service.bal` `retryShare`; `amplify-domain/tests/integration_test.bal` `testShareRequestRetryAndPublishByJobs` |
| C3 | High | Erasure can't anonymize the ledger → deferred + checklist exception | Deferred; **console-blocked** — security team approval pending | M10, M0c | ADR-016 | checklist-exception-data-deletion.md; [data-deletion-interim runbook](../../../docs/runbooks/data-deletion-interim.md) |
| C4 | Medium | AMPLIFIED under-specified → `CHECK` + top-up row | Implemented | M2, M3 | ADR-029 (append-only) | V005 `CHECK (amplified_at IS NULL OR decision = 'APPROVED')`; `scoring:amplifiedTopUp`; `amplify-domain/tests/integration_test.bal` `testExternalShareOneClaimPerUrlAndAmplifiedCheck` |
| C5 | Medium | Duplicate claims across employees → unique on `(evidence_url, action)` | Implemented | M2, M3 | ADR-017 | V005 `UNIQUE (evidence_url, action)`; `amplify-common/modules/types/evidence_url.bal` normalization; `amplify-domain/tests/integration_test.bal` `testExternalShareOneClaimPerUrlAndAmplifiedCheck` |
| C6 | Medium | Pre-coin verification unproven → mark pending M0b research | Deferred (ADR-018) | M6, M0b | ADR-018 | [research 2026-10-16](../../../docs/research/2026-10-16-linkedin-deletion-and-analytics.md); pre-coin pass not built (plan M6) |
| C7 | Low | Campaign window has no default → `campaign.default_window_days = 30` | Implemented | M3 | — | seed `campaign.default_window_days`; V002 campaign invariant |
| C8 | Low | Team summary row needs headcount → derive per request from One WSO2 | Implemented (depends D13 data) | M7 | ADR-019 | [leaderboards.md](leaderboards.md); `amplify-api/reads.bal` `GET /team` |

## 5 · Audit D — stale and drifted artifacts

| # | Sev | Finding (mitigation) | Disposition | Milestone | ADR | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | Medium | Phase 1 PNG out of date → redrawn as a Mermaid logical view | Docs applied | M0c | — | [phase1-solution-architecture.md](phase1-solution-architecture.md) |
| D2 | Low | "Check-in" still used → "submits an external share" | Docs applied | M0c | — | [phase1-domains.md](phase1-domains.md); plan M3 |
| D3 | Low | Old "content" group in the context map → "marketing · PO · SLT · admin" | Docs applied | M0c | — | [phase1-domains.md](phase1-domains.md) context map |
| D4 | Medium | L2 understated + wrong folder → moved to Phase X - Later, banner, typo | Docs applied | M0c | — | [Phase X - Later/amplify-L2-Choreo-Solution.md](../BrainStorms/amplify-L2-Choreo-Solution.md) |
| D5 | Low | Phase labels mixed → one "Other phases" table | Docs applied | M0c | — | requirements-map §Other phases |

## 6 · Open items

| # | Item | Disposition | Owner | Milestone | ADR | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Mark R1–R11 must or should (A2) | Console-blocked | PO | M0c | — | no artefact yet |
| 2 | Consent copy and privacy notice (A9) | Console-blocked | Legal | M0c, M10 | — | placeholder in plan M0c A9 |
| 3 | Asgardeo federation for LinkedIn tokens (A8) | Console-blocked / research | Research (Developer) | M0c | — | no ADR yet |
| 4 | PO dashboard + My Team data source and visibility | Done (design); roster source is people-app `/employees/basic-info` (2026-10-19); **pending: service credential (D13)** | D13 owner | M0 D13, M7 | ADR-013, ADR-019 | [po-dashboard.md](po-dashboard.md), [leaderboards.md](leaderboards.md); `amplify-api/outbound.bal` reads the directory (3-day cache) |
| 5 | Security checklist exception for deferring data deletion (C3) | Console-blocked — security team approval pending | Security team | M0c, M10 | ADR-016 | checklist-exception, [interim runbook](../../../docs/runbooks/data-deletion-interim.md) |
| 6 | Every mitigation recorded and docs match | Docs applied | Developer | M0c | — | plan M0c; [phase1-domains.md](phase1-domains.md), [phase1-data-model.md](phase1-data-model.md), L2 banner |

## 7 · Other phases (deferred by design)

Every row in requirements-map §Other phases is **Deferred** to a later phase; none is built in phase 1 unless the "Designed in phase 1?" column says so. This table records the disposition, the decision that keeps it out, and any phase 1 seed artefact.

| Future item | Requirements | Disposition | ADR / decision | Phase 1 artefact (if any) |
| --- | --- | --- | --- | --- |
| Coin issuer, `PAID` status, points→Coins ratio, Coin value in UI | R8, R9, Q5 | Deferred | ADR-029 | V006 settlement columns + `CHECK` blocking `PAID` |
| Ledger reference aligned with wso2-coin rules | R8 | Deferred | ADR-029 | `ledger.bal` encoding is the phase 1 interim |
| Employee data deletion / anonymize | K3, K4 | Deferred | ADR-016 | security checklist exception (pending) |
| Campaign window default aligned to provider stats look-back | R4, R11 | Deferred | C7 | seed `campaign.default_window_days` |
| Pre-coin verification before any Coin issue | R8, K4 | Deferred | ADR-018 | `sharing.engagement_verification` table only |
| SLT reports (participation, reach, points) | R11 | Deferred | ADR-013 | `amplify_readonly` role + read-only user exist |
| HR Entity team/location sync (`org_dim`) | R10, R11 | Deferred | ADR-009 | none (D13 uses One WSO2 data) |
| Community Management engagement sync (reactions/comments/native reposts) | R4 | Deferred | ADR-018 | tables designed, not created |
| `COMMENT`/`REACTION`/`MENTION` point rules | R4, R6 | Deferred | ADR-018 | enum values listed |
| Revisit "one repost per campaign" | R6 | Deferred | ADR-015 | V004 UK ships as-is |
| Per-share metrics (`engagement_metric`), reach | R11, R9 | Deferred | ADR-018 | table designed, not created |
| LinkedIn org-social-action webhook (L2 B10) | R4 | Deferred | ADR-018 | none |
| Amplify agent / classifier / LLM gateway / AMP / ThunderID / Novera | P5, Q4 | Deferred | — | none |
| Two-way Google Chat | P4 | Deferred | — | one-way webhook only |
| Separate queue service | — | Deferred | ADR-025 | Postgres outbox |
| Other social channels | P3 | Deferred | ADR-005 | provider-agnostic tables |
| Me › Overview widget bar | R9 | Deferred | — | slot only (M7) |
| OpenChoreo deployment | — | Deferred | ADR-026, ADR-027 | `workload.yaml` per component |

## 8 · Decision (D-number) register — ADR mapping

From [decisions/README.md](../../decisions/README.md). "Open" = not decided yet.

| Plan D# | Topic | ADR | Status |
| --- | --- | --- | --- |
| D1 | Ballerina | ADR-001 | Accepted |
| D2 | PostgreSQL + Choreo extension check | ADR-002 | Accepted; **Choreo/Aiven check open** (B18) |
| D3 | Worker shape | ADR-003 | Accepted; scheduler part superseded by ADR-026 |
| D4 | LinkedIn OAuth redirect to a One WSO2 route | — | **Open** (SDK callback check pending) |
| D5 | Repost spike (`reshareContext`) | — | **Done 2026-10-20: `REPOST`** ([ADR-034](../../decisions/ADR-034-share-is-a-repost.md)) |
| D6 | PO decisions (points, period, reminders) | ADR-011 (partial) | **Open** — PO must/should (A2) + point values pending |
| D7 | Token retention security research | ADR-002 | **Open** (grace/rotation confirmation) |
| D9 | Choreo naming | ADR-007 | Accepted |
| D10 | Local identity: Asgardeo | ADR-008 | Accepted |
| D11 | Dockerfile buildpack | ADR-027 | Accepted |
| D12 | Repo home | **ADR-030** | Accepted (provisioning pending) |
| D13 | People data from One WSO2 | ADR-009 | Accepted; **roster endpoint open** |
| D14 | Team adjust/remove = `amplify_po` | ADR-010 | Accepted |

## Console / external-owner summary

Everything in the build is done; these are the non-code steps still outstanding, by owner:

| Owner | Items |
| --- | --- |
| **PO** | Must/should on R1–R11 (A2, Open item 1); point values (D6); pilot cut acceptance (P1). |
| **Legal** | Consent copy + privacy notice (A9, Open item 2). |
| **Security team** | Checklist exception for deferred data deletion (C3, Open item 5); threat-model review + go-live sign-off (M10). |
| **Choreo / Asgardeo console** | Asgardeo app + groups + scopes (M4); Choreo project, BYOR, API Proxy, connections and secrets (M8b); extension check on the real DB (B18); pilot group (P2/M12). |
| **WSO2 GitHub org admin** | Provision the WSO2-managed repo (D12, ADR-030). |
| **LinkedIn / Chat console** | Real Chat space + webhook secret (A7); LinkedIn developer apps on team accounts (M4). |
| **Research (Developer)** | D5 repost spike (done 2026-10-20); D4 SDK callback check; A8 Asgardeo-federation research; D13 roster endpoint. |
