# Architecture Decision Records

One file per decision, dated, short format (Status, Date, Context, Decision, Consequences, Links). New decisions take the next free number. Cite `ADR-NNN` in docs and the plan, not D-numbers.

## Index

| ADR | Decision | Status |
| --- | --- | --- |
| [ADR-001](ADR-001-ballerina.md) | Ballerina for all phase 1 services | Accepted |
| [ADR-002](ADR-002-postgresql-token-partitions.md) | PostgreSQL, schema per context, daily token partitions | Accepted (extension check open) |
| [ADR-003](ADR-003-worker-shape.md) | `amplify-jobs` HTTP-triggered worker, `amplify-cron` schedules it | Accepted; scheduler part superseded by ADR-026 |
| [ADR-004](ADR-004-api-proxy-cell-edge.md) | API proxy at the cell edge | Accepted |
| [ADR-005](ADR-005-data-model-conventions.md) | Phase 1 data model conventions | Accepted |
| [ADR-006](ADR-006-phase1-scoring-scope.md) | Scoring scope: in-app reposts plus approved external shares | Accepted |
| [ADR-007](ADR-007-choreo-naming.md) | Choreo project and component naming | Accepted |
| [ADR-008](ADR-008-local-identity-asgardeo.md) | Local and dev identity: non-prod Asgardeo | Accepted |
| [ADR-009](ADR-009-people-data-from-one-wso2.md) | People data comes from One WSO2 | Accepted |
| [ADR-010](ADR-010-team-adjust-remove-po.md) | Team page adjust/remove is `amplify_po` only | Accepted |
| [ADR-011](ADR-011-point-rules-po.md) | Point rules maintained by `amplify_po` | Accepted |
| [ADR-012](ADR-012-po-manages-campaigns.md) | `amplify_po` can manage campaigns | Accepted |
| [ADR-013](ADR-013-po-dashboard-phase1.md) | PO dashboard ships in phase 1 | Accepted |
| [ADR-014](ADR-014-three-leaderboards-top-n.md) | Three leaderboards, top N default 3 | Accepted; "no full company list" superseded by ADR-035 |
| [ADR-015](ADR-015-failed-share-retry-reuses-row.md) | Retry after a failed share reuses the row | Accepted |
| [ADR-016](ADR-016-erasure-deferred.md) | Employee erasure deferred, checklist exception | Accepted (security flag) |
| [ADR-017](ADR-017-one-claim-per-url.md) | One external-share claim per URL | Accepted |
| [ADR-018](ADR-018-share-verification-and-metrics-need-community-management.md) | Share verification and share metrics wait for Community Management | Accepted |
| [ADR-019](ADR-019-leaderboard-team-visibility.md) | Team page visibility and server-side team roster | Accepted (roster = people-app directory, 2026-10-19); ranks and points visibility superseded by ADR-035 |
| [ADR-020](ADR-020-amplify-common-local-package.md) | Shared code in `amplify_common` from the local Ballerina repository | Accepted for phase 1 (B19 resolved by ADR-021) |
| [ADR-021](ADR-021-amplify-domain-shared-contexts.md) | Bounded contexts and repositories in a shared `amplify_domain` package (B19) | Accepted for phase 1 |
| [ADR-022](ADR-022-backend-jwt-verification-and-authz.md) | amplify-api verifies the backend JWT itself (JWKS cache + breaker) and enforces the activity matrix in code | Accepted for phase 1 |
| [ADR-023](ADR-023-dev-local-jwt.md) | Dev-only switch to accept locally signed JWTs (local Docker only) | Accepted (local only) |
| [ADR-024](ADR-024-amplify-api-m5-boundaries.md) | amplify-api M5 boundary choices: S3→C2 unit of work, idempotency keys, degraded dependencies | Accepted |
| [ADR-025](ADR-025-jobs-run-delivery-and-resilience.md) | amplify-jobs Run: synchronous `/runs`, one run via advisory lock, outbox retry not HTTP retry, deferral, breakers + bulkheads | Accepted (amended 2026-10-17) |
| [ADR-026](ADR-026-akornatskyy-scheduler.md) | `akornatskyy/scheduler` replaces amplify-cron and the Choreo Scheduled Task; amplify-api pushes schedule settings to it | Accepted (amended 2026-10-17) |
| [ADR-027](ADR-027-per-component-docker-contexts.md) | One Docker context per component (Choreo reads `<context>/.choreo/component.yaml`); shared packages built inside the image; jobs on its own ancestor context `apps` | Accepted (amended 2026-10-30, 2026-11-01) |
| [ADR-028](ADR-028-database-breaker-and-breaker-metrics.md) | Database circuit breaker (`DbBreaker` in front of each pool), read-only transient retry, `amplify_breaker_state` gauge, log hygiene check | Accepted (amended 2026-10-17) |
| [ADR-029](ADR-029-ledger-reference-encoding.md) | Ledger reference encoding: deterministic base64url (`AMP-`/`ADJ-`/`REV-`), append-only, 47-char award (C1) | Accepted for phase 1 (re-check with wso2-coin) |
| [ADR-030](ADR-030-repository-home.md) | Amplify source in its own repo under a WSO2-managed GitHub org, added as a submodule (D12) | Superseded by ADR-033 |
| [ADR-031](ADR-031-job-use-cases-live-in-amplify-domain.md) | Job use cases live in shared `amplify_domain`, not an api module or a jobs copy (B19, as built) | Accepted for phase 1 |
| [ADR-032](ADR-032-transaction-gate-ballerina-2201-13.md) | Process-wide transaction gate on Ballerina 2201.13.x (R-13): every `transaction` block runs through `store:inTransaction`; remove after the 2201.14.1+ upgrade | Accepted (interim) |
| [ADR-033](ADR-033-amplify-lives-in-marketing-tools.md) | Amplify backend lives in marketing-tools at `apps/amplify` (D12; supersedes ADR-030) | Accepted |
| [ADR-034](ADR-034-share-is-a-repost.md) | The Amplify action is a REPOST of the campaign post; the D5 spike passed | Accepted |
| [ADR-035](ADR-035-open-leaderboards-and-employee-count.md) | Open leaderboards by company, BU and team; employee count cached 7 days | Accepted |
| [ADR-036](ADR-036-dashboards-for-amplify-roles.md) | Dashboards for the amplify_* roles, read from a reporting context | Accepted |
| [ADR-037](ADR-037-celebrate-top-three-this-week.md) | Celebrate top three and My position are for this month, cached 2 hours | Accepted |
| [ADR-038](ADR-038-group-based-access-by-capability.md) | Group-based access by capability; Asgardeo groups per capability from configuration, `GET /me` returns grants | Accepted |
| [ADR-039](ADR-039-internal-key-for-back-office-components.md) | An internal key (full access) and a scheduler key (`/runs` and partition maintenance only) protect amplify-jobs | Accepted (amended 2026-11-01) |
| [ADR-040](ADR-040-erasure-leaver-sweep-and-token-grants.md) | One audited erase function, a leaver sweep, narrower token grants, outbox alerting | Accepted |

## D-number to ADR map (resolves audit B1)

The plan and phase1-domains used overlapping D-numbers that mean different things from D5 on. This table is the single register. "Open" means not decided yet; it gets an ADR when it is.

| Plan D# | Plan topic | Domains D# | Domains topic | ADR |
| --- | --- | --- | --- | --- |
| D1 | Ballerina | D1 | Ballerina | ADR-001 |
| D2 | PostgreSQL + Choreo extension check | D2 | PostgreSQL, daily token partitions | ADR-002 (check open) |
| D3 | Worker shape | D3 | Worker shape | ADR-003 |
| D4 | LinkedIn OAuth redirect to One WSO2 route | D4 | same | Open (SDK callback check pending) |
| D5 | Repost spike (`reshareContext`) | — | — | ADR-034 (passed 2026-10-20) |
| — | — | D5 | API proxy at cell edge | ADR-004 |
| D6 | PO decisions (points, period, reminders) | — | — | Open |
| — | — | D6 | Data model conventions | ADR-005 |
| D7 | Token retention security research | — | — | Open |
| — | — | D7 | Phase 1 scoring scope | ADR-006 |
| D9 | Choreo naming | — | — | ADR-007 |
| D10 | Local identity: Asgardeo | — | — | ADR-008 |
| D11 | Dockerfile buildpack | — | — | Open |
| D12 | Repo home | — | — | ADR-033 (supersedes ADR-030) |
| D13 | People data from One WSO2 | — | — | ADR-009 |
| D14 | Team adjust/remove = `amplify_po` | — | — | ADR-010 |

Audit decisions ([requirements-map.md](../solution/Phase%201/requirements-map.md)): A5 → ADR-011, A6 → ADR-012, B6 → ADR-013, B15/B16 → ADR-014, B15/A10 visibility → ADR-019, C2 → ADR-015, C3 → ADR-016, C5 → ADR-017, C1 → ADR-029, B19 → ADR-021 (as built, ADR-031).

See [traceability-matrix.md](../solution/Phase%201/traceability-matrix.md) for every requirement and audit finding mapped to its disposition, milestone, ADR and evidence.

There is no D8.
