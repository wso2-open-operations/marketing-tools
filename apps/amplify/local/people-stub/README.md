# people-stub

A local stand-in for the employee directory. It serves a JSON roster from a file through the two routes Amplify and a local One WSO2 use. Ballerina package `amplify_people_stub`.

## What it is and how it is triggered

The Compose service `people-stub` (`compose.yaml`) starts it with `make up`; amplify-api waits for it to be healthy. The production directory is the HR Entity GraphQL service (ADR-045), so amplify-api and amplify-jobs default `hrEntityBaseUrl` to `http://people-stub:9096/graphql` locally (`HR_ENTITY_URL` overrides it). The stub is published on `127.0.0.1:19092` so a local One WSO2 can read it (`ONE_WSO2_PEOPLE_BACKEND_URL = http://localhost:19092`).

The roster is `directory.json` in this folder. It is gitignored, because it may hold real names and emails. `make env` copies `directory.json.example` to it when missing (`people-stub-directory` in the `Makefile`). Compose mounts it read-only at `/app/directory.json`. The stub rereads it on every call. amplify-api caches teams for its own roster cache time.

## Routes

All in `main.bal`.

| Route | What it does |
| --- | --- |
| `POST /graphql` | The HR Entity `employees(filter, limit, offset)` query. Reads `variables.filter.employeeStatus` (a list of statuses), `variables.limit` (default 1000) and `variables.offset` (default 0). Answers `{data: {employees: [...]}}`. A row whose `employeeStatus` is not in the list is left out. It returns whole rows except `house` and `houseId`, which it adds only when the query text names `house`, as the real service answers only the fields asked for |
| `GET /employees/basic-info` | The whole roster as a JSON array. This is the old people-app route. Only the local One WSO2 (photos, names) still reads it |
| `GET /health` | `{status: "UP"}` |

Both data routes answer 500 when `directoryFile` is missing or not a JSON array. CORS allows `allowOrigins` with credentials, for the `Authorization` and `Content-Type` headers.

## Settings

| Setting | Default | What |
| --- | --- | --- |
| `port` | 9096 | Listener port |
| `directoryFile` | `directory.json` | The roster, a JSON array of rows |
| `allowOrigins` | `["http://localhost:3000"]` | Browser origins that may read it |

A row has the fields of the example file: `employeeId`, `firstName`, `lastName`, `workEmail`, `employeeThumbnail`, `designation`, `jobBand`, `startDate`, `managerEmail`, `businessUnit`, `house`, `team`, `subTeam`, `unit`, `employmentType`, `company`, `workLocation`, `employeeStatus`. Use `Active`, `Marked leaver` or `Left` for the status.

Houses: hr_entity 1.1.1 has `houseId` (an integer, null when there is no house) and `house` (the house name). The example rows carry `houseId` and `house` with made-up names, not the real four (CloudBots, Titans, Legions, Wild Boars). The stub answers them only when the query names `house`, so locally the house board stays empty until `hrEntityIncludeHouse` is on (`HR_ENTITY_INCLUDE_HOUSE=true` in `local/.env`), the same as against a real service. `houseId` must be a number or null in your `directory.json`, because a string fails amplify-api's read.

## Files

| File | What |
| --- | --- |
| `main.bal` | The service |
| `directory.json.example` | A fake roster to copy to `directory.json` |
| `tests/stub_test.bal`, `tests/Config.toml` | Tests: the roster, CORS, the GraphQL page and status filter. Port 19596 |
| `Dockerfile` | Builds the jar, runs it as UID 10014 on port 9096 |
| `Ballerina.toml`, `Dependencies.toml`, `.dockerignore` | Package and build files |

## Run and test

```sh
cp directory.json.example directory.json    # once
bal test                                    # from this folder
bal run                                     # port 9096
```

## What it does not do

- It does not check tokens. Any caller gets the roster.
- It does not parse the GraphQL query. It only reads the three variables.
- It does not model the real service's errors or its limits.
