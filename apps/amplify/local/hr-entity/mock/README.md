# HR Entity mock

A small Node service that answers the HR Entity GraphQL `employees` query Amplify reads, from a Postgres table. Local testing only: the real HR Entity is private and has no Docker image yet. Part of the [local HR Entity stack](../README.md), which also runs the database and ThunderID.

## Design

- Written as a small Node service rather than an extension of `local/people-stub` because the data lives in a database. It follows `people-stub`'s query behaviour.
- Serves the query from `amplify-api` (`employeesQuery` in `amplify-api/outbound.bal`) and the leaver sweep in `amplify-jobs`.
- Answers only the fields the query names. An unknown field, or no selection set, gets HTTP 400 with `errors`, as the real service does. Amplify depends on that to detect an HR Entity older than 1.1.1 (no `houseId` / `house`).
- No auth. The real service's client-credentials flow (`HRENTITYTOKENURL`) is not modelled, so leave the `HR_ENTITY_*` token settings empty.

## Endpoints

| Route | What |
|---|---|
| `POST /graphql` (also `POST /`) | `employees(filter: $filter, limit: $limit, offset: $offset)`. `filter.employeeStatus` is a list of statuses (omitted = all); `limit` defaults to 1000, `offset` to 0; ordered by `employeeId` |
| `GET /employees/basic-info` | people-app's shape (with an empty `employeeThumbnail`), for a local One WSO2's names |
| `GET /health` | `{"status":"UP"}` |

## Configuration

| Variable | Default | What |
|---|---|---|
| `DATABASE_URL` | none (required) | Postgres connection string. Compose sets `postgres://hr_entity:<password>@hr-entity-db:5432/hr_entity` |
| `PORT` | `9096` | Listener port inside the container (compose publishes it on host `127.0.0.1:19097`) |
| `ALLOW_ORIGINS` | `http://localhost:3000` | Comma-separated browser origins allowed by CORS (a local One WSO2) |

Compose also reads `HR_ENTITY_DB_PASSWORD` (default `hr-entity-local`) for the database and the mock.

## Fields

GraphQL field to column in the `employee` table (created and loaded by `../seed.sql`):

| Field | Column |
|---|---|
| `employeeId` | `employee_id` |
| `workEmail` | `work_email` |
| `firstName`, `lastName` | `first_name`, `last_name` |
| `businessUnit`, `department`, `subTeam` | `business_unit`, `department`, `sub_team` |
| `houseId`, `house` | `house_id`, `house` (empty for about 15% of people) |
| `designation`, `managerEmail` | `designation`, `manager_email` |
| `company`, `workLocation` | `company`, `work_location` |
| `startDate`, `employeeStatus` | `start_date`, `employee_status` |

`amplify_group` is in the table (it records the role each special user holds in ThunderID) but is not a GraphQL field. Amplify reads the team from `department`.

## Run

With the rest of the stack (from `apps/amplify`):

```bash
docker compose -f local/hr-entity/compose.yaml up -d --build --wait
```

Only the mock, against a Postgres you already seeded with `../seed.sql`:

```bash
npm ci
DATABASE_URL=postgres://user:pass@localhost:5432/hr_entity node server.mjs
```

The only dependency is `pg` (pinned, with a lockfile). Rebuild the image after changing `server.mjs`: `docker compose -f local/hr-entity/compose.yaml up -d --build hr-entity`.

## Point Amplify at it

In `local/.env`, then restart amplify-api and amplify-jobs (amplify-api keeps its roster for 24 hours):

```
HR_ENTITY_URL=http://host.docker.internal:19097/graphql
```

Leave `HR_ENTITY_TOKEN_URL`, `HR_ENTITY_CLIENT_ID` and `HR_ENTITY_CLIENT_SECRET` empty (no auth). Other Amplify settings that shape what it reads: `HRENTITYPAGESIZE` (default 1000) and `HRENTITYSTATUSES` (default `["Active","Marked leaver"]`); the cast here is all `Active`.

## Check it works

```bash
curl -s -XPOST localhost:19097/graphql -H 'Content-Type: application/json' -d '{
  "query":"query getEmployees($filter: EmployeeFilter!, $limit: Int, $offset: Int) { employees(filter: $filter, limit: $limit, offset: $offset) { workEmail department houseId house } }",
  "variables":{"filter":{"employeeStatus":["Active"]},"limit":3,"offset":0}}' | jq
```

## Not covered

- Auth of any kind.
- Filters other than `employeeStatus`, and any query other than `employees`.
- Photos (`employeeThumbnail` is empty).
