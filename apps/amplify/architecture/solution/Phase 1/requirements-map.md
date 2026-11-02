# WSO2 Amplify — Requirements Map and Phase 1 Document Audit

Status: Draft v2, mitigations agreed (2026-10-16)
Source of truth: [0 PO Team · Tracking Platform Requirements](../../../docs/requirements/0%20PO%20Team%20_%20WSO2%20Amplify%20-%20Tracking%20Platform%20Requirements.md)
Audited: [phase1-domains.md](phase1-domains.md) · [phase1-data-model.md](phase1-data-model.md) · [phase1-solution-architecture.md](phase1-solution-architecture.md) · [amplify-L2-Choreo-Solution.md](../BrainStorms/amplify-L2-Choreo-Solution.md) (moved to Phase X - Later, D4) · [phase1-planned-todos.md](../../../docs/requirements/phase1-planned-todos.md)
Follow-up todos: [phase1-planned-todos.md › M0c](../../../docs/requirements/phase1-planned-todos.md#m0c--requirements-audit-follow-ups-2026-10-16)

## Contents

- [How to read this](#how-to-read-this)
- [Requirement IDs](#requirement-ids)
- [Phase 1 map](#phase-1-map)
- [Other phases (refine later)](#other-phases-refine-later)
- [Audit A · Phase 1 vs the requirements](#audit-a--phase-1-vs-the-requirements)
- [Audit B · Contradictions between phase 1 documents](#audit-b--contradictions-between-phase-1-documents)
- [Audit C · Design defects found while cross-checking](#audit-c--design-defects-found-while-cross-checking)
- [Audit D · Stale and drifted artifacts](#audit-d--stale-and-drifted-artifacts)
- [Open items](#open-items)

## How to read this

**Coverage** values:

| Value | Meaning |
| --- | --- |
| Met | Phase 1 does what the requirement asks (including once an agreed mitigation is applied) |
| Met, different mechanism | Intent met, but not the way the requirement or L0/L1 describe it |
| Partial | Some of it ships in phase 1, the rest is deferred |
| Deviates | Phase 1 does something different from what the requirement says. Needs PO sign-off |
| Deferred | Not in phase 1 |

Audit findings are `A#` (vs requirements), `B#` (doc vs doc), `C#` (design defects) and `D#` (stale artifacts). Severity: **High** blocks a requirement or will break the build, **Medium** will cause the wrong thing to be built, **Low** is naming or tidy-up. The **Mitigation** column records what was agreed on 2026-10-16. "Recommendation" means the recommendation in that row was accepted as written.

> The requirements say "Must-haves are needed for the pilot; should-haves can follow", but **no row is marked must or should**. PO is being asked to mark them (A2, todo in M0c). Until then, every Partial, Deviates and Deferred row is provisional.

## Requirement IDs

IDs are assigned here; the requirements doc has none.

| ID | Requirement (verbatim or close) | Stage | Used by |
| --- | --- | --- | --- |
| R1 | Let Marketing and PO register official WSO2 LinkedIn posts, with category and a priority flag | 1 Publish | Marketing, PO |
| R2 | Share new posts to the Amplify Google Chat space automatically | 1 Publish | Marketing, PO |
| R3 | Let each employee link their LinkedIn profile to their WSO2 account through single sign-on | 2 Connect | Employees |
| R4 | Record who reacted, commented, reposted or reposted with commentary on each post | 3 Track | System |
| R5 | Let employees submit their own WSO2-related posts for higher-tier points | 3 Track | Employees |
| R6 | Apply points automatically, once per action per post per person | 4 Score | System |
| R7 | Let PO edit point values, correct records and remove invalid activity | 4 Score | PO |
| R8 | Convert points into WSO2 Coins in the existing Coins programme | 5 Reward | System |
| R9 | Show each employee their points, Coins and activity history | 5 Reward | Employees |
| R10 | Show individual and team leaderboards | 6 Celebrate | Everyone |
| R11 | Report participation, reach and points by team, location and post | 6 Celebrate | PO, SLT |
| T1 | Tier: repost or share of WSO2 content = lowest | Points | — |
| T2 | Tier: repost or share with personal commentary = mid | Points | — |
| T3 | Tier: original employee post with meaningful WSO2 content = higher | Points | — |
| T4 | Tier: original content later amplified by WSO2 or a senior leader = highest | Points | — |
| K1 | Scale: 830+ employees, 10–30 official posts a month | Consideration | — |
| K2 | Authentication: WSO2 SSO | Consideration | — |
| K3 | Data privacy: opt-in linking, capture only the metrics needed for scoring | Consideration | — |
| K4 | Governance: automated duplicate prevention, complete audit logging | Consideration | — |
| P1 | Programme launches 15 October 2026 with a 90-day pilot (go-live since moved to 31 October 2026 by email) | Programme | — |
| P2 | 15–25 Amplify Champions kick-start the pilot | Programme | — |
| P3 | Design for additional social channels later (LinkedIn first) | Programme | — |
| P4 | Match EveryoneSocial's Google Chat integration (posts in Chat, reactions/comments in Chat flow back) | Recommendation | — |
| P5 | Offer AI help for employees writing their own posts | Recommendation | — |
| Q1–Q6 | Open questions to Internal Apps: engagement data, plain vs commentary reposts, Google Chat, AI help, Coins connection, effort and go-live | Questions | — |

## Phase 1 map

| ID | Coverage | How phase 1 does it | Where | Findings |
| --- | --- | --- | --- | --- |
| R1 | **Met** (with A6) | Campaign (S1): post URN, title, summary, image, category, tags, priority flag, window. Save / Save & Share Now. `amplify_marketing` **and `amplify_po`** can register | domains S1; data model `campaign.*`; plan M5 S1, M7 Campaigns | A6 |
| R2 | **Met** | Announcements (S5): cardsV2 card through an incoming webhook to the company-wide **WSO2 Club Group** space (the one Marketing uses today), sent by `amplify-jobs`, retried via outbox | domains S5; data model `announcement`; plan M6a | A7 |
| R3 | **Met, different mechanism** | Employee signs in to One WSO2 with Asgardeo, then connects LinkedIn by OAuth + OIDC (`openid profile w_member_social`) to `amplify-api`. **May move to Asgardeo federation** if it can hold the token encrypted and hand it to jobs (A8 research) | domains S2, D4; data model `connection.*`; plan M5 S2, M7 Connect | A8 |
| R4 | **Partial** | `w_member_social` only covers reposts made **through Amplify** (`REPOST`, `REPOST_COMMENTARY`). Reactions, comments and native LinkedIn reposts come in a future phase with Community Management access | domains C1, D7; data model `sharing.engagement` | A3, B5 |
| R5 | **Met** | External Sharing (S3, UI "My Campaign"): any HTTPS evidence URL, certify checkbox, PO review | domains S3; data model `external_sharing`; plan M5 S3, M7 My Campaign | C4 |
| R6 | **Deviates** (stricter) | Verified in-app reposts are scored automatically, `ON CONFLICT DO NOTHING` on the ledger reference. Phase 1 allows **one repost per campaign per employee**, so "once per action" becomes "once per post". Revisited with Community Management access | domains C1/C2; data model `share_request` UK | A4 |
| R7 | **Met** (with A5) | `amplify_po` edits point rules, adjusts and reverses with a reason, all audited | plan Roles, M5 C2 | A5 |
| R8 | **Deferred** | Points are `HELD` in `scoring.points_ledger`. No Coin issuer | domains scope; data model settlement status | A11 |
| R9 | **Partial** | `/me/points` (total, rank, monthly history), own shares, My Campaign portfolio. **Points only, no Coin value** in phase 1 | plan M5 S4, M7 Leaderboard | A11 |
| R10 | **Partial → Met once B15 lands** | Three leaderboards: company top N (default 3), personal (own rank and gap), and **My Team**. Team grouping uses One WSO2 team data (D13) | domains S4; plan M7 Leaderboard, Team, M0c | A10, B15 |
| R11 | **Partial** | PO dashboard stays in phase 1 (to be defined, B6). SLT reports are phase 2. Reach needs the analytics API (future phase) | plan MVP #4, M0b, M0c | A13, B6, B7 |
| T1 | **Partial** | `REPOST` (spike D5 passed 2026-10-20). `SHARE` stays in the enums as the fallback | data model `point_rule` | B4 |
| T2 | **Met** | `REPOST_COMMENTARY` | data model `point_rule` | — |
| T3 | **Met** | `OWN_POST` via External Sharing, PO-approved | data model `point_rule`, `external_share` | — |
| T4 | **Met** (with C4) | `OWN_POST_AMPLIFIED`, set by PO (`/amplified`) on an approved claim only. Awarded as a top-up row on top of the T3 award | plan M5 S3; data model `external_share.amplified_at` | C4 |
| K1 | **Met** | Pre-built `recognition.standing`, p95 < 50 ms target, load test with 1k employees / 50k ledger rows | data model recognition; plan M11 | — |
| K2 | **Met** | Asgardeo, roles from groups, JWT verified at proxy and in an interceptor | plan Roles, M4 | — |
| K3 | **Deviates** (pending Legal) | Opt-in: yes. Phase 1 also holds a `w_member_social` token that can post on the employee's behalf. Consent copy placeholder in M0c until Legal signs off | domains S2; plan M10, M0c | A9 |
| K4 | **Met** | Ledger reference + unique keys + idempotency keys; `audit.audit_log` for every write, 5-year retention | data model scoring, audit | C1, C5 |
| P1 | **Partial** | Go-live 31 Oct 2026. Dated milestones added (2026-10-16), with a high go-live risk and a minimum pilot cut for PO | plan [Suggested order](../../../docs/requirements/phase1-planned-todos.md#dated-milestones-to-go-live-31-oct-2026) | A1 |
| P2 | **Met** | Pilot group in Asgardeo + preview flag | plan M12 | — |
| P3 | **Met** | Provider-agnostic tables (`provider`, `provider_api`, resource URN), `ProviderAdapter` port | data model design rule 9; domains C1 | — |
| P4 | **Partial** | Posts appear in Chat. Two-way Chat is a future phase | plan M6a | A12 |
| P5 | **Deferred** | Novera / agent in a future phase | domains scope | A12 |
| Q1 | Answered | In-app reposts only (`w_member_social`); the rest needs Community Management | domains C1 | A3 |
| Q2 | Answered | Yes for in-app shares, because the employee picks the kind. Native reposts in a future phase | domains C1 | A3 |
| Q3 | Answered | One-way webhook to WSO2 Club Group; two-way later | plan M6a | A7, A12 |
| Q4 | Deferred | Agent is a future phase | — | A12 |
| Q5 | Deferred | Held in ledger; Coin contract open (L2 open items 3, 4) | L2 | A11, C1 |
| Q6 | Answered (date) | Go-live 31 Oct 2026; effort estimate still to be written | plan M0c | A1 |

## Other phases (refine later)

Placeholder. Phase numbers come from the documents where they say one; the rest are "Later" until PO and the team sequence them. The documents themselves mix "phase 2", "later phase" and "future phase" ([D5](#audit-d--stale-and-drifted-artifacts)).

| Item | Requirement(s) | Target | Depends on | Designed in phase 1? |
| --- | --- | --- | --- | --- |
| Coin issuer, `PAID` ledger status, points → Coins ratio, Coin value in the UI | R8, R9, Q5 | Phase 2 | Coin `reference` + `source` on master/transfer, email → wallet, ratio (L2 open items 3, 4) | Yes: settlement columns, `CHECK` dropped by phase 2 migration |
| Ledger reference encoding aligned with wso2-coin rules | R8 | After phase 1 | wso2-coin reference rules | C1 |
| Employee data deletion / anonymize request (incl. ledger) | K3, K4 | Future | Security checklist exception for the pilot; ledger erasure design | C3 |
| Campaign window default aligned to the provider's stats look-back limit | R4, R11 | Future | Community Management / analytics access | C7 (config key ships in phase 1) |
| Pre-coin verification must have run before any Coin issue | R8, K4 | Phase 2 gate | M0b deletion-API research | Partly: `engagement_verification` ([C6](#audit-c--design-defects-found-while-cross-checking)) |
| SLT reports (participation, reach, points by team, location, post) | R11 | Phase 2 | `amplify_readonly` user, org data, analytics API | Role and read-only user exist |
| HR Entity team/location sync (`org_dim`) | R10, R11 | Later | HR Entity GraphQL access | No (D13 uses One WSO2 data instead) |
| Community Management engagement sync: reactions, comments, native reposts; `org_connection`, `sync_cursor` | R4 | Future | LinkedIn Community Management approval | Yes: tables designed, not created |
| `COMMENT` / `REACTION` / `MENTION` point rules | R4, R6 | Future | Sync above + PO point values | Enum values listed |
| Revisit "one repost per campaign" vs "once per action" | R6 | Future | Community Management access | A4 |
| Per-share metrics (`engagement_metric`): impressions, likes, comments, reposts; reach | R11, R9 | Future | `r_member_postAnalytics` / approval | Yes: table designed |
| LinkedIn org-social-action webhook (L2 B10) | R4 | Later | Community Management | No |
| Amplify agent, classifier, LLM gateway, AMP, ThunderID, Novera tools | P5, Q4 | Future | Agent platform | No |
| Two-way Google Chat (reactions/comments in Chat feed scoring) | P4 | Future | Chat app instead of webhook (Novera or new) | No |
| Separate queue service | — | Later | Volume | No (Postgres outbox) |
| Other social channels | P3 | Later | Per-provider adapter | Yes: provider-agnostic |
| Me › Overview widget bar | R9 | Later | — | Slot only |
| OpenChoreo deployment | — | Later | — | Yes: `workload.yaml`, portable images |

---

## Audit A · Phase 1 vs the requirements

| # | Sev | Finding | Evidence | Recommendation | Mitigation |
| --- | --- | --- | --- | --- | --- |
| A1 | **High** | **Launch date not addressed.** The requirements say the programme launches **15 October 2026** with a 90-day pilot, and ask for effort and the earliest go-live (Q6). No phase 1 document has a date or an estimate | requirements L7, L102; plan has no dates | Confirm the date with PO and add dated milestones to the plan | **Go-live moved to 31 Oct 2026** (by email). Todo in M0c: add dated milestones to the plan |
| A2 | **High** | **Must vs should isn't marked.** The requirements say must-haves are needed for the pilot, but the table has no must/should column | requirements L25, L27–39 | Ask PO to tag each R1–R11 as must or should, then re-check this map | **Todo added** (M0c A2) |
| A3 | **High** | **Native LinkedIn reposts have no path.** R4 wants every repost recorded. Phase 1 records only reposts made through Amplify. The plan's MVP says an employee can check in "a repost in the LinkedIn app", but `external_share.action` only allows `OWN_POST` | plan L13; domains L142; data model L435 | Add `REPOST` to external shares, or drop the MVP claim and tell PO | **Deferred to a future phase.** Phase 1 is limited to `w_member_social`, which only handles reposts made through Amplify. Remove "repost in the LinkedIn app" from the MVP |
| A4 | Medium | **One repost per campaign per employee** is stricter than R6 ("once per action per post") | domains L109; data model L416, L731 | Get PO sign-off | **Revisit once Community Management API access is granted** |
| A5 | **High** | **PO can't edit point values.** R7 gives point values to PO. The plan gives `/admin/point-rules` to `amplify_admin` | requirements L35; plan L72, L216, L294 | Give `amplify_po` write on point rules | **Point rules are maintained by `amplify_po`.** Todo in M0c to update Roles, M5, M7 |
| A6 | Medium | **PO can't register posts.** R1 says "Marketing and PO". Phase 1 limits campaign writes to `amplify_marketing` | requirements L29; plan L70, L212; domains L166 | Allow `amplify_po` on the campaign endpoints | **Allow `amplify_po` on every campaign endpoint.** Todo in M0c |
| A7 | Medium | **Which Chat space?** R2 says the "Amplify Google Chat space". Phase 1 posts to WSO2 Club Group | requirements L30, flow step 2; domains L10; plan L11, M6a | Confirm the space with PO | **Use WSO2 Club Group**: it's company-wide and Marketing already uses it. Can change later (it's a per-environment secret) |
| A8 | Low | **Connect isn't Asgardeo federation.** L1 planned LinkedIn linking through Asgardeo's federated connection. Phase 1 uses LinkedIn OAuth directly | L1 L70, L92; domains D4, S2 | Keep, and say so | **Conditional.** If Asgardeo federation can store the LinkedIn association **and** encrypts the stored token (and can hand it to jobs when the employee isn't signed in), switch to it and update the ERD and docs. Research todo in M0c |
| A9 | Medium | **Privacy scope grew.** K3 says capture only metrics needed for scoring. Phase 1 holds a token that can post as the employee, plus commentary until publish | requirements L88; domains S2; plan M10 L426 | Name it in the consent copy and get Legal sign-off | **Legal todo added** (M0c A9) with placeholder copy: *"When you ask it to, Amplify posts on your LinkedIn for you…"* |
| A10 | Medium | **No team leaderboard, and the "Team" page isn't one** | requirements L38; plan L292; domains L150 | Rename the page and add a team view, or defer | **Todo added:** "Audit A10 - ensure Team Leaderboard functionality". See B15 for the three leaderboards |
| A11 | Medium | **"Coins shown as held" has no rule** | plan L290; data model settlement | Show points only, or a provisional Coin figure | **Phase 1 shows points only; no Coin value** |
| A12 | Low | **Chat two-way and AI help not matched** | requirements L66, L76, L96, L98 | Record as a conscious gap | **Deferred to a future phase** |
| A13 | Low | **"Reach" may not be reachable.** Needs per-share analytics (`r_member_postAnalytics` or Community Management) | plan M0b L113 | Tell PO early | **Deferred to a future phase** |

## Audit B · Contradictions between phase 1 documents

| # | Sev | Finding | Evidence | Recommendation | Mitigation |
| --- | --- | --- | --- | --- | --- |
| B1 | **High** | **Decision IDs collide.** domains D1–D7 and plan D1–D14 don't match from D5 on. The data model cites plan numbers and once mixes them ("D2/D7"). domains S4 cites D14, which isn't in the domains table | domains L18–26, L150; plan L82–103; data model L313, L607 | One decision register: create the ADRs (plan L98) and cite `ADR-NNN` everywhere | Recommendation |
| B2 | Medium | **Campaign states differ.** Plan: `SAVED → OPEN → CLOSED → ARCHIVED`. domains and data model: `SCHEDULED / OPEN / CLOSED / ARCHIVED`, derived | plan L161; domains L128; data model L229 | Use the data model's derived states in the plan | Recommendation |
| B3 | Medium | **ShareRequest key differs.** Plan: unique `(campaign, employee, kind)`. domains and data model: `(campaign, employee)` | plan L163; domains L109; data model L336–337, L416 | Use `(campaign, employee)` in the plan | Recommendation, **for phase 1** (revisit with A4) |
| B4 | Medium | **`SHARE` kind has no home.** Plan D5 may fall back to "only `SHARE`", but no enum has `SHARE` | plan L89, L289; data model L341, L361, L479 | Add `SHARE` (and `SHARE_COMMENTARY`) to the enums now | Recommendation |
| B5 | Medium | **Comments and reactions: in or out?** domains and data model say out; plan D6 and the Admin screen still include them | domains L26, L242; data model L529, L733; plan L90, L294 | Pick one | **Out of phase 1; deferred to a future phase** because of API access. Remove from plan D6 and M7 Admin |
| B6 | Medium | **PO dashboard: phase 1 or 2?** MVP and M0b say phase 2; Roles and M5 `GET /po/dashboard` say phase 1 | plan L14, L69, L117, L217; domains L152 | Drop it, or define it | **Keep the PO dashboard in phase 1.** Todo in M0c to define it in detail. Update MVP #4, M0b and domains S4 to match |
| B7 | Low | **SLT report in phase 1 tests** | plan L437, L382 | Remove from the phase 1 E2E | Recommendation |
| B8 | Medium | **Announcement event wiring differs.** The handler should consume `CampaignRegistered`, not `CampaignAnnounced`. Context-map arrows use names not in any catalogue | domains L50, L57, L181–182; plan L233 | Fix the handler; relabel the arrows | Recommendation |
| B9 | Medium | **Event catalogue drift.** `ConnectionExpired`, `ExternalShareAmplified`, `EmployeeErased`, `CampaignOpened` each appear in only one doc | plan L167, L234; domains L177–187; data model L703–713 | One catalogue (data model), linked from domains and plan | Recommendation |
| B10 | Medium | **Maintenance endpoint name and scope differ** (`/maintenance/partitions` vs `/maintenance/token-partitions`; audit and outbox upkeep not scheduled) | plan L185, L240, L246; data model L317, L695–696 | One name (`/maintenance/partitions`) covering tokens, audit and outbox, scheduled daily | Recommendation |
| B11 | **High** | **Two token-drop rules.** The age rule in plan M6 would delete phase 2 refresh tokens | plan L240 vs L185; data model L316 | Use the `max(expires_at) + grace` rule everywhere | Recommendation |
| B12 | **High** | **API can't update recognition, but writes ledger rows** (PO adjust/reverse) | data model L100, L545, L719; plan L216 | Route through jobs, or grant the API write | **Grant `amplify_api` write on `recognition`**, so adjustments update standings in the same transaction. Update the grants table and the "Written by" column |
| B13 | Low | **`person_urn` vs `member_urn`** | domains L134; plan L162; data model L241 | Use `member_urn` everywhere | Recommendation |
| B14 | Low | **Connection and share states differ**, and M9 leaves share rows "`PENDING`" | plan L162–163, L350; data model L306, L346, L412 | Use the data model's derived states | Recommendation |
| B15 | Medium | **"No full list" vs the Team page.** The Team page shows everyone's rank to every employee; M5 says visibility is "per D14", which is about adjust/remove | domains L149–150; plan L14, L217, L292 | Decide who sees Team | **Three leaderboards:** a **company top 3** (top N), a **personal** leaderboard (own rank, points, gap), and a **My Team** leaderboard. Todo in M0c. Team-page visibility follows from this |
| B16 | Low | **Leaderboard size: fixed or configurable?** | plan L72, L294; data model L559, L697 | Fix it, or rename the column | **Configurable top N, default 3 for phase 1** (`leaderboard.top_n = 3`). Rename `points_to_podium` → `points_to_top_n` |
| B17 | Low | **Audit retention open and closed** | plan L91, L175; domains L247; data model L734 | Close the audit part of D7 | Recommendation |
| B18 | Medium | **Postgres extensions not checked** (`citext`, `pg_trgm`) | data model L165, L553, L600; plan L83, L183, L345 | Add them to the D2 check and the portability rule | Recommendation |
| B19 | Low | **Code layout vs ownership.** Shared modules sit in `amplify-api` but jobs uses them | plan L134–135, L147; domains L206 | Show `amplify_common` in the M1 tree | **Review again later** (todo in M0c) |
| B20 | Low | **Evidence URL rule.** M5's "URL hosts" reads like an allowlist; M2 says any public HTTPS URL | plan L159, L220, L425 | Say "host blocklist" | **Drop "URL hosts" from M5.** M2 and M10 already define the URL rules |
| B21 | Low | **Deployables count** ("2", "three", six components) | PNG; domains L8; plan L92 | One phrase everywhere | Recommendation |

## Audit C · Design defects found while cross-checking

| # | Sev | Finding | Evidence | Recommendation | Mitigation |
| --- | --- | --- | --- | --- | --- |
| C1 | **High** | **Ledger reference is too long.** `varchar(66)`, but `AMP-` + hex sha256 = **68** chars | data model L486, L530; L2 L125 | base64url (47 total) or truncate; add a length test | **Revisit after phase 1** when the wso2-coin reference rules are ready (todo in M0c). Until then the column must still fit the hash, so pick an encoding that fits 66 for phase 1 |
| C2 | **High** | **A failed share locks the employee out of that campaign.** Unique `(campaign_id, employee_id)` + final `failed_at`, with no retry path after reconnect | data model L336–346, L416–420; plan L234, L297 | Reuse the row on retry, or a partial unique key | Recommendation: **reuse the row on retry** (clear `failed_at` / `failure_reason`, bump `attempts`, re-queue). Keeps one row per campaign per employee |
| C3 | **High** | **Erasure can't anonymize the ledger.** `employee_id` is immutable by column grants; deleting shares orphans `source_id` | plan L395; data model L174, L528 | Define erasure for the ledger and document the legal basis | **Deferred to a future phase** (phase 1 is quick to market). Remove the data-deletion path from phase 1 M10 and the `EmployeeErased` handling from the phase 1 build. ⚠ **Security flag:** the WSO2 Application Deployment Security Checklist asks for a data-deletion request path, so the pilot needs a recorded **checklist exception** (and a manual interim process if a request comes in). Todo in M0c |
| C4 | Medium | **AMPLIFIED is under-specified** (shows on rejected claims; top-up vs replace undefined) | data model L445, L459; plan L215 | `CHECK` + define the award | Recommendation: `CHECK (amplified_at IS NULL OR decision = 'APPROVED')`; the T4 award is a **top-up row** for the difference (`OWN_POST_AMPLIFIED` points − `OWN_POST` points), so the ledger stays append-only |
| C5 | Medium | **Duplicate claims across employees** for the same evidence URL | data model L463 | PO-visible warning or unique on `(evidence_url, action)` | **Unique in the DB** on `(evidence_url, action)`. On conflict the API returns a stable code (`EVIDENCE_ALREADY_CLAIMED`) and My Campaign shows: *"Someone else already submitted this url, contact PO Team for review"*. Normalize the URL before the check (scheme, host case, trailing slash, tracking params) or the key is easy to dodge |
| C6 | Medium | **Pre-coin verification is written as fact but unproven** | domains L154; data model L368–375; plan L112 | Mark "pending M0b research" | Recommendation |
| C7 | Low | **Campaign window has no default** (`closes_at`) | plan L287; data model L201, L697 | Seed a default window | Phase 1's only API (`w_member_social`) reads no stats, so there's no provider limit to inherit. **Default `closes_at` = `opens_at` + 1 month**, from config key `campaign.default_window_days = 30`. Todo in M0c: when Community Management / analytics access arrives, check its stats look-back limit and align the default to it |
| C8 | Low | **Team summary row needs headcount Amplify doesn't have** | plan L292; data model design rule 6 | Use One WSO2 employee data | Recommendation. Headcount is **derived per team on each request** from One WSO2's employee data (not stored in Amplify); "active" comes from `recognition.standing` |

## Audit D · Stale and drifted artifacts

| # | Sev | Finding | Evidence | Recommendation | Mitigation |
| --- | --- | --- | --- | --- | --- |
| D1 | Medium | **Phase 1 PNG is out of date.** No API proxy, no `amplify-cron`, "check-in", Token store as its own box, PO "Tracks" | PNG; domains L3; plan L5 | Redraw from the plan's "Architecture at a glance" | Recommendation, as a **logical** view (contexts, cell edge, deployables, externals; no Choreo specifics). Todo in M0c |
| D2 | Low | **"Check-in" still used** | domains L34; plan L13, L175; PNG | Replace with "submits an external share" | Recommendation |
| D3 | Low | **Old "content" group** in the domains context map | domains L39 | Change to "marketing · PO · SLT · admin groups" | Recommendation |
| D4 | Medium | **L2 banner understates what's superseded, and the file is in the wrong folder.** Also "ASGARDIO" typo | L2 L1–8; plan L5; domains L221–235 | Move to `Phase X - Later/`, point the banner at the domains "What changes" table, fix the typo | Recommendation (move also needs the links in domains, plan and L1 updated) |
| D5 | Low | **Phase labels mixed** ("phase 2", "later phase", "future phase") | data model L253, L376, L423; plan L192; domains L12 | Use this map's "Other phases" table as the one place phases are assigned | Recommendation |

## Open items

What's still undecided after the 2026-10-16 mitigations:

1. **PO:** mark R1–R11 must or should (A2).
2. **Legal:** consent copy and privacy notice (A9).
3. **Research:** Asgardeo federation for LinkedIn tokens (A8). Its result may change S2 and the data model.
4. ~~**Design:** PO dashboard contents (B6); My Team leaderboard data source and visibility (A10, B15).~~ **Done 2026-10-16:** [po-dashboard.md](po-dashboard.md), [leaderboards.md](leaderboards.md), ADR-019. Still depends on a server-callable One WSO2 roster endpoint (plan M0 D13).
5. **Security:** checklist exception for deferring the data-deletion path (C3). Request written (exception, [interim runbook](../../../docs/runbooks/data-deletion-interim.md)); **awaiting security team approval**.
6. **Applied (2026-10-16, M0c):** every finding has a mitigation, recorded here and in M0c, and the docs now match:
   - **[phase1-planned-todos.md](../../../docs/requirements/phase1-planned-todos.md):** all mitigations, plus dated milestones (A1).
   - **[phase1-domains.md](phase1-domains.md):** B2 derived campaign states, B3 `(campaign, employee)` key, B4 `SHARE` / `SHARE_COMMENTARY`, B8 `CampaignRegistered` wiring in the context map and relationships, B9 events moved to the single catalogue, B10/B11 one daily `/maintenance/partitions` and one token-drop rule, B12 api writes recognition, B13 `member_urn`, B16 top N, A5/A6 roles, A11 points only, B6/B15 S4 rewritten, C2 retry reuses the row, C4 top-up, C5 key, C6 verification marked future (ADR-018), C7 default window, D2 "check-in" gone, D3 groups, D5 phase labels.
   - **[phase1-data-model.md](phase1-data-model.md):** B4 enums, B9 single event catalogue (incl. `ConnectionRevoked`, `ExternalShareAmplified`; no `CampaignOpened`, `ConnectionExpired`, `EmployeeErased`), B10/B11 maintenance, B12 grant + "Written by", B16 `points_to_top_n` + `leaderboard.top_n`, B17 audit closed, B18 `citext` / `pg_trgm` rule, C1 base64url reference, C2 retry, C3 erasure removed from phase 1, C4 `CHECK` + top-up, C5 `UNIQUE (evidence_url, action)` + normalization, C7 `campaign.default_window_days`, D5 phase labels.
   - **L2:** moved to [Phase X - Later](../BrainStorms/amplify-L2-Choreo-Solution.md) with an expanded banner (D4).
   - **D1:** the architecture is now a Mermaid diagram in [phase1-solution-architecture.md](phase1-solution-architecture.md); the old PNG is removed.
