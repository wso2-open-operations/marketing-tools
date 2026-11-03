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
  client credentials). It is paged (`hrEntityPageSize`, default 1000; the service's own default is 100, and it may cap larger asks). The read ends on an empty page and the next offset moves by the rows that came back, so a capped page never truncates the roster.
- **Only the fields Amplify uses are asked for.** The api asks for `workEmail`, `firstName`, `lastName`,
  `businessUnit`, `team` and `subTeam`; the leaver sweep asks for `workEmail` only. Status, job band, manager and start date are
  never requested.
- **Statuses:** `hrEntityStatuses`, default `Active` and `Marked leaver`. A person who has resigned still works here
  until their status is `Left`, so they stay on rosters and out of the sweep.
- **Retries** use the other HR Entity apps' settings and defaults: `count` 3, `interval` 3.0 s, `backOffFactor` 2.0, `maxWaitInterval` 20 s
  (`hrEntityRetryCount`, `hrEntityRetryInterval`, `hrEntityRetryBackOffFactor`, `hrEntityRetryMaxWaitInterval`), on a connection
  error or a 500, 502, 503 or 504. Ballerina cannot set a record configurable (`retryConfig`, `oauthConfig`) from an
  environment variable, and Amplify configures everything that way, so these are flat names with the same fields and
  values. In amplify-api the first failed read after an outage takes the whole retry time (about 21 s at the defaults),
  then the circuit breaker opens and later calls fail at once for 30 s.
- **Configuration** has the same shape as leave-app's: `hrEntityBaseUrl` and OAuth2 `tokenUrl`, `clientId`,
  `clientSecret` (`hrEntityTokenUrl`, `hrEntityClientId`, `hrEntityClientSecret`). Amplify gets its own client from
  People Operations; the code does not depend on which client is used.
- **Team grouping** is unchanged: the sub-team, or the team when a person has none, under the business unit
  (decided 2026-10-19). The entity's `Employee` has both `team` and `subTeam`.
- **House is not read.** `Employee` has no house field. People-app keeps it in its own database (`house` table, `house_id` on
  the employee, set at onboarding from the employee id) and does not read it from the HR Entity. The house board and house
  counts stay in the API and answer empty until the entity offers one.
- **No other change to people-app.** PR #380's service-client path stays in people-app but Amplify no longer uses it.

## Consequences

- The people-app interceptor change is no longer on Amplify's critical path.
- Rosters carry no house until the entity offers one.
- The local stack's `people-stub` answers the same GraphQL query from `directory.json`, and still serves
  `GET /employees/basic-info` for One WSO2's photos.
- `local/people-app-proto` exercised the people-app service-client path and no longer matches the config names.
