# WSO2 Amplify — Phase 1 PO Dashboard

Status: Draft v1 (2026-10-16)
Closes: audit B6 ([requirements-map.md](requirements-map.md)) · Decision: [ADR-013](../../decisions/ADR-013-po-dashboard-phase1.md) (ships in phase 1)
Data: [phase1-data-model.md](phase1-data-model.md) · Plan: [M5 S4 `GET /po/dashboard`, M7 PO Review](../../../docs/requirements/phase1-planned-todos.md)

## What it's for

The PO team runs the pilot day to day. The dashboard answers four questions on one screen: **what's waiting for me, is the pilot getting used, which posts are working, and what changed in the ledger.** It's an operations view, not a report. SLT reports (participation, reach, points by team and location) stay in phase 2 behind `amplify_slt` and the read-only DB user.

Who: `amplify_po` only. Where: PO Review › Dashboard tab in One WSO2.

## Tiles

| # | Tile | Shows | Data source (schema.table) | Notes |
| --- | --- | --- | --- | --- |
| 1 | **Review queue** | Pending external shares: count, oldest age, count older than the review SLA | `external_sharing.external_share` `WHERE decision IS NULL` (index `(created_at) WHERE decision IS NULL`) | Click → PO Review queue. SLA from `po.review_sla_hours` (default 48) |
| 2 | **Review throughput** | Approved, rejected, amplified this calendar month (UTC); median hours to decision | `external_sharing.external_share` (`decided_at >=` the 1st of the month) | Feeds the "reviewed within SLA" success metric (M12) |
| 3 | **Action required** | Ledger rows with `status IS NULL` | `scoring.points_ledger` (index `(created_at) WHERE status IS NULL`) | Click → list to clear. Usually 0 in phase 1 (verification is a future phase, ADR-018) |
| 4 | **Points this period** | Points awarded in the current month and all time, split by action (`REPOST`, `REPOST_COMMENTARY`, `SHARE*`, `OWN_POST`, `REACTION`, `COMMENT`, `CHALLENGE_ENTRY`, `CHALLENGE_WINNER`, `OWN_POST_AMPLIFIED`, `ADJUSTMENT`, `REVERSAL`) | Totals: `recognition.employee_points_monthly`. Split: `scoring.points_ledger` grouped by `action`, `source_type` for the month | Points only, no Coin value (A11) |
| 5 | **Participation** | Connected employees (ACTIVE / EXPIRING / NEEDS_RECONNECT), employees with any points, employees active in the last 30 days | `connection.member_connection_v`; `recognition.standing` (`period_key = 'ALL'`, `last_activity_at`) | Counts only. The UI may show a rate against One WSO2 headcount (C8); Amplify doesn't store headcount |
| 6 | **Campaigns** | Open and recently closed campaigns (last 30 days): title, priority, window, reposters, approved external shares, points, announcement status | `campaign.campaign_v` + `recognition.campaign_participation` + `announcement.announcement` | Sorted priority first, then newest. Click → campaign detail |
| 7 | **Share health** | Shares queued, published, failed this calendar month (UTC); failures by `failure_reason` | `sharing.share_request_v` | A spike in `NEEDS_RECONNECT` means a reminder is due |
| 8 | **Recent corrections** | Last 10 adjustments and reversals: who, whom, points, reason, when | `scoring.points_ledger` `WHERE source_type IN ('ADJUSTMENT','REVERSAL')` | Every row also sits in `audit.audit_log` |

Not on the dashboard (and why): reach and impressions (need analytics access, A13, future); breakdowns by team or location (SLT reports, phase 2); Coin value (phase 2); per-person leaderboards (on the Team page).

## Scorecard and the other boards (ADR-036)

Built as `GET /dashboards/{operations,campaigns,participation,glance,scorecard}` for every `amplify_*` role (not plain employees). This page's PO dashboard (`GET /po/dashboard`) stays PO only. The scorecard is a second view for PO, Marketing, SLT and Admin: how participation is tracking against targets. It reports **only what Amplify recorded in its own database**: reposts, shares, connections, points and Chat card status. Reach, impressions and anything LinkedIn holds stay out until Community Management is approved (ADR-018).

| Measure | Source | Target configurable (env `BAL_CONFIG_VAR_<NAME>`, default in code) |
| --- | --- | --- |
| Employees connected, % of headcount | `connection.member_connection_v` (not `REMOVED`) over `GET /headcount` | `scorecardTargetConnectedPct` (25) |
| Connections expired, % of connected | `member_connection_v` `NEEDS_RECONNECT` where `access_expires_at < now()` | `scorecardMaxExpiredPct` (5, a ceiling) |
| Share success rate | `sharing.share_request_v` published over published + failed, this calendar month (UTC) | `scorecardTargetShareSuccessPct` (98) |
| Chat cards delivered | `announcement.announcement_v` `SENT` over campaigns opened in the window; `FAILED` listed by name, retries shown from `messaging.outbox.attempts` | none (every post) |
| Priority posts reaching X% of connected | `recognition.campaign_participation.reposters` over connected, where `campaign_v.is_priority` | `scorecardTargetPriorityReachPct` (25) |
| Active employees, last 30 days | `recognition.standing.last_activity_at` | `scorecardTargetActive30d` (100) |
| Reposts this month | `sharing.engagement` `occurred_at`, `REPOST` / `REPOST_COMMENTARY`, since the 1st (UTC) | `scorecardTargetRepostsPerMonth` (600) |

Status is On track when the measure meets its target, Watch when it doesn't. The seeded values are starting lines, not agreed targets. Chat delivery has no reminder or manual retry here: failed cards retry through the outbox with backoff (ADR-025), and only a card that used all 8 attempts needs the admin retry (ADR-024).

## Performance and caching

At pilot volume (830 employees, 10–30 campaigns a month) every tile is a small indexed aggregate. `amplify-api` runs the eight queries in one read-only transaction, returns `Cache-Control: private, max-age=60`, and caches the response in process for 60 seconds. Target p95 < 300 ms. If tile 4's month scan of `points_ledger` gets slow later, add an index on `(created_at)`; it isn't needed for the pilot.

All reads use `amplify_api`'s existing `select` grants. No new tables.

## `GET /po/dashboard`

Role `amplify_po` (403 otherwise). Query: `?month=2026-10` (default: current month, UTC). `asOf` is the server time; each tile is computed in the same transaction, so tiles agree with each other.

```jsonc
{
  "asOf": "2026-10-30T09:15:00Z",
  "month": "2026-10",
  "reviewQueue": {
    "pending": 7,
    "oldestPendingAt": "2026-10-28T08:01:00Z",
    "overSla": 2,
    "slaHours": 48
  },
  "reviewThroughput": {
    "windowDays": 7,
    "approved": 21, "rejected": 3, "amplified": 2,
    "medianHoursToDecision": 9.5          // null when nothing was decided
  },
  "actionRequired": { "count": 0 },
  "points": {
    "monthTotal": 1840,
    "allTimeTotal": 1840,
    "byAction": [                         // every enum value present, 0 when none
      { "action": "REPOST", "points": 610, "rows": 122 },
      { "action": "REPOST_COMMENTARY", "points": 780, "rows": 65 },
      { "action": "SHARE", "points": 0, "rows": 0 },
      { "action": "SHARE_COMMENTARY", "points": 0, "rows": 0 },
      { "action": "OWN_POST", "points": 400, "rows": 16 },
      { "action": "OWN_POST_AMPLIFIED", "points": 60, "rows": 2 },
      { "action": "ADJUSTMENT", "points": 10, "rows": 1 },
      { "action": "REVERSAL", "points": -20, "rows": 1 }
    ]
  },
  "participation": {
    "connections": { "active": 140, "expiring": 6, "needsReconnect": 4 },
    "employeesWithPoints": 151,
    "activeLast30Days": 133
  },
  "campaigns": [
    {
      "campaignId": "0192…", "title": "WSO2 at KubeCon", "isPriority": true,
      "status": "OPEN", "opensAt": "2026-10-20T00:00:00Z", "closesAt": "2026-11-19T00:00:00Z",
      "reposters": 48, "externalSharesApproved": 3, "points": 520,
      "announcement": "SENT"              // QUEUED | SENT | FAILED
    }
  ],
  "shareHealth": {
    "windowDays": 7,
    "queued": 2, "published": 187, "failed": 5,
    "failedByReason": { "NEEDS_RECONNECT": 4, "PROVIDER_REJECTED": 1, "RETRIES_EXHAUSTED": 0 }
  },
  "recentCorrections": [
    {
      "reference": "ADJ-0192…", "type": "ADJUSTMENT",   // ADJUSTMENT | REVERSAL
      "employeeId": "e5f6…", "email": "sam@wso2.com",
      "points": 10, "reason": "Missed share during outage",
      "actorId": "po1…", "createdAt": "2026-10-29T11:20:00Z"
    }
  ]
}
```

Rules: counts are integers ≥ 0; `points` can be negative only on `REVERSAL` and `ADJUSTMENT`; `campaigns` holds at most 20 rows; `recentCorrections` at most 10. Errors use the API's problem-details shape.

## Settings

New key, seeded with the others in `config.app_setting`: `po.review_sla_hours = 48`. Editable by `amplify_admin` (PO can ask for a change).

## Tests

- Fixture with known rows → every tile matches hand-computed numbers.
- Non-PO roles get 403; the call is audited as a read only if PO wants that (not by default).
- Empty database → every tile returns zeros or empty lists, never nulls (except `medianHoursToDecision`).
