# Mock LinkedIn (Share on LinkedIn + OAuth 2.0)

A local Ballerina mock of the LinkedIn APIs a self-serve app gets with **Share on LinkedIn**
(`w_member_social`) and **Sign In with LinkedIn using OpenID Connect** (`openid profile email`).
Use it to build and test Amplify without a real LinkedIn app, real members, or real posts.

Contract: [`w-member-social.openapi.yaml`](../../resources/openapi/openapi/w-member-social.openapi.yaml).
Request and response types in `types.bal` are generated from it with `bal openapi`.

## Hosts

The mock runs two listeners, one per LinkedIn host, so your app's base URLs swap cleanly.

| Real host | Mock | Serves |
|---|---|---|
| `https://api.linkedin.com` | `http://localhost:9090` | `/v2/userinfo`, `/rest/posts`, `/rest/images`, `/v2/ugcPosts`, `/v2/assets`, `/health` |
| `https://www.linkedin.com` | `http://localhost:9091` | `/oauth/v2/authorization`, `/oauth/v2/accessToken`, `/dms-uploads/...` |

## Run

```bash
cp Config.toml.local Config.toml   # then set clientId, clientSecret, redirectUris
bal run
```

Both listeners bind to `localhost` by default. Set `listenerHost = "0.0.0.0"` to run it in a container.

Tests start both listeners on ports 19090/19091 using `tests/Config.toml`:

```bash
bal test
```

## OAuth 2.0 flow

Same 3-legged authorization code flow as LinkedIn. There is no login or consent page: every
authorization signs in as the configured `member` and approves straight away.

1. Send the browser to the authorization endpoint:

   ```
   http://localhost:9091/oauth/v2/authorization?response_type=code&client_id=<clientId>&redirect_uri=<registered uri>&state=<state>&scope=openid%20profile%20w_member_social
   ```

   The mock redirects to `redirect_uri?code=AQ...&state=...`.

2. Exchange the code (form encoded, single use, valid 30 minutes):

   ```bash
   curl -s http://localhost:9091/oauth/v2/accessToken \
     -d grant_type=authorization_code -d code=<code> -d redirect_uri=<uri> \
     -d client_id=<clientId> -d client_secret=<clientSecret>
   ```

   ```json
   {"access_token": "AQ...", "expires_in": 5184000, "scope": "openid,profile,w_member_social", "token_type": "Bearer"}
   ```

3. Call the API with `Authorization: Bearer <access_token>`.

Rules the mock enforces, matching LinkedIn:

- `client_id` and `redirect_uri` must match the config exactly, or you get a `400` and no redirect.
- Unsupported scopes (anything other than `w_member_social`, `openid`, `profile`, `email`)
  redirect back with `error=unauthorized_scope_error`.
- Add `mock_consent=deny` to simulate the member cancelling (`error=user_cancelled_authorize`).
  This parameter is mock only.
- Tokens last 60 days. There are no refresh tokens.
- Issuing a token with a **different scope set** revokes the member's earlier tokens.

## Share API behaviour

| Call | Needs | Mock behaviour |
|---|---|---|
| `GET /v2/userinfo` | `openid` + `profile` | Returns the configured member. `email` only with the `email` scope. |
| `POST /rest/posts` | `w_member_social` | `201` with `x-restli-id: urn:li:share:{19 digits}`. Supports text, image, article and reshare. |
| `POST /rest/posts/{urn}` | `w_member_social` | `X-RestLi-Method: PARTIAL_UPDATE`. `204`, or `404` if unknown. |
| `DELETE /rest/posts/{urn}` | `w_member_social` | Idempotent `204`. |
| `POST /rest/images?action=initializeUpload` | `w_member_social` | Returns an `uploadUrl` on the www host and an `urn:li:image:` URN. |
| `PUT /dms-uploads/...` | `w_member_social` | Upload the bytes with the same bearer token. `201`, or `413` past `maxUploadBytes` (10 MB by default). |
| `POST /v2/ugcPosts` | `w_member_social` | Legacy share. `NONE`, `ARTICLE` or `IMAGE`. `201` with `x-restli-id`. |
| `DELETE /v2/ugcPosts/{urn}` | `w_member_social` | Idempotent `204`. |
| `POST /v2/assets?action=registerUpload` | `w_member_social` | Returns an `uploadUrl` and an `urn:li:digitalmediaAsset:` URN. |

Validation that returns LinkedIn-style errors (`{"status", "message", "serviceErrorCode"}`):

- `401` for a missing, unknown, revoked or expired token.
- `403` when the token lacks the scope, or `author`/`owner` is not the signed-in member.
- `400` when `X-Restli-Protocol-Version: 2.0.0` is missing, or `LinkedIn-Version` is missing on `/rest/*`.
- `400` for an image that was never uploaded, both `media` and `article`, a bad article URL, an article without a `title`,
  or commentary over 3,000 characters.
- `403` when resharing a mock post created with `isReshareDisabledByAuthor: true`.
  Reshare parents the mock never saw (real company posts) are accepted.
- `422` for the same text from the same member within 10 minutes.
- `429` past 150 calls per member, or 100,000 per app, per UTC day.
- `413` for an upload body over `maxUploadBytes`. The body is read in chunks and refused as soon as it
  passes the limit, so an oversized upload is never held in memory in full.

A body, header or query parameter that doesn't match the contract gets a generic `400`.
The exact binding error goes to the debug log, not the caller.

URNs in paths can be URL encoded (`urn%3Ali%3Ashare%3A123`) as LinkedIn requires.
Every response on both hosts carries an `x-li-uuid` correlation id that also appears in the logs.

## Admin endpoints (local only)

With `enableMockAdmin = true` (off by default) and `mockAdminKey` set to at least 32 characters, the API
listener also serves:

- `GET /mock/posts` lists every post the mock holds.
- `POST /mock/reset` clears tokens, codes, posts, uploads and rate counters.

Every call must carry the key in `X-Amplify-Internal-Key`, the same header amplify-jobs uses for its own
endpoints; a missing or wrong key gets a `401`. With the flag on but no usable key, the endpoints are not
attached at all, so a missing secret can never leave them open. Don't turn them on anywhere but your
machine or CI: the Choreo descriptor has no field for the flag, so a deployed mock never serves them.

## Limits

- All state is in memory and gone on restart.
- No `id_token` in the token response. Call `/v2/userinfo` for the member id.
- Error codes and messages are close to LinkedIn's but not guaranteed identical.
- `GET /v2/userinfo` can return `403` (token without `openid profile`). The spec lists only `401`.
- The legacy assets flow uses the same `/dms-uploads` upload host as `/rest/images`.
- `CreateUgcPost` in `mock_types.bal` is written by hand because the OpenAPI tool fails on
  its dotted `com.linkedin.ugc.*` property names.
