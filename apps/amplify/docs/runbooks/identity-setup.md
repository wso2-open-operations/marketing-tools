# Runbook: Identity setup (Asgardeo, Choreo API proxy, LinkedIn apps)

Status: Draft (2026-10-16). Code side done in M4 ([ADR-022](../../architecture/decisions/ADR-022-backend-jwt-verification-and-authz.md)); the console steps below are still open in the [plan](../requirements/phase1-planned-todos.md) M4.
Owner: Amplify technical owner. Do non-prod first, test, then repeat for prod.

`amplify-api` config keys referenced below live in `amplify-api/config.bal` (Choreo: Configs & Secrets; local: `BAL_CONFIG_VAR_*`).

## Token requirements (read this first)

`amplify-api` decides who a caller is, and what they may do, from **one token: the access token** that One WSO2 sends as the Bearer. Locally the dev proxy reads it; in Choreo the API proxy validates it and builds the backend JWT (`x-jwt-assertion`) from its claims. It never reads the **id_token**. The id_token is for the One WSO2 app itself: it can show the right menu items while the API still sees a plain employee. That mismatch is the usual symptom of this being set up wrong.

**The access token must be a JWT and carry:**

| Claim | Why | If missing |
| --- | --- | --- |
| `groups` (array of `amplify_*` names) | the only source of PO, Marketing, SLT and Admin access (ADR-038) | everyone is a plain employee: `403 ROLE_NOT_PERMITTED` on New Post, Dashboards and review, and `400 "Only open campaigns can be listed"` on Current Posts |
| `email` | the employee record, team rosters and the leaderboard match people by email | `401 TOKEN_CLAIMS_INVALID` ("Credentials are missing identity claims"). Only the local dev proxy papers over it: it asks userinfo, and if that fails it invents `<sub>@example.com`, which will not match the people directory |
| `name` (or `given_name` + `family_name`) | display name on the employee record and the leaderboard | the display name falls back to the part of the email before the `@` |
| `sub` | the stable employee id (ADR-009) | `401 TOKEN_CLAIMS_INVALID` |

**It is not enough that the scope is requested.** The One WSO2 app asks for `openid email groups profile`, and the decoded access token's `scope` line shows all four, yet the token can still carry **no `groups` or `email` value**. The values appear in the access token only when the claims are also added to the application's **Access Token attributes** (step A5). The id_token gets them from the app's User Attributes, which is why it can look right.

**Verify in every environment (step A6), before any deploy:** sign in as a test user, decode the **access** token **locally** (`echo '<token>' | cut -d. -f2 | base64 -d`; never paste a real token into a web decoder), and check `groups`, `email` and `name` are present and `exp - iat <= 3600`. Then call `GET /me` through the proxy: `roles` must list the user's `amplify_*` groups and `capabilities` must be non-empty for a PO.

**Production adds one more place it can break.** The Choreo gateway builds the backend JWT from the access token's claims and may rename them (for example to `http://wso2.org/claims/...`). Set `rolesClaim`, `emailClaim` and `nameClaim` in section C to the names that actually appear in the **backend JWT**, not the access token, and check them with the same decode on a request that reaches the backend.

**Group names must match exactly** between Asgardeo and the `can<Capability>Groups` settings (section C). Names that don't start with `amplify_` are dropped by the local dev proxy.

## A. Asgardeo (non-prod org first, then prod)

- [ ] **A1 Groups.** User Management › Groups › create `amplify_po`, `amplify_marketing`, `amplify_slt`, `amplify_admin` (exact names, same in both orgs). Employees get no group.
- [ ] **A2 Test users (non-prod only).** One user per group plus one with no group. No real employee accounts, no link to prod (ADR-008).
- [ ] **A3 API resource.** API Resources › New: identifier e.g. `amplify-api`, scopes as the proxy needs (per-resource scopes, plan Roles: "enforce twice"). Authorize it for the **One WSO2 SPA** application.
- [ ] **A4 Access token** (One WSO2 SPA › Protocol): token type **JWT**, access-token expiry **≤ 3600 s** (short-lived). Refresh token per One WSO2 standard.
- [ ] **A5 Claims in the access token** (One WSO2 SPA › User Attributes and Access Token attributes): `email`, `name` (or `given_name`/`family_name`; we read one claim, default `name`), and **`groups`**. Mark email as mandatory. **Add them under the Access Token attributes, not only under User Attributes:** the access token omits any claim not listed there.
- [ ] **A6 Verify.** Sign in as a test user, decode the access token **locally** (never paste real tokens into web decoders): `groups` holds the `amplify_*` names, `email` is present, `exp - iat ≤ 3600`. Decode the **id_token** too: it must carry the same `amplify_*` groups, because One WSO2 shows or hides New Post and Current Posts from the id_token, while the API decides from the access token. If only the access token has them, a PO can't see the pages; if only the id_token does, they see the pages and get 403s.

## B. Choreo API proxy (Amplify API Proxy, per environment)

- [ ] **B1** Proxy's key manager = the matching Asgardeo org; subscribe the One WSO2 SPA app.
- [ ] **B2** Enable the **backend JWT** (pass end-user attributes to the upstream) so the proxy sends `x-jwt-assertion`. Include the user claims from A5.
- [ ] **B3** Per-resource scopes from A3 on the proxy resources (first gate).
- [ ] **B4** Backend endpoint = `amplify-api` Project URL. The backend stays Project visibility.

## C. amplify-api config (per environment)

| Key | Value |
| --- | --- |
| `environment` | `dev` / `staging` / `prod` (**never `local` in Choreo**, ADR-023) |
| `gatewayJwksUrl` | JWKS of the Choreo gateway that signs the backend JWT (Choreo docs list it per data plane region) |
| `gatewayIssuer` | `iss` of the backend JWT |
| `gatewayAudiences` | comma-separated `aud` values of the backend JWT (usually the client id of the subscribed app) |
| `rolesClaim` / `emailClaim` / `nameClaim` | claim names as they appear in the **backend JWT** (defaults `groups`, `email`, `name`; the gateway may rename them, e.g. to `http://wso2.org/claims/...`) |
| `jwtHeader` | `x-jwt-assertion` (default) |
| `canCampaignGroups` … `canAdminGroups` | Asgardeo groups per capability, comma separated ([ADR-038](../../architecture/decisions/ADR-038-group-based-access-by-capability.md)). Leave empty for the defaults in the table below. Any one listed group grants the capability |
| `dbHost`, `dbUser`, `dbPassword`, `dbSchema`, `dbSslMode` | the one DB login every component shares, and its schema (empty = the user name); password is a secret (ADR-043) |

Access groups (`BAL_CONFIG_VAR_CAN<CAPABILITY>GROUPS`; defaults in `amplify-api/config.bal`):

| Configurable | Grants | Default |
| --- | --- | --- |
| `canCampaignGroups` | `CAN_CAMPAIGN`: register, edit, archive campaigns; any status | `amplify_po,amplify_marketing` |
| `canDashboardGroups` | `CAN_DASHBOARD`: Dashboarding boards, person popup | `amplify_po,amplify_marketing,amplify_slt,amplify_admin` |
| `canExportGroups` | `CAN_EXPORT`: dashboard CSV (names, emails) | `amplify_po,amplify_marketing,amplify_slt,amplify_admin` |
| `canReviewSharesGroups` | `CAN_REVIEW_SHARES`: external-share queue | `amplify_po` |
| `canPointRulesGroups` | `CAN_POINT_RULES`: point rules | `amplify_po` |
| `canAdjustPointsGroups` | `CAN_ADJUST_POINTS`: adjust/reverse, company Team page, anyone's history | `amplify_po` |
| `canPoDashboardGroups` | `CAN_PO_DASHBOARD`: PO dashboard | `amplify_po` |
| `canReportsGroups` | `CAN_REPORTS`: SLT reports (phase 2) | `amplify_slt,amplify_po` |
| `canAdminGroups` | `CAN_ADMIN`: settings, kill switches, scheduler sync, announcement retry | `amplify_admin` |

- [ ] **C1** Set the keys above in dev.
- [ ] **C2** Call `GET /me` through the proxy as each test user. Expect 200, `roles`, `grants` and `capabilities` matching [activity-matrix.md](../../architecture/solution/Phase%201/activity-matrix.md).
- [ ] **C3** As the no-group user, call `GET /po/dashboard`: expect 403 `ROLE_NOT_PERMITTED` and an `audit.audit_log` row with `outcome = DENIED`.
- [ ] **C4** If you get 401, the problem `code` says why: `TOKEN_ISSUER_INVALID` / `TOKEN_AUDIENCE_INVALID` → set log level DEBUG for `wso2/amplify_api.auth` once; it logs the received `iss` / `aud` (never the token). `TOKEN_CLAIMS_INVALID` → email or sub claim missing (A5/B2 or claim name). 503 `DEPENDENCY_UNAVAILABLE` → JWKS URL unreachable.
- [ ] **C5** Repeat C1–C3 in prod with the prod org.

## D. LinkedIn developer apps

- [ ] **D1 Owner.** LinkedIn has no service or shared accounts: a developer app belongs to a person. Create both apps from a named WSO2 employee's account, add a second WSO2 person as an app admin/developer so the apps survive someone leaving, and record both names here and in the security checklist.
- [ ] **D2 Prod app** associated with the **WSO2 company page**; a page admin approves the association (page-admin verification).
- [ ] **D3 Products** on the prod app: *Share on LinkedIn* (`w_member_social`) and *Sign In with LinkedIn using OpenID Connect* (`openid profile email`).
- [ ] **D4 Redirect URI** (prod): the One WSO2 route from plan D4 (still open; the SDK callback check decides it). Exact match, HTTPS.
- [ ] **D5 Non-prod app**: separate app, separate client id/secret, same products, dev/localhost redirect URIs. **No prod credentials in non-prod.**
- [ ] **D6 Secrets**: client secrets only in Choreo secrets (`LINKEDIN_CLIENT_SECRET` per environment); locally only in `local/.env` (gitignored).
- [ ] **D7** Note the app's API version header (`LINKEDIN_VERSION`) and the token lifetime (≈60 days) in the plan.

## E. Local development tokens

### Option A (preferred): real token from the non-prod Asgardeo org

No APIM needed: point the verifier straight at Asgardeo and send the Asgardeo access token as `x-jwt-assertion`.

1. In `local/.env`: `GATEWAY_JWKS_URL=https://api.asgardeo.io/t/<non-prod-org>/oauth2/jwks`, `GATEWAY_ISSUER=https://api.asgardeo.io/t/<non-prod-org>/oauth2/token`, `GATEWAY_AUDIENCES=<client id of the app you sign in with>`.
2. Get a token: sign in to the local One WSO2 (non-prod app) and copy the access token from the browser dev tools (Application › session storage / the token request), or run the authorization-code + PKCE flow against the non-prod app with a test user.
3. `curl -H "x-jwt-assertion: $TOKEN" http://127.0.0.1:9090/me`

Treat the token as a secret: don't paste it in chats, tickets or web decoders.

### Option B (offline, fixtures): dev-only local signing (ADR-023)

1. `local/dev-jwt/mint-dev-jwt.sh init` (creates `dev-key.pem` + `jwks.json`, both gitignored).
2. `AMPLIFY_DEV_LOCAL_JWT=true` in `local/.env`; compose sets `environment=local` and mounts `local/dev-jwt`.
3. `TOKEN=$(local/dev-jwt/mint-dev-jwt.sh token emp-1 ada@wso2.com amplify_po)`, then call as above. Groups are optional (none = plain employee).

The API refuses to start with this switch unless `environment = local`, `dbSslMode = DISABLE` and `gatewayJwksUrl` starts with `http://localhost` (compose defaults `GATEWAY_JWKS_URL` to `http://localhost:1/unset`, so leave it empty here; a real Asgardeo JWKS URL means Option A, with the switch off). It logs at ERROR when the switch is on.
