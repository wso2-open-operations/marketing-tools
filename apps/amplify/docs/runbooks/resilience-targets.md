# WSO2 Amplify — Resilience Targets (plan M12)

Resilience, recovery and detection targets for the Amplify phase 1 pilot (30 Oct 2026 – 29 Jan 2027). Written 2026-10-17. Pairs with [operations.md](operations.md) (the procedures) and WSO2 Amplify Threat Model.docx §6 (dependencies).

Owner: Developer. Escalation: PO team (product impact), WSO2 platform (Choreo/Aiven).

## 1. Service level (pilot)

| | Target |
| --- | --- |
| Availability | **Business-hours best-effort** for the pilot — not a 24×7 SLA. Core read paths (leaderboard, points) and the daily run must work during WSO2 business hours |
| Scope of "up" | The API proxy answering reads; the run pipeline draining the outbox within the schedule |
| Out of scope | Phase 2 SLT reports, coin issue, and any non-LinkedIn channel |

Amplify is **async by design**, so a short outage is tolerated: shares, announcements and scoring queue in the outbox and settle on the next run. The pilot degrades rather than loses work (see §5).

## 2. RPO / RTO / MTTD

Targets; the DB figures depend on the managed-Postgres plan chosen at deploy (must be a plan **with backups** — Hobbyist has none).

| Asset | RPO (max data loss) | RTO (max time to restore) | Notes |
| --- | --- | --- | --- |
| Postgres (Amplify) | **≤ 24 h** (provider backup/PITR granularity — record exact at deploy, B4) | **≤ 4 h** business hours | Restore is manual — [operations.md](operations.md) §8; **restore test pending** |
| Token ciphertext | ≤ backup retention (dropped partitions live in backups until retention ends) | n/a | True max lifetime of a token at rest |
| Scheduler DB | Low value; rebuildable from `PUT /admin/settings` + reconcile | ≤ 1 h | Lost history only; jobs are recreated by `POST /admin/scheduler/sync` |
| Secrets (Choreo) | n/a (source of truth is the secret store) | ≤ 1 h (re-enter secret) | Token keys must include any still-needed `key_id` (see operations §2) |
| **MTTD** (mean time to detect) | **≤ 30 min** in business hours | — | Alerts in [choreo-deploy.md](choreo-deploy.md) §alerts + `/ready` + breaker gauge |

**Honest note:** these are pilot targets, not contractual. RPO/RTO are bounded by the managed-Postgres plan and a manual restore; there is **no backup automation or restore runbook in the repo** (gap — [operations.md](operations.md) §8).

## 3. Health and readiness checks (actual scopes)

| Component | Liveness | Readiness | Gates on |
| --- | --- | --- | --- |
| `amplify-api` | `GET /health` → always `UP` | `GET /ready` | **`database`** (breaker not OPEN **and** `store:probe` ok) **and `jwks`** (breaker not OPEN). `jobs`, `roster`, `linkedinOAuth`, `linkedinApi`, `linkedinIdTokenJwks` are **reported, not fatal** (ADR-024, ADR-028 amendment) |
| `amplify-jobs` | `GET /health` → always `UP` | `GET /ready` | **`database`** (breaker not OPEN **and** `store:probe` ok). `linkedinApi`, `googleChat` breakers and `runInProgress` are **reported, not fatal** (a run defers those rows, ADR-025). Compose healthcheck uses it |
| API proxy | platform health | platform | — |
| Scheduler | external image | — | no Amplify health code |

`/health` and `/ready` are public, GET-only (`amplify-api/modules/auth/matrix.bal:111`) and must **not** be published through the proxy. `/ready` also republishes the `amplify_breaker_state` gauges (ADR-028). Readiness failing (503) means "don't send traffic"; a **JWKS outage returns 503 `DEPENDENCY_UNAVAILABLE`, not 401** (a deliberate choice — an IdP outage must not look like a bad token).

`amplify-jobs` `/ready` (deep review 2026-10-17) mirrors the api's database check and also refreshes the breaker gauges.

**Pool exhaustion fails readiness in both** (deep review round 2, R-13). HikariCP's "Connection is not available" counts as a transient DB error, so once the breaker threshold is reached the DB breaker opens and `/ready` answers 503 DOWN. A replica whose pool has leaked (the Ballerina 2201.13.x transaction race, [ADR-032](../../architecture/decisions/ADR-032-transaction-gate-ballerina-2201-13.md)) gets taken out of rotation instead of failing every call. The Choreo readiness probe for api and jobs must point at `/ready` (console).

## 4. Detection (MTTD sources)

| Signal | Where | What it means |
| --- | --- | --- |
| Outbox `FAILED` count rising | PO dashboard / SQL (`operations.md` §1) | Settlements failing past retries |
| Breaker gauge `OPEN` (`amplify_breaker_state`) | Choreo metrics / `/ready` | A dependency (DB, JWKS, LinkedIn, Chat, people directory) is down |
| `RunReport.failed` > 0, `durationMs` high | run log / `POST /runs` response | Run health |
| `schedulerSync: PENDING` / reconcile give-up | settings response / audit | Scheduler unreachable or refused |
| 5xx rate; scheduler job failures | Choreo observability; `GET {scheduler}/jobs/{id}/history` | Platform/run errors |
| `/ready` → 503 | platform probe | api: DB (incl. pool exhausted) or JWKS down; jobs: DB down |
| Session `idle in transaction` > 30 s | `pg_stat_activity` query ([operations.md](operations.md) §11) | A transaction got past the R-13 gate; V013 ends it at 30 s |

Alerts and thresholds: [choreo-deploy.md](choreo-deploy.md) §alerts.

## 5. Degradation modes (what still works when a dependency is down)

| Dependency down | Effect | Behaviour (by design) |
| --- | --- | --- |
| **LinkedIn** (OAuth or post API) | New shares can't post | Outbox **retries with backoff** (base 30 s → max 3600 s, `maxAttempts=8`); `429` stays queued; `401` revokes → `NEEDS_RECONNECT`. Reads, leaderboard, points still work |
| **Google Chat** | Announcements/cards fail | `400` fails once; `5xx`/`429` retry; a card 404 means the webhook was deleted (rotate). Announcement status `FAILED`, admin retry (`/admin/announcements/{id}/retry`) |
| **Postgres** | Everything | DB breaker opens → API `503`, `/ready` **DOWN**; jobs run errors cleanly, half-open trial closes after restart. No writes lost (nothing committed) |
| **JWKS / Asgardeo** | Login + token verify | Cached keys served; empty cache → **503 `DEPENDENCY_UNAVAILABLE`** (not 401). Breaker + 30 s min-refresh guard |
| **people-app directory** (team rosters) | My Team, Team page team scope | Index cached 24 hours; a failed refresh keeps serving the old teams and asks again on the next call (an outage is never cached for the TTL). Only a cold start with the directory down gives `teamStatus: UNAVAILABLE`; My Team degrades, **never widens** (fails closed to self). Photos and names in the UI fall back to initials ([operations.md](operations.md) §13) |
| **Scheduler** | Scheduling | Settings save still succeeds with `schedulerSync: PENDING`; runs can be triggered manually (`POST {jobs}/runs`); reconcile/`POST /admin/scheduler/sync` converges when it recovers |

Kill switches ([operations.md](operations.md) §10) let a PO stop new shares or announcements during a provider incident without a deploy.

## 6. Backups

| | |
| --- | --- |
| Mechanism | Choreo-managed PostgreSQL 18 on a **plan with backups** ([choreo-deploy.md](choreo-deploy.md) B1) — provider snapshots/PITR |
| Frequency / retention | **Record at deploy (B4)** — depends on the plan |
| Restore test | **Pending** — restore one backup into dev once and record the result ([operations.md](operations.md) §8, plan M3 "Backups") |
| Deletion caveat | Deleted data (and dropped token partitions) live in backups until **backup retention** ends — the true RPO floor for erasure |

**Gap:** no `pg_dump`/restore automation or runbook in the repo; backup config is a console step. Owner: Developer / Aiven.

## 7. End-user messaging when Amplify is down

The UI is the One WSO2 Amplify module; user-visible states (owner: One WSO2 UI owner, to confirm):

| Situation | Message / behaviour |
| --- | --- |
| API `503` / `/ready` DOWN | One WSO2 shows a generic "Amplify is temporarily unavailable, try again shortly" state (not a raw error) |
| Share accepted but not yet posted | "Share queued" — the 202 is honest about async; the share settles on the next run |
| LinkedIn disconnected / expired | Reconnect banner in the UI (no automated chat reminder in phase 1) |
| My Team unavailable | "Team view unavailable right now" (degrades, does not error) |
| Kill switch on | "Sharing/announcements paused" (`FEATURE_DISABLED`) |

**Pilot comms during an incident:** PO team posts to the WSO2 Club space ([pilot-readiness.md](../requirements/pilot-readiness.md) §3) — a short "Amplify posting is paused, your shares are queued and will go out once LinkedIn recovers" note. Use the kill switch to stop new work while the incident is open.
