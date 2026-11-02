# How to test Amplify locally

How to run the whole of Amplify on your machine: the backend stack, a local One WSO2 signed in with ThunderID or Asgardeo, team rosters, and the real people-app if you want it. Then how to try the phase 1 flows end to end.

Verified on 2026-10-19 from `apps/amplify` (backend, branch `feat/amplify-app`) and `projects/one-wso2` (branch `feat/amplify-people-data`).

Phase 1 (2026-10-19 breakdown) is: Marketing and PO register posts (New Post, Current Posts), new posts go to the Club Chat space, employees link LinkedIn and amplify posts, and everyone sees the individual and team leaderboards (Celebrate).

---

## 1. What runs where

| Piece | Where | Port |
|---|---|---|
| amplify-api, amplify-jobs, scheduler, Postgres ×2, mock LinkedIn, chat-stub, people-stub | Docker Compose, `apps/amplify` | api 9090, mock LinkedIn 19091, people-stub 19092 |
| Dev proxy (stands in for the Choreo API proxy) | `node local/one-wso2-proxy/proxy.mjs` | 9089 |
| One WSO2 | `npm run dev` in `projects/one-wso2/webapp` | 3000 |
| Real people-app (optional) | `local/people-app-proto/run.sh up` | gateway 19093, people-app 19094 |

The browser talks to One WSO2 on :3000. One WSO2 calls the dev proxy on :9089 with your sign-in token. The proxy swaps that token for a local dev JWT (`x-jwt-assertion`, the way the Choreo gateway does it) and forwards to amplify-api on :9090.

## 2. Prerequisites

Docker, Node 22, `bal` (Ballerina 2201.13.3), `curl`, `jq`, `openssl`, and a sign-in for One WSO2:

- **ThunderID:** a client id and the server's discovery URL (`https://<host>/.well-known/openid-configuration`). The client needs `http://localhost:3000` as redirect URL and allowed origin, and the `groups` scope.
- **Asgardeo:** see [TestOneWSO2.md](TestOneWSO2.md) §3.

For the PO/Marketing screens, put your test user in `amplify_po` or `amplify_marketing` at the IdP.

## 3. Start the backend

```bash
cd apps/amplify
make up        # first run writes local/.env and the dev-JWT keys, builds images, starts everything
```

The Compose project is always `wso2-amplify`, so your data survives restarts. `make down` **deletes the volumes**; use `docker compose --env-file local/.env stop` to stop without losing data.

Team rosters come from people-stub. `make env` (run by `make up`) copies the sample to `local/people-stub/directory.json` the first time (the real file is gitignored, so keep real names and emails out of commits). Then edit `local/people-stub/directory.json`: it's re-read on every call, but amplify-api keeps its team index for 24 hours, so restart amplify-api after an edit (`docker compose --env-file local/.env restart amplify-api`). Match `workEmail` to the email your sign-in reaches Amplify with (step 4).

## 4. Start the dev proxy

```bash
# ThunderID's access token has no email claim, so let the proxy look it up:
USERINFO_URL=https://<thunder-host>/oauth2/userinfo node local/one-wso2-proxy/proxy.mjs
```

- Roles come from the token's `groups` (or `roles`). To try another role without changing the IdP, write `po`, `marketing`, `employee` or `token` into `local/one-wso2-proxy/role` (git-ignored); it applies on the next request.
- The proxy logs each token's claim names and the identity it forwards. If a user shows up as `<sub>@wso2.com`, the token had no email and `USERINFO_URL` isn't set.

## 5. Configure and start One WSO2

`projects/one-wso2/webapp/public/config.js` (git-ignored):

```js
window.config = {
  ONE_WSO2_AUTH_BASE_URL: "https://<thunder-host>",
  ONE_WSO2_AUTH_CLIENT_ID: "<client-id>",
  // Set for ThunderID (or any server outside Asgardeo's URL layout): One WSO2 then signs in through
  // ThunderProvider. Leave it out for Asgardeo.
  ONE_WSO2_AUTH_WELL_KNOWN_URL: "https://<thunder-host>/.well-known/openid-configuration",
  ONE_WSO2_AUTH_SIGN_IN_REDIRECT_URL: "http://localhost:3000",
  ONE_WSO2_AUTH_SIGN_OUT_REDIRECT_URL: "http://localhost:3000",
  ONE_WSO2_THEME: "wso2",
  ONE_WSO2_PEOPLE_BACKEND_URL: "http://localhost:19092",      // people-stub: photos and names
  ONE_WSO2_AMPLIFY_BACKEND_URL: "http://localhost:9089",      // the dev proxy
  ONE_WSO2_AMPLIFY_LINKEDIN_ORG_URN: "urn:li:organization:1477",
  // LinkedIn plus the mock: post links and the "Link me" redirect may only go to these origins.
  ONE_WSO2_AMPLIFY_POST_LINK_ORIGINS: ["https://www.linkedin.com", "https://linkedin.com", "http://localhost:19091"],
  ONE_WSO2_PREVIEW_FEATURES: { amplify: true },
};
```

Then `npm run dev` in `webapp/` and open http://localhost:3000/amplify/celebrate. With the people backend set to the stub, other people-app screens (Me, Org Chart) show errors; that's expected.

## 6. Try the phase 1 flows

1. **New Post** (PO or Marketing): paste a LinkedIn post URL (`/feed/update/urn:li:share:…` or a copy-link `/posts/…-activity-…`), headline, summary, category, priority. **Save & share now** starts a run; the card shows in chat-stub (`docker compose --env-file local/.env logs chat-stub`).
2. **Current Posts:** Update post edits the card fields; Create new post goes back to New Post.
3. **Celebrate:** posts to amplify (priority first; gone once you've shared them all), top three, my position, team leaderboard.
4. **Amplify** on a card: not linked → the "Link your LinkedIn account" popup → mock consent on :19091 → back on Celebrate with the share dialog open. Linked → the share dialog. The share posts on the next run (every 5 minutes, or `make e2e` style `POST /runs`), and points follow.
5. **Team leaderboard:** your directory sub-team, ranked; people with no points count toward the headcount but aren't listed.

## 7. Seed demo data

Give made-up teammates points so the leaderboards have something to show (PO adjustments through the API, the same audited path PO uses):

```bash
M=local/dev-jwt/mint-dev-jwt.sh
PO=$($M token seed-po seed.po@wso2.com amplify_po)
for row in demo-avery:avery.demo@wso2.com:25 demo-blake:blake.demo@wso2.com:18; do
  IFS=: read id email pts <<<"$row"
  curl -s -o /dev/null -H "x-jwt-assertion: $($M token $id $email)" localhost:9090/me   # registers them
  curl -s -X POST -H "x-jwt-assertion: $PO" -H 'Content-Type: application/json' \
    -H "Idempotency-Key: demo-$id" -d "{\"employeeId\":\"$id\",\"points\":$pts,\"reason\":\"Demo seed\"}" \
    localhost:9090/po/points/adjustments
done
```

Their emails must be in `directory.json` (on your sub-team) to show on your team leaderboard.

## 8. Use the real people-app (optional)

`local/people-app-proto/run.sh up` builds people-app from `projects/people-ops-suite` (in its own Ballerina image), runs it on MySQL 8.0 behind a gateway stand-in, and points amplify-api at it as a service client. `run.sh demo` runs 11 checks; `run.sh off` shows the behaviour before the service-client change; `run.sh down` puts amplify-api back on people-stub. The people-app change itself lives in people-ops-suite.

## 9. Tests

```bash
make check                                   # descriptors, log PII, transaction gate
TIERS="unit it scheduler" scripts/test-all.sh   # safe with the stack up (api tests use port 19590)
make e2e                                     # against the running stack
```

`scripts/test-all.sh` with no `TIERS` also runs the e2e tier, which ends with `make down` and **deletes your local data**.

`make e2e` on a stack someone has used: the mock has one LinkedIn member, and once an employee has linked it, it stays theirs (B13). e2e then runs its employee steps as that person, so they get the e2e share and its points. Archive the `E2E campaign …` posts afterwards if you don't want them on Celebrate.

## 10. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Sign-in loops or never completes with ThunderID | `ONE_WSO2_AUTH_WELL_KNOWN_URL` missing, or site data still holds Asgardeo-style endpoints: clear site data for localhost:3000 |
| "We couldn't find your team" | Your Amplify email doesn't match a `workEmail` in the directory. Check the proxy log for the email it forwards; set `USERINFO_URL` |
| New Post / Current Posts missing from the menu | Your token has no `amplify_po` / `amplify_marketing` in `groups` (the menu reads the id_token). Add the group at the IdP and sign in again |
| "My position" shows someone else's numbers | Fixed 2026-10-19 (per-viewer ETag). If you see it, you're on an old amplify-api image: `make up` |
| `MEMBER_ALREADY_LINKED` when linking | The mock's one LinkedIn member already belongs to another local employee (B13). Link as that user, or reset local data with `make down && make up` |
| "Link me" does nothing, or New Post says "Paste the link to a post on LinkedIn" for a mock URL | The mock's origin (`http://localhost:19091`) isn't in `ONE_WSO2_AMPLIFY_POST_LINK_ORIGINS` (UI) or `CAMPAIGN_LINK_ORIGINS` (amplify-api; Compose includes it by default) |
| Celebrate shows "Amplify isn't connected yet" | `ONE_WSO2_AMPLIFY_BACKEND_URL` isn't set, or the `amplify` preview flag is off |
