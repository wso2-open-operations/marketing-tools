# WSO2 Amplify — Pilot Readiness (plan M12)

Pilot operations for the 90-day pilot that starts at go-live (31 Oct 2026) and ends 29 Jan 2027. Written 2026-10-17. Complements the [SDLC walk](sdlc-checklist-walk.md) and the [runbook suite](../runbooks/operations.md).

Owner: Developer (technical). Comms owner: PO team.

## 1. LinkedIn version watch

The LinkedIn Marketing API is versioned by a `YYYYMM` string sent on every call in the **`LinkedIn-Version`** header. Amplify pins **`202610`** (plan M8b "Config per environment ... API version `202610`"). A version is supported for a limited window and then stops being accepted; a call on a sunset version fails.

**Policy:** bump the pinned version **quarterly**, and at least **60 days before the pinned version sunsets**, whichever comes first. Do not wait for a failure.

**How the version is set (config as data, not code):**

- amplify-jobs reads the version from config (the `linkedin*` keys in `amplify-jobs/config.bal`; Choreo: `LINKEDIN_VERSION` config/secret, local: `BAL_CONFIG_VAR_LINKEDINVERSION`).
- The dev/local **mock LinkedIn** must accept the same version string, so a local bump is validated without the real API.
- No code change is needed for a bump: change the config value per environment and redeploy amplify-jobs.

**Procedure (planned, before `202610` sunsets):**

1. **Watch.** Check the LinkedIn "Recent Marketing API Changes" page each month for the sunset month of the pinned version and for the new version string. The plan records the pin; the owner checks the page on the first working day of each month.
2. **Pick the target version.** Choose the newest stable `YYYYMM` that is not the current one.
3. **Dev first.** Set `LINKEDIN_VERSION` to the target in dev (Choreo amplify-jobs config) and in `local/.env` for the mock. Redeploy amplify-jobs.
4. **Smoke test** in dev: connect (mock), share a campaign, confirm `POST /rest/posts` succeeds and `published_at` is set. Against the real non-prod LinkedIn app, run the [M11 real-LinkedIn smoke test](phase1-planned-todos.md) with a test account.
5. **Prod.** Set `LINKEDIN_VERSION` in prod, redeploy, and repeat step 4 with one real share.
6. **Record.** Update the plan's "API version" line and this section with the old version, the new version, and the date.

**Risk if it slips:** a sunset version makes every share fail with a 4xx (`PROVIDER_REJECTED`), which surfaces in the PO dashboard "Share health" tile and the run log. No data is lost (shares stay retryable), but the pilot cannot post until the bump lands. This is a **calendar item, not a build item.**

**Open:** confirm the exact sunset date of `202610` against LinkedIn's versioning policy (not published as a fixed table); the 60-day rule is the safety margin.

## 2. Pilot group in Asgardeo + preview flag

**Pilot group in Asgardeo (non-prod and prod orgs):**

1. Asgardeo › User Management › Groups: create a **`amplify-pilot`** group (in addition to the `amplify_po` / `amplify_marketing` / `amplify_slt` / `amplify_admin` role groups).
2. Add the **15–25 Amplify Champions** at launch; grow the group during the pilot. Champions are employees (no role group) plus a few Marketing/PO/Admin members.
3. Non-prod org gets test users only, with no linkage to prod (ADR-008).

**Preview flag (One WSO2 UI):** the Amplify module is hidden behind `isPreviewEnabled("amplify")` in One WSO2 `webapp/src/config/previewFeatures.ts`; its routes in `App.tsx` are gated by the same flag (plan M7). So only people with the flag on see the Amplify rail.

- Roll-out options: (a) enable the flag per-user for the pilot group via One WSO2's preview-feature mechanism, or (b) enable it org-wide but rely on the Amplify rail being visible only after the user visits. **Decision needed:** confirm which mechanism One WSO2 supports for a group-scoped preview; the recommended path is group-scoped so non-pilot employees see nothing.
- Fail-closed: `useAmplifyGate` → `GET /me`; while resolving, features are hidden (plan M7).

**Owner:** One WSO2 UI owner (preview flag mechanism) + Developer (Asgardeo group). **Status: open** (both are console/UI work).

## 3. Pilot comms (WSO2 Club space)

Announcements go to the **WSO2 Club Group** Google Chat space (ADR-007, plan M6a) via the incoming webhook, using the `chatSpace = club` config in prod.

**Comms plan:**

| When | Message | Channel | Owner |
| --- | --- | --- | --- |
| T-3 working days | "Amplify pilot starts <date>: connect LinkedIn, repost WSO2 campaigns, earn points." Link the share page. | Club space | PO |
| Go-live day | First campaign announced automatically by Amplify (the webhook card). Optional pinned intro card from the team. | Club space (Amplify card) | System / PO |
| Weekly during pilot | Leaderboard callout (company top N) + one featured campaign, posted by the team (not automated in phase 1). | Club space | PO |
| Reconnect reminder | Employees in the reminder window see the reconnect banner in the UI; there is no automated chat reminder in phase 1 (plan M6, ADR-025 item 13). | One WSO2 UI | System |

**Note:** the pilot does **not** add ad-hoc posting from Amplify; the only automated posts are campaign announcement cards. Any human-authored pilot comms are posted by the PO team in the Club space directly.

## 4. Feedback channel

- **Primary:** a dedicated **Google Chat space "Amplify pilot feedback"** (or a topic in the Club space) where Champions post issues and ideas. Owner: PO.
- **Bug/feature capture:** issues raised from feedback are recorded as GitHub issues in the Amplify repo, labelled `pilot-feedback`, triaged by Developer into the [phase 2 backlog](#6-phase-1-retro-and-phase-2-entry-criteria).
- **Direct channel:** the runbook suite ([operations.md](../runbooks/operations.md)) and the data-deletion path ([data-deletion-interim.md](../runbooks/data-deletion-interim.md)) cover operational incidents and privacy requests separately from product feedback.
- **Cadence:** PO reviews feedback weekly; a summary goes back to the Champions so they see their input land (matching "credit the team" comms).

## 5. Success metrics

Four metrics for the pilot. Compute from the Amplify schema (queries below run as `amplify_readonly`; PO can also read the dashboard tiles).

| Metric | Definition | Source | Pilot target (to confirm with PO) |
| --- | --- | --- | --- |
| **Connected employees** | Employees with an **ACTIVE** LinkedIn connection | `connection.member_connection_v` | ≥ 60% of the pilot group by week 4 |
| **Shares per campaign** | Published in-app reposts per open campaign | `sharing.share_request_v` (`PUBLISHED`), grouped by campaign | ≥ 40% of connected employees share each weekly campaign |
| **External shares reviewed within SLA** | PO decisions on external shares within `po.review_sla_hours` (48) | `external_sharing.external_share` (`decided_at - created_at`) | ≥ 90% within 48 h |
| **Announcement delivery rate** | Campaign cards SENT vs (SENT + FAILED) | `announcement.announcement_v` | ≥ 98% |

**Queries**

```sql
-- Connected employees (ACTIVE)
SELECT count(*) FROM connection.member_connection_v WHERE provider = 'linkedin' AND status = 'ACTIVE';

-- Shares per campaign (published, current window)
SELECT campaign_id, count(*) AS reposts
FROM sharing.share_request_v
WHERE status = 'PUBLISHED'
GROUP BY campaign_id ORDER BY reposts DESC;

-- External shares reviewed within SLA
SELECT
  count(*) FILTER (WHERE decided_at - created_at <= interval '48 hours') AS within_sla,
  count(*) FILTER (WHERE decided_at IS NOT NULL)                        AS decided,
  count(*)                                                              AS total
FROM external_sharing.external_share;

-- Announcement delivery rate
SELECT
  count(*) FILTER (WHERE sent_at IS NOT NULL)  AS sent,
  count(*) FILTER (WHERE failed_at IS NOT NULL) AS failed
FROM announcement.announcement;
```

These also feed the PO dashboard tiles 2–7 ([po-dashboard.md](../../architecture/solution/Phase%201/po-dashboard.md)). Targets are proposals; PO confirms the numbers.

## 6. Phase 1 retro and phase 2 entry criteria

**Retro:** PO + team run a written retro at pilot end (or at the 29 Jan 2027 exception review, whichever is first): what worked, what the four metrics showed, top friction from the feedback channel, and the defects deferred (see the M11 open items). Output: a short retro note plus a groomed phase 2 backlog.

**Phase 2 entry criteria (all three must be true before phase 2 starts):**

| Criterion | Owner | Why it gates phase 2 |
| --- | --- | --- |
| **Community Management approval** | Developer / PO | Share verification (pre-coin) and the share-metrics pass need `r_member_postAnalytics` and the Community Management product (ADR-018, [deletion/analytics research](../research/2026-10-16-linkedin-deletion-and-analytics.md)). Points stay `HELD` until verification can run; nothing becomes a Coin until then. |
| **Coin contract** | Developer / PO / Coin team | Points → Coins needs the ratio, the `reference`/`source` on the Coin master/transfer, and the email → wallet mapping (L2 open items; ADR-018 keeps points `HELD` meanwhile). The ledger's settlement columns and the phase-2 `CHECK` drop are already designed in. |
| **HR Entity access** | Developer / PO | SLT reports (points by team/location) need HR Entity GraphQL (`org_dim`); phase 1 deliberately stores no HR data (ADR-009). |

**Also required to close the pilot's open items (not strictly phase 2 gates):**

- Data-deletion **exception closed** (deletion path built) — Security + Legal; target before phase 2 Coin issue (ADR-016).
- Ledger reference encoding revisited against the wso2-coin rules (audit C1).
- Real One WSO2 **roster endpoint** found for My Team (plan D13), replacing the assumed contract (ADR-024 item 5).
