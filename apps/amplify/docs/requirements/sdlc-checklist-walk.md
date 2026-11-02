# WSO2 Amplify — SDLC Checklist Walk (plan M12)

Walk of the nine-stage [WSO2 Digital SDLC](https://docs.google.com/document/d/14euRO9IAYSb76StcBIokOqV1IX9RIlHy-htmGjtm5vQ/edit) for the Amplify phase 1 pilot. Written 2026-10-17; re-walked 2026-10-19 and **2026-10-26**. The [26 Oct re-walk](#re-walk-2026-10-26) at the end is the current one and supersedes the earlier findings tables where they differ.

This is an **audit-mode** walk: for each stage it records the outputs that must exist, whether the closing approval is on record, and who owns the gap. It does not penalize stages that have not started. Where an approval may exist undocumented, the entry says so and asks for the email.

Legend: **Done** = outputs exist and the closing approval is on record · **Output done, gate pending** = the work exists but the email/+1 has not been recorded · **Not started** = later stage.

Owner column: `Developement Team Lead` = technical owner; `Lead` = WSO2 Digital lead; `Sec` = security team; `Arch` = architecture group; `PO` = PO team; `Admin` = a Choreo/Asgardeo org admin.

## Summary

| # | Stage | Outputs | Closing gate | Status | Owner of next action |
| --- | --- | --- | --- | --- | --- |
| 1 | Discovery and Problem Definition | Problem statement, as-is, value, requirements | Discovery email to ops | Output done, gate pending | Lead |
| 2 | Solution Architecture and Technical Design | SAD, OpenAPI, data model, integration diagram | Architecture review + email (Leads +1) | Output done, gate pending | Arch / Dev Lead |
| 3 | Requirement Breakdown and Planning | Backlog, milestones, estimation | Stakeholder planning meeting + email | Output done (estimation thin), gate pending | Lead / PO |
| 4 | Development | Source, tests, code review, dev deploy | 2 PR approvals per PR | Output done; PR approvals + Choreo dev deploy pending | Dev Lead / reviewer |
| 5 | Security Review | Security Checklist, Threat Model | Security team +1 (`security email`) | **Output produced this milestone**, +1 pending | Sec / Dev Lead |
| 6 | Deployment and Release Management | dev/stage deploys, config/secrets, release note, rollback plan | Production deployment approval email | Not started | Dev Lead / Admin |
| 7 | User Acceptance Testing | UAT results on staging | UAT sign-off email (+1) | Not started | PO |
| 8 | Go-Live | Live system, comms, Go-Live report | Announcement email + chat space | Not started | Lead |
| 9 | Post-Production Support | Monitoring, feedback loop, backlog | (continuous) | Not started | Dev Lead |

No **Skipped gate** (High) findings: nothing is in stage or prod yet, so no later stage is running ahead of an earlier approval. The one gate that must clear before any production deploy is **Stage 5 (security +1)**.

---

## Stage 1 · Discovery and Problem Definition

**Outputs**

- Problem statement and as-is process: the [PO Team requirements doc](0%20PO%20Team%20_%20WSO2%20Amplify%20-%20Tracking%20Platform%20Requirements.md), mapped and ID'd in [requirements-map.md](../../architecture/solution/Phase%201/requirements-map.md) (R1–R11, T1–T4, K1–K4, P1–P5, Q1–Q6).
- Value definition (time/cost/risk/experience): stated, not yet quantified per requirement.
- Feasibility (who uses it, how often, why not an alternative): the 2026-10-15 design review with Lead and the M0b/M0c decisions.

**Gate:** discovery email to `dev team email address` plus lead and stakeholder groups; reply commits to build or proposes a workaround.

**Status:** output done; gate email **not on record in this repo**. Owner: Lead. Action: confirm the discovery email exists or send it; the requirements doc predates the repo.

## Stage 2 · Solution Architecture and Technical Design

**Outputs**

- Solution Architecture Document: [phase1-solution-architecture.md](../../architecture/solution/Phase%201/phase1-solution-architecture.md) (Mermaid logical view), plus [amplify-L0-solution.md](../../architecture/solution/High%20Level/amplify-L0-solution.md) and [amplify-L1-solution.md](../../architecture/solution/High%20Level/amplify-L1-solution.md).
- API specs: [amplify-api/openapi.yaml](../../amplify-api/openapi.yaml), [amplify-jobs/openapi.yaml](../../amplify-jobs/openapi.yaml).
- Data models: [phase1-data-model.md](../../architecture/solution/Phase%201/phase1-data-model.md), [phase1-domains.md](../../architecture/solution/Phase%201/phase1-domains.md).
- Integration diagram: the architecture diagram plus the Choreo L2 ([Phase X - Later](../../architecture/solution/BrainStorms/amplify-L2-Choreo-Solution.md)).
- High-Level Technical Design: the ADRs ([architecture/decisions](../../architecture/decisions/README.md), ADR-001–028).
- EA conformance: [reviewed 2026-10-26](../../architecture/reviews/2026-10-26-ea-conformance.md) against the current design (it replaces the 19 Oct review). 12 findings, none fixed since 19 Oct. The two High ones are the missing egress gateway decision and the missing tracing design.

**Gate:** architecture review meeting plus email approval to `architecture team email address` (Leads +1).

**Status:** output done; **architecture-group approval not on record**. The SAD doubles as the basis for the Stage 5 threat model (per the SDLC), so this gate should clear before the security review is scheduled. Owner: Arch (Leads +1). Action: send the SAD for the architecture-group +1.

## Stage 3 · Requirement Breakdown and Planning

**Outputs**

- Product backlog / user stories / acceptance criteria: [phase1-planned-todos.md](phase1-planned-todos.md) (milestones M1–M12, each with acceptance-style items).
- Milestones: the [dated milestones to go-live](phase1-planned-todos.md#dated-milestones-to-go-live-31-oct-2026) work back from 31 Oct 2026.
- Estimation sheet: **thin.** Effort is expressed as day-by-day milestones, not a sized estimation sheet. Finding (**Low**): a sized estimate does not exist.

**Gate:** stakeholder planning meeting plus email.

**Status:** output done (estimation thin); gate email not on record. Owner: Lead / PO. Action: confirm the planning email; PO to answer A2 (must/should per requirement) — see [pilot-readiness.md](pilot-readiness.md).

## Stage 4 · Development

**Outputs**

- Source code: [apps/amplify](../..) (Ballerina services, migrations, descriptors) and the One WSO2 UI module (M7, in `projects/one-wso2`, not this repo).
- Unit/integration tests: `make test-all` (unit, repository/IT on Postgres, adapter against `mock_linkedin`, auth matrix, breaker, rerun safety, load — see M11).
- Code review notes: the repo follows feature→dev→stage→prod branching and a PR template. **Every PR needs 2 approvals.** PR approvals are a GitHub-side control and are not recorded in this repo. Reviews re-run 2026-10-26: [backend](../reviews/2026-10-26-code-review-backend.md), [UI, people-app and po-agent](../reviews/2026-10-26-code-review-ui-people-agents.md), [security](../reviews/2026-10-26-security-review.md), [integration boundaries](../reviews/2026-10-26-integration-boundaries.md) and [project structure](../reviews/2026-10-26-project-structure.md).
- Dev deployment on Choreo: **not done** (console work, M8b).
- Governance: coding standards and PR hygiene per `wso2-digital-coding-standards` / `wso2-engineering-governance`.

**Gate:** 2 mandatory PR approvals per PR (branch protection); no secrets or customer data in prompts.

**Status:** output done; **Choreo dev deployment pending** and PR-approval evidence is external. Owner: Dev Lead (deploy) / reviewer (approvals). Action: run the [choreo-deploy runbook](../runbooks/choreo-deploy.md) for dev; turn on branch protection with a 2-approval rule if not already on.

## Stage 5 · Security Review

**Outputs**

- Security Checklist document: architecture/security/WSO2 Amplify Application Deployment Security Checklist.docx (M10).
- Threat Model document: architecture/security/WSO2 Amplify Threat Model.docx (M10), built on the Stage 2 SAD.
- Token/OAuth specifics: token-and-oauth-notes.md.
- Checklist exception for deferred data deletion: **awaiting security team approval**.

**Gate:** +1 from the security team; route to `security email at wso2.com`.

**Status:** outputs produced in this milestone; **security +1 pending**, and the data-deletion exception still needs sign-off. Owner: Sec / Dev Lead. Actions:

1. Book the threat-model review session; record notes and action items; raise GitHub issues for any open threat; update the risk registry (threat model § risk registry).
2. Move the threat model into Security Review Documents after review.
3. Get the data-deletion checklist exception approved (Security + Legal/Privacy).

**This is the gate that must clear before any production deploy.**

## Stage 6 · Deployment and Release Management

**Outputs (all pending)**

- dev/stage deploys; staging developer testing (entity/backend APIs via Postman; web apps via test cases).
- Collaborative privileges/roles session.
- Connected apps for external integrations: LinkedIn, Google Chat (Choreo connections).
- Choreo pipeline deploy with config maps/secrets/OAuth/DB.
- Release note; rollback plan.
- Stage 7 (UAT) runs inside this stage before the production approval.

**Gate:** production deployment approval email; releases expected at least bi-weekly thereafter.

**Status:** not started (console work). Owner: Dev Lead / Admin. Action: after the security +1, run [choreo-deploy.md](../runbooks/choreo-deploy.md) C–E for dev then prod, and write the rollback plan + release note. The rollback plan must cover DB migration rollback (there is no down-migration; restore from backup — see [operations.md](../runbooks/operations.md) §8).

## Stage 7 · User Acceptance Testing

**Outputs (pending):** captured bugs/improvements from real business users on a staging URL (e.g. `apps-stg.wso2.com`); prioritized fixes; a bug-fix release.

**Gate:** UAT sign-off email (+1).

**Status:** not started. Owner: PO. Note: no staging environment is planned (M8b uses dev + prod); UAT runs on dev with the pilot Champions unless the org requires staging.

## Stage 8 · Go-Live

**Outputs (pending):** live system; no data migration needed (new system); updated portals/docs/KBs; post-deployment monitoring and uptime checks; Go-Live report.

**Gate:** announcement email plus chat space.

**Status:** not started. Owner: Lead. Depends on Stage 6. Comms plan: [pilot-readiness.md](pilot-readiness.md).

## Stage 9 · Post-Production Support and Continuous Improvement

**Outputs (pending):** monitoring of logs/errors/performance (runbook [operations.md](../runbooks/operations.md), [resilience-targets.md](../runbooks/resilience-targets.md)); bug-fix releases; user feedback loop (see [pilot-readiness.md](pilot-readiness.md)); improvement/feature backlog; cost audits.

**Channels:** email and chat (the Club space).

**Status:** not started (begins at go-live). Owner: Dev Lead.

---

## Findings

Ordered by severity. No High findings (no skipped gate: nothing is in stage/prod).

| # | Sev | Stage | Finding | Confidence | Next action |
| --- | --- | --- | --- | --- | --- |
| 1 | Medium | 5 | Security +1 not on record; data-deletion exception awaiting approval | High | Book the review; route to `security email`; get the exception approved |
| 2 | Medium | 2 | Architecture-group +1 not on record | Medium (may exist undocumented) | Send the SAD for the architecture-group +1 |
| 3 | Medium | 6 | No rollback plan before a production deploy is possible | High | Write the rollback plan in Stage 6 (backup-restore based) |
| 4 | Low | 3 | No sized estimation sheet | High | Add a sized estimate, or record that milestones are the estimate |
| 5 | Low | 1, 3 | Discovery and planning emails not in the repo | Medium | Confirm the emails exist or send them |
| 6 | Low | 7 | No staging environment planned | High | Confirm with PO that UAT runs on dev, or add staging |

## Re-walk 2026-10-19

What changed since the first walk: the phase breakdown was updated (phase 1 = register posts, Club Chat share, LinkedIn link, repost tracking, individual and team leaderboards; own posts, scoring rules and PO edits move to phase 3; Coins and reports to phase 2); the phase 1 One WSO2 UI was built; team rosters now come from people-app, which needed a change in people-app itself; the backend moved to marketing-tools `apps/amplify` (ADR-033). Five PRs are open on the forks (one-wso2 #2, people-ops-suite #1, marketing-tools #1, wso2-amplify #4, #5).

**Headline.** Amplify is still at the end of Stage 4 (development done, dev deploy and PR approvals pending) with Stage 5 outputs drafted. The work is well documented: ADRs for every decision, a current threat model (v0.3), runbooks, a local how-to, and 465 passing backend tests plus e2e. Still no skipped gate, because nothing is deployed. The risk is the calendar: go-live is 31 Oct, 12 days out, and Stages 2, 5, 6 and 7 still need approvals and a deploy that haven't started.

| # | Sev | Stage | Finding | Confidence | Next action |
| --- | --- | --- | --- | --- | --- |
| R1 | High | 5–6 | Go-live on 31 Oct needs, in order: architecture +1, security +1 (threat model v0.3 with the new people-app boundary, data-deletion exception), Choreo dev deploy, UAT sign-off, prod approval, rollback plan. None are on record and the Choreo deploy hasn't started. | High | Decide now whether 31 Oct holds; if it does, book the architecture and security reviews this week |
| R2 | Medium | 5 | The SDLC's Stage 5 outputs are the WSO2 **Threat Model** and **Security Checklist** documents. The markdown versions are current; the official `.docx` templates haven't been filled (the threat-model skill needs the two templates). | High | Get the templates; generate the documents for `security email` |
| R3 | Medium | 2 | The architecture changed after the first walk: a new egress to people-app (another team's API, with a change in their access control) and a new repo home. Any architecture approval obtained earlier covered the older design. | Medium (no approval on record either way) | Send the delta (ADR-019 update, ADR-033, threat model B-E3/AMP-R9) with the SAD for the architecture-group +1 |
| R4 | Medium | 3 | The plan doesn't reflect the 2026-10-19 phase breakdown: the MVP definition still lists My Campaign, PO review/adjust and the PO dashboard as phase 1, and M7 (UI) still describes the older screen set, all unchecked. | High | Rewrite the MVP definition and M7 to the breakdown; re-confirm with stakeholders (the Stage 3 gate) |
| R5 | Medium | 3 | Requirement tension: phase 1 ranks leaderboards by points, but "apply points automatically" is listed as phase 3. Repost tracking awards points today. | High | PO to confirm phase 1 keeps automatic points for reposts (the leaderboard needs them) |
| R6 | Medium | 4 | PR size and review: the SDLC asks for 200–400 LOC PRs (up to ~600) with 2 approvals. marketing-tools #1 adds ~107k lines (a move, no logic change). On the forks, one-wso2 #1 (the ~2.4k-line phase 1 UI) and wso2-amplify #3 were merged with **0 reviews**; the open one-wso2 #2 is small (+148). | High | Get 2 approvals on each open PR; the fork merges need a retro review before the code goes upstream. Upstream: split the One WSO2 UI by screen; present the marketing-tools move as a move |
| R7 | Medium | 4 | Two One WSO2 Amplify UIs exist: `feat/amplify-module` (earlier M7 build, older screen set, unmerged) and `feat/amplify-people-data` (phase 1 per the [Phase 1 UX PDF](Phase%201%20-%20WSO2%20Amplify%20User%20Experience.pdf), PR #2). | High | Decide which pieces of `feat/amplify-module` carry into phases 2–3; close or park it so reviewers aren't asked to review both |
| R8 | Medium | 6 | My Team depends on another team's release: the people-app service-client change has to merge and deploy, the client-id claim has to be confirmed on a real gateway token, and the Choreo connection created (choreo-deploy C7). Without it, phase 1 ships with `teamStatus: UNAVAILABLE`. | High | Raise the people-app PR upstream now; agree the deploy date with the people-app team |
| R9 | Medium | 6 | No rollback plan yet (carried from finding 3). | High | Write it with the deploy (backup-restore based; image tag pinning) |
| R10 | Low | 7 | UAT environment still dev-only (carried from finding 6); the 2026-10-19 phase 1 flows (Celebrate, New Post, Current Posts, link, share) are the UAT script. | High | Confirm UAT on dev with the PO; reuse `docs/HowToTestLocally/TestAmplify.md` §6 as the test list |
| R11 | Low | 1, 3 | Discovery and planning emails not in the repo (carried from finding 5). | Medium | Confirm or send |

**Done well since the first walk:** a cross-user data leak (one user's leaderboard shown to another through browser caching) was found and fixed with a regression test; the integration boundary to people-app was reviewed (../reviews/2026-10-26-integration-boundaries.md), no High findings); the people-app change was proven end to end before raising it; tests no longer clash with the local stack.

**Single most valuable next action:** decide whether the 31 Oct go-live holds. If it does, the next gate is the architecture-group +1 on the updated design, owned by the Lead, immediately followed by the security review (`security email`), because every later stage waits on those two.

## Re-walk 2026-10-26

What changed since 19 Oct: about 20 backend feature commits and the One WSO2 dashboards (role-gated boards, person board, CSV export, open leaderboards, headcount), Novera now carries the campaign announcement, and people-app returns the employee's house. The ADRs run to 037. The 24 Oct phase breakdown produced the [epic map](epic-map.md) and 108 issues. The workspace-level architecture, docs and plan moved into this repo. Nothing is in a deployed environment that I can see, and no PR is open upstream yet. I split the fork's work into 133 small PRs for review (the ledger lives with the upstream PR plan outside this repo).

I re-ran the EA, integration-boundary, code, security and project-structure reviews today and replaced the 17 and 19 Oct versions. The threat model (v0.4) and security checklist (v0.2) are regenerated on the official WSO2 `.docx` templates, kept outside this repo for now. They are drafts and need a manual read before they go to `security email`.

**Headline.** Amplify is still at the end of Stage 4 with Stage 5 outputs written but stale. The team has kept the paper trail current: 37 ADRs, five fresh reviews with no High findings in the code or the security pass, and 458 backend tests passing (one stale database test fails, see R15). Still no skipped gate, because nothing is deployed. The risk is the calendar. Go-live is 31 Oct, five days out.

| # | Sev | Stage | Finding | Confidence | Next action |
| --- | --- | --- | --- | --- | --- |
| R12 | High | 5–6 | Go-live on 31 Oct needs, in order: architecture +1, security +1, Choreo dev deploy, UAT sign-off, prod approval, rollback plan. None is on record. Carried from R1. | High | Decide whether 31 Oct holds; if it does, book the architecture and security reviews now |
| R13 | Medium | 5 | Was High before the regeneration. The threat model (v0.3, 19 Oct) and checklist (17 Oct) predated the Novera egress, dashboards, person board, CSV export, open leaderboards and headcount. The [code](../reviews/2026-10-26-code-review-backend.md), [EA](../../architecture/reviews/2026-10-26-ea-conformance.md) and [integration](../reviews/2026-10-26-integration-boundaries.md) reviews each found rows missing. The 26 Oct regeneration covers them (v0.4, 130 threats, 24 registry risks). | High | Read the drafts, close the questions they list as unverified, then send both to `security email` |
| R14 | Medium | 2 | The design moved after the 19 Oct EA review and any earlier architecture +1 covers the older design (carried from R3). There is no ADR for the Novera egress, and the SAD and domains doc trail ADR-034 to ADR-037. | High | Write the Novera egress ADR with the threat model update, decide the egress gateway question, then send the delta for the +1 |
| R15 | Medium | 4 | `make check` is red on `main` (the `posts` property fails the OpenAPI name lint) and one database test is stale (it asserts 6 seed scripts, there are 7). marketing-tools has no CI workflow, so none of the five gates runs per upstream PR. | High | Fix both before the first PR; add a CI workflow that runs the gates |
| R16 | Medium | 4 | The [security review](../reviews/2026-10-26-security-review.md) has no High findings and three Mediums: team history shows the PO's free-text reason and actor id to teammates (F-1), a PO can adjust or reverse their own points (F-3), and the people-app service-client path trusts an unsigned token carrying two claims (F-2). The [UI review](../reviews/2026-10-26-code-review-ui-people-agents.md) adds that the CSV export of names and emails has no recorded sign-off. | High | Fix F-1 and F-3 before the pilot opens; get the export signed off or narrow it to PO and Admin; state F-2 in the people-ops-suite PR |
| R17 | Medium | 4 | PR size and review (carried from R6). The fork merges had 0 reviews, so the upstream PRs are the first real review. The UI diff is 63 files and about 6.8k lines, and the sign-in provider change in it affects every One WSO2 user. | High | Send small PRs as planned; put the auth and side-rail changes in their own PRs |
| R18 | Medium | 6 | Novera is now in the announcement path. It has no idempotency key (a retry can rebroadcast to every employee), Amplify marks the announcement sent on a 202, and Novera is missing from the egress allow-list and the deploy and failure runbooks ([integration review](../reviews/2026-10-26-integration-boundaries.md), N1, N2, N4). | High | Fix N1 and N4 before the first production announcement |
| R19 | Medium | 6 | My Team still depends on another team's release (carried from R8): the people-app change has to merge and deploy, and the token claims need confirming on a real gateway token. | High | Raise the people-app PR upstream first; agree a deploy date |
| R20 | Medium | 6 | No rollback plan on record (carried from R9). | High | Write it with the deploy (backup-restore, image tag pinning) |
| R21 | Low | 8–9 | No tracing design, and neither Novera nor people-app logs the correlation id. The outbox exports no queue depth or age ([EA review](../../architecture/reviews/2026-10-26-ea-conformance.md), G2; integration review N5). | High | Decide the tracing approach before go-live monitoring is set up |
| R22 | Low | 1, 3, 7 | Discovery and planning emails not in the repo, and UAT would run on dev (carried from R10 and R11). | Medium | Confirm the emails; confirm UAT on dev with the PO |

Not re-checked this pass: the plan's MVP wording after the 24 Oct breakdown (R4, R5) and the two parallel One WSO2 UIs (R7).

**Done well since 19 Oct:** 458 backend tests and 188 UI tests pass, type check and lint are clean, the CSV export guards against formula injection, the dev JWT can't be switched on outside local, and the people-app review fixes B1 and B2 from 19 Oct are in. I couldn't find a committed secret in any of the four repos.

**Single most valuable next action:** read the regenerated threat model and checklist, answer the questions they mark as not verified (real gateway token claims, whether people-app is gateway-only, what is deployed), and send both to `security email` with the architecture delta. Every later gate waits on the security +1.
