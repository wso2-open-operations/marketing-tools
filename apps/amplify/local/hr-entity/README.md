# Local HR Entity + ThunderID

Run a stand-in for the HR Entity service and a ThunderID sign-in server on your machine, both loaded with the same 200 fake employees (`@example.com`), so you can debug Amplify's team rosters, headcount, leaver sweep and role-gated screens without the real (private) HR Entity or a real IdP.

Standalone: its own Compose project (`amplify-hr-entity`) and network. It changes nothing in the main Amplify stack until you set the lines below.

| Piece | Host port | What |
|---|---|---|
| `hr-entity` | `127.0.0.1:19097` | Node mock of the HR Entity GraphQL `employees(filter, limit, offset)` query, over Postgres. No auth. Also `GET /employees/basic-info` (people-app's shape) for One WSO2 names |
| `hr-entity-db` | none | Postgres 17, `seed.sql` loaded on first start |
| `thunderid` | `https://127.0.0.1:8090` | [ThunderID](https://github.com/asgardeo/thunder) (image `ghcr.io/thunder-id/thunderid:1.0.0`, pinned by tag and digest: the `latest` gateway image is a 2.0 milestone whose console and user type name differ) (self-signed certificate: open it once in the browser and accept it) |

## Design

- **One source of truth.** `gen.mjs` writes `people.csv`, `seed.sql` and `thunder/10-amplify.yaml` from one list, so the database and ThunderID always match. The 200 people include the 5 special users (195 random names).
- **The mock is a small Node service**, not an extension of `people-stub`, because the data lives in a database. It follows `people-stub`'s query behaviour. Its own config and endpoints: [mock/README.md](mock/README.md).
- **Standalone compose.** The compose file has its own project (`amplify-hr-entity`). Ports: HR mock `19097`, ThunderID `https://localhost:8090`.
- **Admin user.** ThunderID already ships a built-in user with email `admin@example.com`, so that user is the Amplify admin (it is also in ThunderID's own `Administrators` group).
- **No auth on the mock.** The real service's `HRENTITYTOKENURL` client-credentials flow is not exercised.

## Start and stop

```bash
cd apps/amplify
docker compose -f local/hr-entity/compose.yaml up -d --build --wait   # first run pulls images, takes a minute
docker compose -f local/hr-entity/compose.yaml down                   # stop, keep data
docker compose -f local/hr-entity/compose.yaml down -v                # fresh start (reseeds both)
```

Seed and bootstrap files only run on an empty volume, so after `gen.mjs` changes use `down -v`.

## The cast

200 employees. Everyone signs in to ThunderID with their email and **`Password2026!`** (override with `DEFAULT_PASSWORD`; it applies to every user at first start).

| Email | Amplify group (ThunderID `groups` claim) |
|---|---|
| `admin@example.com` | `amplify_admin` |
| `po@example.com` | `amplify_po` |
| `marketing@example.com` | `amplify_marketing` |
| `slt@example.com` | `amplify_slt` |
| `user@example.com` | none |
| 195 others (`first.last@example.com`) | none |

Teams, business units, sub-teams and houses (about 15% of people have no house) are spread over everyone. A few departments sit under several BUs, one in a different spelling (Business Operations under 4 BUs, Customer Success under 2), like the real directory, so the Team Leaderboard's one-row-per-department roll-up can be seen locally. `admin@example.com` is ThunderID's built-in admin user (its username is the email too), so it also sits in ThunderID's own `Administrators` group and can open the ThunderID console at `https://localhost:8090/console`.

## Point Amplify at it

amplify-api and amplify-jobs, in `local/.env` (the HR Entity has no auth here, so the token settings stay empty):

```
HR_ENTITY_URL=http://host.docker.internal:19097/graphql
```

Then `docker compose --env-file local/.env up -d amplify-api amplify-jobs` (amplify-api keeps its roster for 24 hours, so restart it after any change).

Sign-in for a local One WSO2 (`projects/one-wso2/webapp/public/config.js`):

```js
ONE_WSO2_AUTH_BASE_URL: "https://localhost:8090",
ONE_WSO2_AUTH_CLIENT_ID: "AMPLIFY_LOCAL",
ONE_WSO2_AUTH_WELL_KNOWN_URL: "https://localhost:8090/.well-known/openid-configuration",
ONE_WSO2_PEOPLE_BACKEND_URL: "http://localhost:19097",
```

The `AMPLIFY_LOCAL` client is a public PKCE client for `http://localhost:3000` and asks for the `groups` scope. The dev proxy looks up the email from ThunderID (see [TestAmplify.md](../../docs/HowToTestLocally/TestAmplify.md) step 4); ThunderID's certificate is self-signed, so run it as:

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 USERINFO_URL=https://localhost:8090/oauth2/userinfo node local/one-wso2-proxy/proxy.mjs
```

## Check it works

```bash
curl -s -XPOST localhost:19097/graphql -H 'Content-Type: application/json' -d '{
  "query":"query getEmployees($filter: EmployeeFilter!, $limit: Int, $offset: Int) { employees(filter: $filter, limit: $limit, offset: $offset) { workEmail firstName lastName businessUnit department subTeam houseId house } }",
  "variables":{"filter":{"employeeStatus":["Active"]},"limit":3,"offset":0}}' | jq
```

The mock answers only the fields the query names, and refuses an unknown field with HTTP 400 and `errors`, as the real service does (amplify-api relies on that to detect an HR Entity older than 1.1.1).

## Change the cast

`gen.mjs` writes `people.csv`, `seed.sql` and `thunder/10-amplify.yaml` from one list, so the database and ThunderID never drift. Edit it (counts, special users, teams, houses), run `node gen.mjs`, then `down -v` and `up`. It is deterministic: the same script gives the same 200 people.

## Not covered

- Real HR Entity auth (OAuth client credentials, `HRENTITYTOKENURL`): the mock accepts any caller.
- The real service's other fields and queries; only what Amplify asks for (`employeeStatus` filter, paging, the fields in `outbound.bal`) is modelled.
- Photos: `employeeThumbnail` is empty.

## Sign-in page branding

The ThunderID sign-in page shows Amplify's logo and a short description of what Amplify is for. The left panel is compiled into ThunderID's gate bundle, so `branding/` holds replacement files mounted over it: `logo.svg` and `logo-inverted.svg` (light and dark pages), `SignInSlogan-Tolf_PI8.js` (the text) and `gate-config.js` (the product name). The file names belong to the pinned image. When the image pin changes, copy the new originals out (`docker run --rm <image> cat /opt/thunderid/apps/gate/assets/SignInSlogan-*.js`) and reapply the text.
