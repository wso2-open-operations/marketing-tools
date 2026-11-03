# ADR-045: The HR Entity GraphQL service is Amplify's employee directory

Status: Accepted (2026-11-03)

## Context

Amplify needs every current employee's work email, name, business unit and team to build My Team rosters, the
headcount and the leaver sweep. It read them from people-app's `GET /employees/basic-info`. people-app's interceptor
rejected a client-credentials token (no email, no groups), so PR #380 in people-ops-suite taught it about service
clients. The reviewer pointed out that this hands a third-party application a full directory row, including
`Marked leaver`, and loads the primary database on every call. The People Operations reviewer confirmed that the HR
Entity GraphQL service is what service-to-service callers use for this.

## Decision

- **amplify-api and amplify-jobs read the HR Entity GraphQL service**, not people-app. The `employees(filter, limit,
  offset)` query is sent as a GraphQL POST over the existing HTTP client (circuit breaker, timeout, OAuth2
  client credentials). It is paged (`hrEntityPageSize`, default 1000) and stops at a short page.
- **Only the fields Amplify uses are asked for.** The api asks for `workEmail`, `firstName`, `lastName`,
  `businessUnit` and `team`; the leaver sweep asks for `workEmail` only. Status, job band, manager and start date are
  never requested.
- **Statuses:** `hrEntityStatuses`, default `Active` and `Marked leaver`. A person who has resigned still works here
  until their status is `Left`, so they stay on rosters and out of the sweep.
- **Configuration** has the same shape as leave-app's: `hrEntityBaseUrl` and OAuth2 `tokenUrl`, `clientId`,
  `clientSecret` (`hrEntityTokenUrl`, `hrEntityClientId`, `hrEntityClientSecret`). Amplify gets its own client from
  People Operations; the code does not depend on which client is used.
- **Team grouping** uses the entity's `team`. The entity query does not ask for a sub-team, so a roster is the
  business unit and team, where people-app's directory split it by sub-team as well.
- **House is not read.** It lives in people-app's database, and no entity query Amplify knows of returns it. The
  house board and house counts stay in the API and answer empty until a later change adds the field.
- **No other change to people-app.** PR #380's service-client path stays in people-app but Amplify no longer uses it.

## Consequences

- The people-app interceptor change is no longer on Amplify's critical path.
- Rosters are coarser (team, not sub-team) and carry no house until the entity offers them.
- The local stack's `people-stub` answers the same GraphQL query from `directory.json`, and still serves
  `GET /employees/basic-info` for One WSO2's photos.
- `local/people-app-proto` exercised the people-app service-client path and no longer matches the config names.
