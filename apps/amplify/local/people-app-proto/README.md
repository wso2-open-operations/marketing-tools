# people-app-proto

**Obsolete. Do not use it for current work.** It tests the old people-app service-client path, and Amplify no longer takes that path.

Why it is obsolete: ADR-045 moved the employee directory from people-app's `GET /employees/basic-info` to the HR Entity GraphQL service. amplify-api and amplify-jobs now read `hrEntityBaseUrl`, `hrEntityTokenUrl`, `hrEntityClientId`, `hrEntityClientSecret`, `hrEntityPageSize` and `hrEntityStatuses`. `run.sh` still sets the old `PEOPLE_DIRECTORY_URL`, `PEOPLE_DIRECTORY_TOKEN_URL`, `PEOPLE_DIRECTORY_CLIENT_ID` and `PEOPLE_DIRECTORY_CLIENT_SECRET`, which nothing in `compose.yaml` or the components reads any more. The `up` and `demo` steps would start the prototype and then fail to point amplify-api at it. The people-app service-client change (PR #380 in people-ops-suite) stays in people-app, but Amplify does not use it. The folder is kept as a record of how that path was proved.

For a local directory, use `local/people-stub` (it serves `POST /graphql` and `GET /employees/basic-info`).

## What it was and how it was triggered

A shell script (`run.sh`) run by hand from `apps/amplify` with the Compose stack up. It built the real people-app from the people-ops-suite submodule, started it with MySQL and a gateway stand-in, and pointed amplify-api's directory settings at the gateway. It proved that a client-credentials service client could read the directory and nothing else.

```sh
local/people-app-proto/run.sh up      # build people-app, start MySQL, people-app and the gateway
local/people-app-proto/run.sh demo    # curl checks, printed as PASS or FAIL
local/people-app-proto/run.sh off     # restart people-app with no service clients (the "before")
local/people-app-proto/run.sh down    # remove everything, point amplify-api back at people-stub
```

Needs Docker, curl, jq and openssl. `PEOPLE_BACKEND` overrides the people-app backend folder (default: the `people-ops-suite` submodule next to this repo).

## What the demo checked

- A listed service client reads `GET /employees/basic-info` through the gateway. Other people-app routes (one employee, personal info, search) answer 403.
- An unlisted client id answers 403. A listed id on a user token answers 500. An employee user and a user with no people group behave as before.
- amplify-api's My Team read worked from the real directory (the old check on team name and headcount).

## Files

| File | What |
| --- | --- |
| `run.sh` | `up`, `demo`, `off`, `down` |
| `gateway.mjs` | A Node gateway stand-in: `POST /token` (client credentials), then forwards with an unsigned `x-jwt-assertion` to people-app. Ports: gateway 19093, people-app 19094 |
| `Config.toml.template` | people-app configuration, filled into `Config.toml` by `run.sh` (gitignored) |
| `seed.sql` | A fake demo cast on `example.com` addresses, loaded into the prototype's MySQL |
| `.gitignore` | Ignores `Config.toml` and `.proto.env` |

## What it does not do

- It does not match the current configuration (see the top of this file).
- It does not test the HR Entity GraphQL service. `local/people-stub` and amplify-jobs' `leavers.bal` tests cover that shape.
- It does not run in CI.
