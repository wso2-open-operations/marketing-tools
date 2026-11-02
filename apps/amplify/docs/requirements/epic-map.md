# WSO2 Amplify: Epic Map

**Epic:** [Amplify App #1613](https://github.com/wso2-enterprise/wso2-digital-team-project-management/issues/1613) in `wso2-enterprise/wso2-digital-team-project-management`
**Lifecycle:** SDLC for WSO2 Digital Team (9 stages, governance outputs and channels)
**Phase source of truth:** "Amplify Requirements / Phase Breakdown" (screenshot, 2026-10-24). Older phase breakdowns in `CLAUDE.md`, the requirements map and the plan are superseded for this epic.
**Status evidence:** git history and code as of 2026-10-24, and the [SDLC walk re-walk of 23 Oct](sdlc-checklist-walk.md) and the code change audit of 24 Oct
**Scripts:** two helper scripts built the 108 issues (run on 24 Oct) and regroup them by phase. Both dry-run by default; `--apply` changes GitHub. They live in the workspace repo, outside `projects/` (see the PR plan note on moving them).

---

## 1. Structure

The epic reads as Epic, then phase, then SDLC stage, then work. Each phase runs its own copy of SDLC stages 2 to 8, so a phase closes when its stages close. The epic only closes when all four phases have closed.

Discovery (SDLC 1) and post-production (SDLC 9) happen once for the programme, so they stay directly under the epic.

```
Epic #1613 Amplify App
├── SDLC 1  Discovery and Problem Definition              (once, T1.x)
├── PHASE 1  Pilot, go-live 31 Oct 2026
│   ├── SDLC 2  Solution Architecture and Technical Design (T2.x)
│   ├── SDLC 3  Requirement Breakdown and Planning         (T3.x)
│   ├── SDLC 4  Development                                (T4.x)
│   │   ├── R1 R2 R3 R4a R6 R10 R11, each with its features
│   │   └── PLAT platform foundations, with FP1 to FP12
│   ├── SDLC 5  Security Review                            (T5.x)
│   ├── SDLC 6  Deployment and Release Management          (T6.x)
│   ├── SDLC 7  User Acceptance Testing                    (T7.x)
│   └── SDLC 8  Go-Live                                    (T8.x)
├── PHASE 2  Coins, points and Coins history, SLT reports
│   ├── SDLC 2 to SDLC 8   (copies, not started)
│   └── SDLC 4 holds R8, R9, R11b with their features
├── PHASE 3  Own posts and PO point edits
│   ├── SDLC 2 to SDLC 8   (copies, not started)
│   └── SDLC 4 holds R5, R7 with their features
├── PHASE 4  Reactions, comments and native reposts
│   ├── SDLC 2 to SDLC 8   (copies, not started)
│   └── SDLC 4 holds R4b with its features
└── SDLC 9  Post-Production Support and Continuous Improvement (once, T9.1)
```

Phase 1 reuses the stage issues that already exist (#1688 to #1694). Phases 2 to 4 get copies with the same outputs and communication lines, marked not started. The phase 2 to 4 stages start empty. Add activity tasks to them as each phase begins.

**R11 is split.** R11 (PO dashboards, phase 1) keeps F11.1 to F11.3. A new R11b (SLT reports and reach, phase 2) takes F11.4 and F11.5, so no phase holds a feature from another phase.

**Where each item lands**

| Item | Phase | Parent |
| --- | --- | --- |
| R1, R2, R3, R4a, R6, R10, R11 | 1 | Phase 1, SDLC 4 |
| PLAT (platform foundations) | 1 | Phase 1, SDLC 4 |
| T2.x to T5.x, T6.x to T8.x | 1 | Phase 1, their own stage |
| R8, R9, R11b | 2 | Phase 2, SDLC 4 |
| R5, R7 | 3 | Phase 3, SDLC 4 |
| R4b | 4 | Phase 4, SDLC 4 |
| T1.x, T9.1 | none | SDLC 1 and SDLC 9, under the epic |

Titles of phase 1 stages and tasks carry both tags, for example `[AMPLIFY][PHASE1][SDLC6] Write the rollback plan`.

**Why requirement items sit under Development.** Each phase's Development stage holds the build work of that phase: its requirement items and their features, so the stage closes when the phase's features are built. Requirement Breakdown (SDLC 3) holds the planning tasks (confirm go-live, MVP rewrite, estimates) and closes when planning is done. An earlier version put the requirement items under SDLC 3, which left the Development stages of phases 2 to 4 empty.

Sub-issues are native GitHub sub-issues. The epic body gets a `## Phases` checklist.

### 1.1 Title tags (no new labels)

We have triage access on the repo, so we cannot create labels. Phase and stage go in the issue title instead, as a tag prefix: `[AMPLIFY][PHASE1] task description`. The script applies only labels that already exist.

| Item | Title tag | Example |
| --- | --- | --- |
| SDLC stage issue | `[AMPLIFY][SDLCn]` | `[AMPLIFY][SDLC4] Development` |
| Activity task, no phase | `[AMPLIFY][SDLCn]` (its stage) | `[AMPLIFY][SDLC5] Send the checklist and threat model to sc-team@wso2.com for +1` |
| Activity task, phase-specific | `[AMPLIFY][PHASEn]` | `[AMPLIFY][PHASE1] Write the rollback plan: backup restore and pinned image tags` |
| Requirement item | `[AMPLIFY][PHASEn]` | `[AMPLIFY][PHASE3] Score: apply points automatically, once per action per post per person` |
| Feature | `[AMPLIFY][PHASEn]` | `[AMPLIFY][PHASE1] Company top three this month, cached 2 hours (ADR-037)` |

| Label | Used on | Status |
| --- | --- | --- |
| `Type/Epic`, `EpicLevel/Business` | Epic | Exists on #1613 |
| `Type/Task` | SDLC stages, activities, requirement items | Exists |
| `Type/New Feature` | Features | Exists. The skill's `Type/Feature` does not exist in this repo |

The phase and stage are also written in each issue body, and the stage is clear from the parent. To list one phase, search the repo for `[AMPLIFY][PHASE1]` in the title. To list everything, search `[AMPLIFY]`.

Stage issues carry no phase tag, since a stage covers all phases. The hidden marker `amplify-map: KEY` in each body is what the script uses to avoid creating anything twice.

---

## 2. SDLC stages

| Stage | Status on 2026-10-24 | Outputs (from the governance checklist) | Communication |
| --- | --- | --- | --- |
| 1. Discovery and Problem Definition | Output done. Gate email to `wso2-digital-team@` not on record | Problem statement, as-is process, value definition, three feasibility answers, high-level requirements | Email, stakeholder meeting |
| 2. Solution Architecture and Technical Design | Output done: SAD, architecture diagram, EA review of 19 Oct, 37 ADRs. Architecture-group +1 not on record. Design has drifted | SAD, OpenAPI, data models, integration diagram, HLTD. The threat model is prepared here | Architecture review meeting, email `architecture-group@` |
| 3. Requirement Breakdown and Planning | Output done: requirements, phase plan, dated milestones. Plan trails Novera and dashboards. Estimate is thin | Product backlog (the 12 requirement items), estimation sheet, milestones, bi-weekly deliverables | Email, stakeholder meeting |
| 4. Development | Output done on the forks; all merged to fork `main`. Choreo dev deploy not started. Two-approval evidence not verified | Source code, reusable components, review notes, unit test reports. PRs about 200 to 400 LOC, at most about 600 | GitHub PRs, Choreo dev deploy, email updates |
| 5. Security Review | Checklist and threat model exist as markdown. Threat model v0.3 is stale. `.docx` not generated. Security +1 pending | Security checklist, threat model (`.docx`), +1 from security | Email `sc-team@` |
| 6. Deployment and Release Management | Not started | Production release on Choreo, deployment logs, release note, rollback plan | Release email per milestone |
| 7. User Acceptance Testing | Not started. Pilot Champions test on dev; no staging planned | UAT sign-off, bug-fix release | UAT meetings, email +1 |
| 8. Go-Live | Not started. Depends on stages 5 to 7 | Live system, go-live report, developer, user and admin docs | Announcement by email and the Chat space |
| 9. Post-Production Support and Continuous Improvement | Not started. Phase 2 to 4 items enter the backlog here | Maintenance, bug-fix releases, improvement backlog | Email, Chat |

---

## 3. Activity tasks (children of each stage)

Activities are the governance and delivery steps the 23 Oct re-walk found open. Each one is a task with a clear finish line.

### Stage 1: Discovery

| Key | Phase | Activity |
| --- | --- | --- |
| T1.1 | none | Send the gate email with the requirements and the three feasibility answers |
| T1.2 | none | Hold feasibility talks with Security and Compliance, Revenue Operations, Infrastructure and the requirement initiators |

### Stage 2: Architecture

| Key | Phase | Activity |
| --- | --- | --- |
| T2.1 | none | Send the architecture-group +1 request with the SAD, the ADR delta and the 19 Oct EA review |
| T2.2 | none | Update the SAD for the Novera egress, the dashboards and the people-app boundary |

### Stage 3: Planning

| Key | Phase | Activity |
| --- | --- | --- |
| T3.1 | none | Confirm go-live on 31 Oct, or move it. Every later stage waits on this |
| T3.2 | none | Rewrite the MVP definition and milestone M7 against the screenshot phase table |
| T3.3 | none | Write the estimation sheet |

### Stage 4: Development

| Key | Phase | Activity |
| --- | --- | --- |
| T4.1 | none | Deploy amplify-api, amplify-jobs and the database to Choreo dev (M8b, due 21 Oct, missed) |
| T4.2 | none | Pull review data for each merged PR and confirm two approvals |
| T4.3 | none | Raise upstream PRs in reviewable slices of about 200 to 400 LOC |

### Stage 5: Security Review

| Key | Phase | Activity |
| --- | --- | --- |
| T5.1 | none | Write the threat model v0.4 delta: the Novera egress, the CSV export with reposter emails, the person board endpoint |
| T5.2 | none | Get the WSO2 threat model and checklist templates, and generate the `.docx` files |
| T5.3 | none | Send the checklist and threat model to `sc-team@` for +1 (due 22 Oct, not sent) |

### Stage 6: Deployment and Release

| Key | Phase | Activity |
| --- | --- | --- |
| T6.1 | 1 | Open and merge the upstream people-app PR, and deploy it. Blocks My Team |
| T6.2 | 1 | Deploy in order: wso2-digital-agents `4b7d5ff`, marketing-tools `a3c7b7e`, one-wso2 `c63e051` |
| T6.3 | 1 | Write the rollback plan: backup restore and pinned image tags |
| T6.4 | 1 | Set Choreo connections and secrets: people directory and Novera credentials |
| T6.5 | 1 | Get the production deployment approval by email, after T2.1 and T5.3 |

### Stage 7: UAT

| Key | Phase | Activity |
| --- | --- | --- |
| T7.1 | 1 | Run UAT on dev with the pilot Champions, using `TestAmplify.md` section 6 |
| T7.2 | 1 | Check real photos and names render in dev (D13) |
| T7.3 | 1 | Get the PO sign-off on UAT by email |

### Stage 8: Go-Live

| Key | Phase | Activity |
| --- | --- | --- |
| T8.1 | 1 | Send the go-live announcement by email and to the Chat space |
| T8.2 | 1 | Write the user guide and admin documentation, linking the runbooks |
| T8.3 | 1 | Set up uptime checks (UptimeRobot or an internal monitor) |

### Stage 9: Post-Production

| Key | Phase | Activity |
| --- | --- | --- |
| T9.1 | none | Run post-production monitoring, bug triage and intake of the phase 2 backlog |

---

## 4. Requirement items (Stage 3 backlog)

Phases follow the screenshot phase table. Row 4 of the PO table is split in two, because the screenshot splits it.

| Key | Phase | Requirement item | Used by |
| --- | --- | --- | --- |
| R1 | 1 | Publish: register official WSO2 LinkedIn posts with category and priority | Marketing, PO |
| R2 | 1 | Publish: share new posts to Google Novera App | Marketing, PO |
| R3 | 1 | Connect: link each employee's LinkedIn profile to their WSO2 account through SSO | Employees |
| R4a | 1 | Track: record who reposted on each post | System |
| R4b | 4 | Track: record who reacted, commented, reposted or reposted with commentary. Depends on LinkedIn Community API approval | System |
| R5 | 3 | Track: employees submit their own WSO2-related posts for higher-tier points | Employees |
| R6 | 1 | Score: apply points automatically, once per action per post per person | System |
| R7 | 3 | Score: PO edits point values, corrects records and removes invalid activity | PO |
| R8 | 2 | Reward: convert points into WSO2 Coins in the existing Coins programme | System |
| R9 | 2 | Reward: employees see their points, Coins and activity history | Employees |
| R10 | 1 | Celebrate: individual and team leaderboards | Everyone |
| R11 | 1 | Celebrate: report participation, reach and points by team, location and post | PO, SLT |

---

## 5. Features (children of each requirement item)

Status is written in the feature body. "Built, ahead of phase N" means the code is merged to a fork `main` and its phase tag is later.

### R1: Register posts (phase 1)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F1.1 | Campaign registration API: category, priority, window, image, tags | Built | `amplify-domain` campaign module; `/campaigns`, `/tags`, `/categories`; `c71de94`, `52b7dce` |
| F1.2 | New Post page: Save and Save and Share Now | Built | `one-wso2` `NewPostPage.tsx`; `26d3bf5f` |
| F1.3 | Current Posts list and edit post | Built | `CurrentPostsPage.tsx`, `EditPostDialog.tsx`; `813e118a` |
| F1.4 | Default post image when the post image is missing or fails | Built | `aeae9747`, `4a41b05` |

### R2: Share to Google Chat through Novera (phase 1)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F2.1 | Novera announcement card: campaign image and Amplify button | Built, needs agents change deployed first | `novera.bal`; `buildNoveraNotification`; `56271f0`; agents `4b7d5ff` |
| F2.2 | Admin retry of failed announcements | Built | `/admin/announcements/{id}/retry` |
| F2.3 | Local Chat stub and Novera mock | Built | `local/chat-stub`, `local/novera-mock` |

### R3: Connect LinkedIn through SSO (phase 1)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F3.1 | Asgardeo sign-in, JWT verification and role matrix | Built | `amplify-api` interceptors and `modules/auth`; `a78eca3` |
| F3.2 | LinkedIn OAuth connect and callback | Built | `/connections/linkedin/start` and `/complete`; `LinkedInCallbackPage`, `LinkLinkedInDialog`; `fa716b93`, `de0f133d` |
| F3.3 | Encrypted LinkedIn token storage, re-seal on use | Built | `amplify-common` crypto; `db4d9c5` |
| F3.4 | Unlink a LinkedIn user (support script) | Built | `scripts/unlink-linkedin-user.sh`; `061645e` |
| F3.5 | Opt-in consent copy for profile linking | Copy in Link Me pop-up (I consent / I don't consent, profile URL on decline, `linkedin_consent`); Legal sign-off and Privacy Notice URL (`ONE_WSO2_AMPLIFY_PRIVACY_NOTICE_URL`) pending | Requirements map K3; plan M0c |

### R4a: Record reposts (phase 1)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F4.1 | Repost through Amplify (`REPOST`) with idempotency key | Built | `amplify-domain` sharing; `ShareDialog.tsx`; `06e94f3a` |
| F4.2 | Repost with personal commentary through Amplify (`REPOST_COMMENTARY`) | Built. In-app, so no Community API needed | `ShareDialog.tsx`, 3000-character cap; `f26c9912`, `37528e0` |
| F4.3 | Engagement recording: one repost per campaign per employee, duplicate publish settles | Built | `sharing.engagement`; `32237bb`, `db4d9c5` |
| F4.4 | Read every LinkedIn copy-link form for post URLs | Built | `linkedinPost.ts`; `45657d03` |

### R4b: Reactions, comments and native reposts (phase 4)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F4.5 | Reactions and comments sync through LinkedIn Community Management | Planned, blocked on LinkedIn approval | Requirements map R4 |
| F4.6 | Native LinkedIn reposts, including ones made outside Amplify | Planned, blocked on LinkedIn approval | Requirements map R4, Q1 |

### R5: Own posts (phase 3)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F5.1 | External share claim: any HTTPS evidence URL with certify checkbox | Built, ahead of phase 3 | `external_sharing`; `/external-shares`, `/me/external-shares` |
| F5.2 | PO approve and reject external shares | Built, ahead of phase 3 | `/po/external-shares/{id}/approve` and `/reject` |
| F5.3 | PO marks an approved post as amplified (`OWN_POST_AMPLIFIED` top-up) | Built, ahead of phase 3 | `/po/external-shares/{id}/amplified` |
| F5.4 | My Campaign page: employee submits an own post | Planned, no UI route | No My Campaign route in `one-wso2` |

### R6: Automatic scoring (phase 1)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F6.1 | Points ledger with `HELD` status and point rules | Built | `amplify-domain` scoring; V006, V014; `/po/point-rules` |
| F6.2 | Once per action per post per person: unique keys, `ON CONFLICT DO NOTHING` | Built | Scoring ledger reference; requirements map R6 |
| F6.3 | Scheduled sweeps award points and reconcile | Built | `amplify-jobs` sweeps; scheduler sync |
| F6.4 | Every pilot point value seeded | Built | V014, S006; `3992be5` |

### R7: PO edits (phase 3)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F7.1 | PO adjusts a member's points with a reason | Built, ahead of phase 3 | `/po/points/adjustments` |
| F7.2 | PO reverses a ledger entry with a reason | Built, ahead of phase 3 | `/po/points/{reference}/reverse` |
| F7.3 | PO edits point rule values | Built, ahead of phase 3 | `/po/point-rules` |
| F7.4 | PO screens for adjust, reverse and remove | Planned, no UI | No adjust screen in `one-wso2` |
| F7.5 | Remove invalid activity as its own action | Open: decide whether reverse covers it | Requirements map R7 (A5) |

### R8: Coins (phase 2)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F8.1 | Coin issuer into the wso2-coin programme | Planned | L2 open items 3 and 4 |
| F8.2 | `PAID` settlement status and points-to-Coins ratio | Planned, columns designed | Data model settlement status |
| F8.3 | Engagement verification before any Coin issue | Planned, partly designed | Requirements map C6 |
| F8.4 | Ledger reference encoding aligned with wso2-coin rules | Planned | Requirements map, later phases |

### R9: Employees see points and history (phase 2)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F9.1 | `/me/points`: total, rank and monthly history | Built (API), ahead of phase 2 | `openapi` `/me/points`; `/team/{employeeId}/history` |
| F9.2 | Employee points and Coins screen in One WSO2 | Planned, no UI route | `one-wso2` Amplify routes |
| F9.3 | Own shares list | Built (API), UI not found | `/me/shares` |
| F9.4 | Coin value shown in the UI | Planned | Requirements map R9 |

### R10: Leaderboards (phase 1)

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| F10.1 | Company top three this month, cached 2 hours (ADR-037) | Built | `/leaderboard/top`; `TopAmplifiersPodium.tsx`; `499bfd0`, `ff4d031` |
| F10.2 | Personal standing: own rank and gap | Built | `/leaderboard/people`; "My position" in `LeaderboardPanels` |
| F10.3 | My Team leaderboard from the people directory | Built, gated on people-app deploy | `/team`, `/leaderboard/groups`; `37a6eba`; people-ops-suite `8d39e2df` |
| F10.4 | Open leaderboards by company, BU and team, with group boards (ADR-035) | Built | `/leaderboard/groups`; `4746d57`, `68a22a3` |

### R11: Reports (phase 1)

PO confirmed R11 is phase 1. The SLT reports and reach features stay phase 2, because they need data and roles that do not exist yet.

| Key | Phase | Feature | Status | Evidence |
| --- | --- | --- | --- | --- |
| F11.1 | 1 | Dashboards for amplify roles: At A Glance, Operations, Post Performance, Participation, Scorecard | Built | `/dashboards/*`; `one-wso2` `pages/dashboards`; `802ddbf`, `d453eb74` |
| F11.2 | 1 | Post popup and person popup | Built | `/dashboards/people/{employeeId}`; `7644e130` |
| F11.3 | 1 | Raw-data CSV export | Built. Carries reposter emails (threat model gap) | `/dashboards/export`; `ce42472` |
| F11.4 | 2 | SLT reports: participation, reach, points by team, location and post | Planned | `amplify_readonly` role exists |
| F11.5 | 2 | Reach from the analytics API (`engagement_metric`) | Planned, future | Requirements map R11 |

### PLAT: Platform foundations (under SDLC 4, phase 1)

Not a PO requirement. This is the work every requirement item stands on. It sits under Stage 4 Development, not Stage 3, since it is not part of the product backlog.

| Key | Feature | Status | Evidence |
| --- | --- | --- | --- |
| FP1 | Domain model in code: modules, value objects, events, LinkedIn and Chat anti-corruption layers | Built | `amplify-domain`, `amplify-common`; `ac060e6` |
| FP2 | Database: migrations V001 to V014, maintenance functions, seeds, migrate runner with VERIFY_FULL TLS | Built | `amplify-database`; `a8d92ee`, `0a52b31`, `1e62e93`, `429c11d` |
| FP3 | API platform: OpenAPI contract, idempotency, security headers, JWKS cache, contract tests | Built | `openapi.yaml`; `c78e02d` |
| FP4 | Jobs service and scheduler: run loop, handlers, sweeps and breakers | Built | `amplify-jobs`, `amplify-scheduler`; `053d6a7`, `ef50889` |
| FP5 | Resilience: DB breaker, breaker metrics, log hygiene check, DB-down recovery | Built | `4162b99`, `cb5f4af` |
| FP6 | Local stack: Docker Compose, end-to-end run, Chat, people and Novera stubs, dev proxy, LinkedIn mock | Built | `compose.yaml`; `local/*`; `b8947c4`, `37a6eba`, `fedb6e2` |
| FP7 | Choreo and OpenChoreo descriptors, clean-checkout Docker builds | Built, not deployed | `.choreo/component.yaml`, `workload.yaml`; `b8947c4` |
| FP8 | Quality: deep reviews of four modules, R-13 transaction gate, load test, p95 fix | Built | `2d2a02f`, `e0eb224`, `d9dff7e`, `3258bfd`, `343e46a`, `ce35e10` |
| FP9 | Security documents: threat model v0.3, deployment checklist, token and OAuth notes | Built as markdown, stale, `.docx` not generated | `1e30782` |
| FP10 | Runbooks, test guide, 37 ADRs and module READMEs | Built | `1e30782`, `51aef1b`, `1a209f1` |
| FP11 | Automatic submodule pointer bump (rolling PR) | Built | `bump-submodule-pointers.yml`; `9776cd7` |
| FP12 | People-app service-client access to the employee directory | Built on the fork, upstream PR not open | people-ops-suite `8d39e2df`, `81a2b73e` |

**Totals:** 9 stages, 25 activity tasks, 12 requirement items, 1 platform item, 61 features (49 under requirements, 12 under platform). 108 issues were created on 24 Oct. The phase restructure adds 26 (4 phase issues, 21 stage copies for phases 2 to 4, and R11b), for 134 in all.

---

## 6. Phase decisions

Phases follow the screenshot, with the PO's confirmations of 24 Oct applied.

| Item | Screenshot | PO decision | Result |
| --- | --- | --- | --- |
| R2 Chat share | Phase 1 | Phase 1, and the channel is now Novera, not the Club chat space mentioned in the requirements document. | R2 retitled "through Novera". F2.2 (Novera) is the main feature. F2.1 becomes "keep the Club webhook path off by default, for dev work" (PO decision) |
| R5 Own posts | Phase 3 | Phase 3 | Unchanged. F5.1 to F5.3 are built ahead of phase 3 |
| R7 PO edits | Phase 3 | Phase 3 | Unchanged. F7.1 to F7.3 are built ahead of phase 3 |
| R6 Automatic scoring | Phase 3 | Phase 1 (PO updated the chart) | R6 and F6.1 to F6.4 are phase 1 and plain "Built". The phase 1 leaderboard (R10) ranks by points, so this closes the earlier conflict |
| R11 Reports | Phase 2 | Phase 1 | R11 and F11.1 to F11.3 are phase 1 and plain "Built". F11.4 and F11.5 stay phase 2 |
| Club webhook | Not in the table | Keep it off, useful for dev work | F2.1 keeps the code, off by default |

Still open:

| Item | Issue |
| --- | --- |
| R9 Points and Coins history is phase 2 | F9.1 (`/me/points`) is built, so it is ahead of its phase. No decision needed unless the pilot should show points |
| R4 Reposts with commentary | F4.2 (in-app commentary repost) stays phase 1 under R4a. Confirm the phase 4 row means only the native and Community API variants |

Items that are built and still tagged for a later phase appear as "built, ahead of phase N". The phase tag does not move to match the code.

---

## 7. Open decisions

1. **Where do requirement items sit?** Stage 3 (this map) or Stage 4. One line in the script. 
2. **R4 reposts with commentary.** Confirm the phase 4 row covers only the native and Community API variants.
3. **Run the restructure.** The 108 issues exist (#1687 to #1794). `scripts/restructure-epic-phases.sh --apply` adds the phase layer and moves items under it, and assigns the new issues to BechtelCanDoIt (override with `ASSIGNEE=name`). It is idempotent.

Decided on 24 Oct: R5 phase 3, R7 phase 3, R11 phase 1, R2 phase 1 through Novera, R6 phase 1, Club webhook stays off for dev work, platform work is included, owner is BechtelCanDoIt.
