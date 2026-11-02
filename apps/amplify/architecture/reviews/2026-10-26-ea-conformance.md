# EA conformance review: Amplify phase 1 (2026-10-26)

Method: WSO2 Agentic Enterprise Architecture conformance checklist (May 2026 revision), the same checklist as the 19 Oct review. This pass reads the design as it is now, so I read the ADRs and the code, not only the SAD. Scope: [phase1-solution-architecture.md](../solution/Phase%201/phase1-solution-architecture.md), ADR-034 to ADR-037, the Novera egress in `amplify-jobs`, the `amplify-api` dashboards and leaderboards, the people-app service-client read, the threat model v0.3 and the Novera notifications route in `po-agent`.

**Headline.** The cell kept its shape while the design moved. One proxy still fronts everything, the activity matrix still denies by default, and the new dashboards slot into it as one more audience (`DASHBOARD_READERS`) with no side door. The Novera announcement reuses the outbox, so it gets persist-first, retry with backoff and a terminal `FAILED` for free. Credit to the team: the late changes (ADR-034 to ADR-037) each came with tests and an ADR.

Two things did not move. None of the five gaps from 19 Oct is closed, and the two High items (egress, tracing) are still the ones to decide before the security review. And the documents have fallen behind the code: the SAD, the threat model and the ADR index say nothing about Novera, the dashboards or the open leaderboards. That is the new work in this report.

## Counts

| Severity | Carried forward (still open) | New | Total |
|---|---|---|---|
| High | 2 | 0 | 2 |
| Medium | 2 | 4 | 6 |
| Low | 1 | 3 | 4 |
| Conflicts | 0 | 0 | 0 |

Fixed: 0. Superseded: 1 (the "not yet adopted" row, partly). Confidence is per finding below.

## Checklist verdicts

| # | Area | Verdict | Where |
|---|---|---|---|
| 1 | Gateway boundaries | Partial (gap G1) | Ingress is one proxy. Egress: Novera and people-app go through Choreo gateways; LinkedIn and Chat do not |
| 2 | Boundary auth | Conformant | OAuth2 client credentials to Novera and people-app, per-member OAuth to LinkedIn, secret webhook to Chat. Internal calls still open (G5), people-app assertion handling (N7) |
| 3 | Control plane vs dashboard | Conformant | ADR-036 calls the boards dashboards; governance stays in the matrix, settings and audit |
| 4 | Identity ownership | Absent (gap G4) | Email is still the join key |
| 5 | Entity Layer mediation | Conformant for writes, gap for reads (G3) | Amplify writes only its own database; employee data still comes from people-app's application API |
| 6 | Orchestration | Conformant | One engine (`amplify-jobs` driven by the scheduler). Novera is a delivery target, not a second orchestrator |
| 7 | Observability | Absent (gap G2) | Correlation ids reach Novera and people-app; neither logs them; no tracing design |
| 8 | Agent governance | Not applicable to Amplify; see N5 | Amplify has no agent. Novera is one, and it is now in the announcement path |
| 9 | AI traffic controls | Not applicable to Amplify; see N5 | The Novera payload is plain text from campaign fields. No LLM call in Amplify |
| 10 | Async patterns | Conformant | Persist-first outbox. Feedback loop from Novera is thin (N1) |

## Carried forward from 19 Oct

### Conformant items

| # | Item | Status | Evidence |
|---|---|---|---|
| C1 | Ingress gateway | Still conformant | One published proxy; backend, jobs, scheduler and databases at Project visibility ([ADR-004](../decisions/ADR-004-api-proxy-cell-edge.md), [CLAUDE.md](../../CLAUDE.md) cell rules). The new `/dashboards/*`, `/leaderboard/*` and `/headcount` routes sit behind the same proxy ([openapi.yaml](../../amplify-api/openapi.yaml)) |
| C2 | Governance at every layer | Still conformant | Default-deny matrix in [matrix.bal](../../amplify-api/modules/auth/matrix.bal); dashboards gated by `DASHBOARD_READERS` (PO, MKT, SLT, ADM) per [ADR-036](../decisions/ADR-036-dashboards-for-amplify-roles.md); the UI hides the menu but the backend is the gate ([useAmplifyDashboardAccess.test.tsx](../../../../../one-wso2/webapp/src/features/amplify/api/useAmplifyDashboardAccess.test.tsx)) |
| C3 | Async patterns | Still conformant, now includes Novera | `CampaignRegistered` outbox row to Novera: retryable 503/429/no response goes back to the outbox, 4xx is terminal `FAILED`, no HTTP-level retry ([novera.bal](../../amplify-jobs/novera.bal), [handlers.bal](../../amplify-jobs/handlers.bal), [ADR-025](../decisions/ADR-025-jobs-run-delivery-and-resilience.md)) |
| C4 | Orchestration | Still conformant | Same single engine; Novera is called from the existing `CampaignRegistered` handler, no new coordinator |
| C5 | Control plane vs dashboard | Still conformant | [ADR-036](../decisions/ADR-036-dashboards-for-amplify-roles.md) names five dashboards and keeps governance in the matrix and audit |
| C6 | Writes to systems of record | Still conformant | Amplify writes only its own database. The new `reporting` context reads other Amplify schemas, writes nothing and publishes no events ([ADR-036](../decisions/ADR-036-dashboards-for-amplify-roles.md) item 3). It is an accepted bend of ADR-005 inside the cell's own store and raises no EA issue. Novera and LinkedIn are called, not written to as records |
| C7 | Boundary auth (external) | Still conformant, two additions | Novera: OAuth2 client credentials from an application subscribed at the gateway, https enforced except for the local mock ([novera.bal](../../amplify-jobs/novera.bal)). people-app: the 19 Oct code review's B1 and B2 are fixed, so only application tokens count as service clients and the route match is exact ([authorization.bal](../../../../../people-ops-suite/apps/people-app/backend/modules/authorization/authorization.bal), review). Open point: N7 |

### Gaps

| # | Gap | Status | Evidence |
|---|---|---|---|
| G1 | Egress gateway (High) | **Still open**, narrowed | See details below |
| G2 | End-to-end tracing (High) | **Still open**, wider chain | See details below |
| G3 | Entity Layer for employee data (Medium) | **Still open**, wider use | See details below |
| G4 | Single identity owner for employees (Medium) | **Still open** | See details below |
| G5 | Internal call auth (Low) | **Still open** | See details below |
| NYA | Agents, MCP and AI gateways "not yet adopted" | **Superseded** in part | Novera is now in the path. See N5 |

**G1. Egress gateway.** High, confidence Medium. Still open, but smaller than on 19 Oct. Two of the four outbound targets now cross a Choreo gateway with an authenticated subscription: Novera ([novera.bal](../../amplify-jobs/novera.bal), `noveraNotifyUrl` is "the Choreo gateway URL of Novera's API") and the people-app directory ([outbound.bal](../../amplify-api/outbound.bal)). LinkedIn (`api.linkedin.com`, `www.linkedin.com`) and the Club webhook (`chat.googleapis.com`) are still direct HTTPS from `amplify-jobs`, with breakers, per-run and per-day ceilings and secrets in Choreo ([CLAUDE.md](../../CLAUDE.md) "Egress only to the declared endpoints"). The deploy runbook still says "if the org uses egress control" and its allow-list does not name the Novera gateway host ([choreo-deploy.md](../../docs/runbooks/choreo-deploy.md) D5). Fix is unchanged: decide whether the org has an egress gateway, route LinkedIn and Chat through it, or accept the risk with an owner.

**G2. End-to-end tracing.** High, confidence Medium. Still open. `X-Correlation-ID` is assigned at the edge ([interceptors.bal](../../amplify-api/interceptors.bal)) and now travels to amplify-jobs, people-app and Novera (`resilience:correlationHeaders` in [novera.bal](../../amplify-jobs/novera.bal)). The receivers do not use it: a search of people-app's backend finds no correlation handling, and `po-agent`'s notifications route reads no correlation header ([index.ts](../../../../../wso2-digital-agents/po-agent/src/index.ts)). The chain is longer now (proxy, api, outbox, jobs, Novera gateway, Novera, Google Chat, per-person DM) and the gap grows with it. `observabilityIncluded = true` is set in every deployable Ballerina package ([amplify-api/Ballerina.toml](../../amplify-api/Ballerina.toml)). I found no tracing design and nothing in the operations runbook about it. I could not confirm what Choreo traces on dev because the dev deploy is still open (T4.1 in [epic-map.md](../../docs/requirements/epic-map.md)).

**G3. Entity Layer for employee data.** Medium, confidence Medium. Still open, and the dependence grew. One whole-directory call to `GET /employees/basic-info` now builds team, BU, house and headcount indexes ([outbound.bal](../../amplify-api/outbound.bal), [ADR-035](../decisions/ADR-035-open-leaderboards-and-employee-count.md) item 4). The directory is still people-app's application API, not a versioned employee entity. The 19 Oct integration-boundary review's single fix (refresh off the request path) is recorded in that review; the 7-day headcount cache and 3-day team cache soften it but I did not confirm the refresh left the request path.

**G4. Single identity owner.** Medium, confidence High. Still open. The index maps lowercase work email to team, BU and house (`teamOf`, `buOf`, `houseOf` in [outbound.bal](../../amplify-api/outbound.bal)). Amplify keys employees by the IdP subject. A changed email still drops someone from their team and from group boards, where ADR-035 sums them into `unassigned` instead of dropping them. That softens the effect, but nobody owns the identity yet.

**G5. Internal call auth.** Low, confidence High. Still open. `amplify-jobs` has no caller auth ([service.bal](../../amplify-jobs/service.bal), [CLAUDE.md](../../amplify-jobs/CLAUDE.md) says caller auth "lands in M9/M10"). The scheduler API has none by design ([ADR-026](../decisions/ADR-026-akornatskyy-scheduler.md)). Accepted in the threat model as AMP-R1.

## New findings

| # | Severity | Confidence | Finding |
|---|---|---|---|
| N1 | Medium | High | Novera broadcast has one control, the gateway subscription |
| N2 | Medium | High | Threat model v0.3 and the deployment checklist describe the 19 Oct design |
| N3 | Medium | High | SAD, domains doc and ADR index lag the code; no ADR for the Novera egress |
| N7 | Medium | Medium | people-app admits service clients on claims it does not verify |
| N4 | Low | Low | Dashboard export and person board return employee emails; I found no read audit |
| N5 | Low | Medium | Novera is an agent with no registry or AI gateway evidence, now in Amplify's chain |
| N6 | Low | High | Stale comments and counts in code and docs |

**N1. Novera broadcast has one control.** Medium, confidence High. One registered campaign becomes one card to every employee who added Novera. The only protection of `POST /internal/notifications` is the gateway subscription: approving a subscription lets that application message every connected employee ([po-agent ARCHITECTURE.md](../../../../../wso2-digital-agents/po-agent/ARCHITECTURE.md) "Notifications", [openapi.yaml](../../../../../wso2-digital-agents/po-agent/.choreo/openapi.yaml)). On the Amplify side the controls are good: PO or Marketing roles register campaigns, one announcement per campaign (PK = campaign), the `announcements.enabled` kill switch, and the outbox dedupe. Gaps: no per-caller quota or volume ceiling at Novera; Novera answers 202 before it sends, so Amplify keeps a `novera:<campaignId>` marker and cannot see delivery ([handlers.bal](../../amplify-jobs/handlers.bal)); and the production channel (Novera, webhook, or both) is still an open decision in [phase1-planned-todos.md](../../docs/requirements/phase1-planned-todos.md). This falls under the governance-at-every-layer principle and is no conflict. Fix: record the decision, agree a per-caller rate limit with the Novera owner, and decide whether the PO needs delivery counts.

**N2. Security documents lag.** Medium, confidence High. Threat model v0.3 says Novera is out of scope, lists Chat as the only announcement channel (campaign registration flow), and §8.8 says employees see "own team only" with "no full company list". [ADR-035](../decisions/ADR-035-open-leaderboards-and-employee-count.md) reversed that for ranks and points. It also has no entry for the five dashboards, the CSV export with reposter emails, the person board, or the weekly top three. The ADR itself tells security to note the points classification. [epic-map.md](../../docs/requirements/epic-map.md) already tracks this as T5.1 (threat model v0.4 delta). Fix: ship v0.4 before the security review.

**N3. Architecture documents lag.** Medium, confidence High. What I found:

- The [SAD diagram](../solution/Phase%201/phase1-solution-architecture.md) has no Novera egress, no people-app, no `reporting` context and no dashboards. It lists "Agent (Novera, AMP)" under later phases. T2.2 in [epic-map.md](../../docs/requirements/epic-map.md) covers this.
- [phase1-domains.md](../solution/Phase%201/phase1-domains.md) still says "B7 announcements through Novera: Club space incoming webhook" and "Novera tools" as later phase.
- [phase1-code-modules.md](../solution/Phase%201/phase1-code-modules.md) names none of ADR-034 to ADR-037, and the SAD names none of them either.
- There is no ADR for the Novera egress. The decision lives in the plan todos and the CLAUDE.md cell rules. The ADR index ([README.md](../decisions/README.md)) ends at ADR-037 with no Novera row.
- The SAD does not mention share-as-repost ([ADR-034](../decisions/ADR-034-share-is-a-repost.md)) or the service-client read of people-app.

Fix: one ADR for the Novera egress (channel choice, subscription as control, 202 semantics), then the SAD diagram and the domains doc.

**N7. people-app trusts the gateway assertion unsigned.** Medium, confidence Medium. The service-client path decides on claims (`application` claim value, client id in the allow list) read with `jwt:decode`, which does not verify the signature ([authorization.bal](../../../../../people-ops-suite/apps/people-app/backend/modules/authorization/authorization.bal)). The threat model already carries this as AMP-R9. It matters more now because the same check admits whole-directory reads (work email, names, photo, team, house) without a user. It holds as long as the gateway is the only way in. I could not verify people-app's network exposure from the repo. Fix: verify the assertion signature in people-app, or record the network guarantee.

**N4. Export and person board.** Low, confidence Low. `GET /dashboards/export` returns up to 366 days of rows with employee name and email as CSV, and `/dashboards/people/{employeeId}` shows one person's posts, both for the four dashboard roles ([dashboards.bal](../../amplify-api/dashboards.bal)). The CSV cell function guards against formula injection. I found no audit row for a successful read of either route and did not run the service to check. Denials are audited. Fix: confirm, and if missing, audit export reads with the range and caller.

**N5. Novera is an agent in the chain.** Low, confidence Medium. Amplify sends plain text built from campaign fields and calls no LLM, so rows 8 and 9 do not apply to it. Novera does call Claude through the Anthropic SDK, with an optional `ANTHROPIC_BASE_URL` ([claude.ts](../../../../../wso2-digital-agents/po-agent/src/agent/claude.ts)). I found no Agent Registry entry, AI gateway or PII redaction in its architecture doc. That belongs in the Novera review. It becomes an Amplify concern if Amplify starts sending employee data to Novera or Novera starts acting on Amplify data.

**N6. Stale comments and counts.** Low, confidence High.

- [config.bal](../../amplify-jobs/config.bal) says `amplifyOnNovera` is "Not acted on yet: the Novera sender does not exist". `handlers.bal` branches on it.
- [CLAUDE.md](../../amplify-api/CLAUDE.md) says "42 operations"; the spec has 46.
- [phase1-planned-todos.md](../../docs/requirements/phase1-planned-todos.md) says LinkedIn and Chat are "Choreo connections"; the descriptors use plain config for them, for Novera and for people-app (also M4 in the 19 Oct code review).
- The people-app and Novera hosts are missing from the D5 allow-list in [choreo-deploy.md](../../docs/runbooks/choreo-deploy.md).

## Where the SAD and ADRs lag the code

| Area | Code says | Document says |
|---|---|---|
| Novera egress | `amplify-jobs` announces through Novera by default (`amplifyOnNovera = true`), Chat webhook becomes best effort | SAD: Chat only, Novera later. No ADR. Threat model: Novera out of scope |
| Dashboards | Five boards, one 60-second snapshot, `reporting` context, export, person board | SAD silent. [po-dashboard.md](../solution/Phase%201/po-dashboard.md) and the matrix are current; the threat model is not |
| Open leaderboards | Company, BU, team and group boards open to all roles; headcount cache 7 days | ADR-035 current; threat model §8.8 and the older team-visibility wording are not |
| Weekly top three | `GET /leaderboard/top`, weekly scope, 2-hour per-replica cache | ADR-037 and [leaderboards.md](../solution/Phase%201/leaderboards.md) current; SAD silent |
| people-app | Service-client read of `GET /employees/basic-info`, house included | Threat model B-E3 current; SAD diagram has no people-app |
| Share kind | REPOST, REPOST_COMMENTARY when text is added | ADR-034 current; SAD silent |

## Conflicts

None. Nothing contradicts the reference model. The gaps are ones a 90-day internal pilot can carry, except the two High items, which still need a decision with a named owner before the security review.

## Not yet adopted (no finding)

Agent Registry, MCP and AI gateways, LLM token telemetry and prompt guardrails for Amplify itself. Amplify has no LLM call. See N5 for Novera.

## Single most valuable fix

**Write the Novera egress ADR and the threat model v0.4 delta together, and put the egress gateway decision in both.** One short ADR settles the channel (Novera, webhook or both), the subscription as the only control and a quota with the Novera owner (N1). The v0.4 delta then covers Novera, open boards, dashboards and export (N2), and the SAD update follows from the ADR (N3). Put the G1 decision in the same pass: either route LinkedIn and Chat through the org egress gateway with tracing on it (which closes G1 and most of G2), or record the acceptance with an owner. That clears the High items and the Medium document gaps in one review cycle.

## What I could not verify

- Whether Choreo's built-in observability gives traces on dev (no dev deploy yet).
- Whether the matrix and `contract_test.bal` still pass; I did not run `bal test`.
- Whether successful export and person-board reads write audit rows (N4).
- Whether the directory refresh moved off the request path (G3).
- people-app's network exposure and whether the gateway is its only ingress (N7).
- The org's egress gateway: whether one exists (G1).
