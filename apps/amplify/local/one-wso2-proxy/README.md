# one-wso2-proxy

A small Node proxy that lets a local One WSO2 call the Compose amplify-api. It stands in for the Choreo API proxy and is local only.

```
One WSO2 (localhost:3000) --Bearer token--> :9089 --x-jwt-assertion dev JWT--> :9090 (amplify-api)
```

## What it is and how it is triggered

Run by hand from `apps/amplify` with the stack up: `node local/one-wso2-proxy/proxy.mjs`. Nothing in Compose starts it. It needs Node 18 or later (it uses `fetch`) and `local/dev-jwt/mint-dev-jwt.sh` (run `make env` once so the keys exist).

For each request it:

1. Answers `OPTIONS` with CORS headers for the One WSO2 dev server.
2. Reads `sub`, `email` and `groups` or `roles` from the bearer token. It does not verify the token. Use the access token, never the id token.
3. Mints a dev JWT with `mint-dev-jwt.sh` (cached 20 minutes per sub, email and groups), drops the `Authorization` header and forwards the request with `x-jwt-assertion`.
4. Answers 401 `TOKEN_MISSING` when there is no bearer, and 502 when amplify-api is unreachable.

Only groups that start with `amplify_` are passed on.

## Role switch

Put `po`, `marketing`, `employee` or `token` in the file `local/one-wso2-proxy/role` (gitignored). The default, `token`, uses the groups in the token. `po` gives `amplify_po`, `marketing` gives `amplify_marketing`, `employee` gives no groups. It takes effect on the next request, with no restart.

## Settings

Environment variables.

| Variable | Default | What |
| --- | --- | --- |
| `PORT` | 9089 | Listens on `127.0.0.1` |
| `TARGET_HOST`, `TARGET_PORT` | `127.0.0.1`, 9090 | amplify-api |
| `ORIGIN` | `http://localhost:3000` | The CORS origin |
| `USERINFO_URL` | empty | The identity provider's OIDC userinfo endpoint, asked once per user (cached 30 minutes) when the access token has no email, as with ThunderID. Without it a token with no email maps to `<sub>@example.com` |
| `MINT_SCRIPT` | `../dev-jwt/mint-dev-jwt.sh` | The minting script |

## Files

| File | What |
| --- | --- |
| `proxy.mjs` | The proxy |
| `.gitignore` | Ignores the `role` file |

## What it does not do

- It does not verify tokens. amplify-api's dev JWT mode is itself refused outside `environment=local`, so never run this against a deployed amplify-api.
- It does not log tokens. It logs the claim names, groups and each request's status.
- It does not replace the real gateway checks (audience, issuer, signature).
