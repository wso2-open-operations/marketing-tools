# ADR-004: API proxy at the cell edge

- **Status:** Accepted (amended 2026-11-03)
- **Date:** 2026-10-16
- **Source:** domains D5 (no plan number)

## Context

One WSO2 needs a single, governed way into Amplify, with rate limits and subscriptions.

## Decision

An API proxy sits at the cell edge: Choreo API Proxy in Choreo, WSO2 API Manager in local Docker. `amplify-api` is visible only inside the project (superseded on 2026-11-03: its endpoint is Organization-visible, see the amendment below). One WSO2 calls only the proxy.

## Consequences

- One entry point; rate limiting and subscriptions handled there.
- Scopes per resource are enforced at the proxy **and** again in `amplify-api` (see [activity matrix](../solution/Phase%201/activity-matrix.md)).
- Local Docker needs an APIM container.

## Links

- [phase1-domains.md](../solution/Phase%201/phase1-domains.md) (D5)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (Architecture at a glance, Roles and access)

## Amendment (2026-11-03): the Backend endpoint is Organization-visible

Staging showed the Project-only Backend can't sit behind the proxy. Choreo accepted `http://amplify-backend-<id>:9090/` (the Backend's Project URL) as the proxy target, but every call through the proxy answered `503 No healthy upstream` (gateway code `102508`): the gateway runs outside the project, so it can't reach a Project-only endpoint. This is the fallback the runbook's step D1 planned for.

- **Change.** The `amplify-api` endpoint in `apps/amplify/.choreo/component.yaml` is `Organization`, and the proxy targets the Backend's Organization URL. One WSO2 still calls only the proxy, and only the proxy is published.
- **Why it's safe.** The Backend never trusted the network for identity: it verifies the gateway's backend JWT (signature against the gateway JWKS, `iss`, `aud`) and enforces the activity matrix itself (ADR-022). Another component in the organization that calls the Backend directly has no gateway-signed token, so every application route answers 401, written to the audit log as a denial.
- **Exception: the probes.** `GET /health` and `GET /ready` are public by design (activity matrix; `AuthInterceptor` lets them through without a token) so Choreo can check the pod. A direct caller in the organization can read them. They return status only: `UP`, and for `/ready` the state of the database, the JWKS and the breakers, with no user data. Each `/ready` call runs one database probe. They stay off the proxy (resilience-targets.md).
- **Unchanged.** amplify-jobs, the scheduler and the databases stay Project-only and are never published.
- **Not changed yet.** `amplify-api/workload.yaml` (OpenChoreo, M8c) keeps `project`; set its organization-level value when OpenChoreo deploys this component.
