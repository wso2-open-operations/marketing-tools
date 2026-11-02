# ADR-004: API proxy at the cell edge

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** domains D5 (no plan number)

## Context

One WSO2 needs a single, governed way into Amplify, with rate limits and subscriptions.

## Decision

An API proxy sits at the cell edge: Choreo API Proxy in Choreo, WSO2 API Manager in local Docker. `amplify-api` is visible only inside the project. One WSO2 calls only the proxy.

## Consequences

- One entry point; rate limiting and subscriptions handled there.
- Scopes per resource are enforced at the proxy **and** again in `amplify-api` (see [activity matrix](../solution/Phase%201/activity-matrix.md)).
- Local Docker needs an APIM container.

## Links

- [phase1-domains.md](../solution/Phase%201/phase1-domains.md) (D5)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (Architecture at a glance, Roles and access)
