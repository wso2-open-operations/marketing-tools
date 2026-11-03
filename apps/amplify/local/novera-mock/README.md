# novera-mock

A Node mock of Novera's gateway. It takes the announcement amplify-jobs sends, logs it, builds the Chat card the way Novera does, and answers 202. Nothing reaches Google Chat.

## What it is and how it is triggered

Run by hand: `node server.mjs` from this folder. Compose does not start it, and it is off until you point amplify-jobs at it. Copy the commented block in `local/.env.example` into `local/.env` instead of the `NOVERA_*` lines (the stack runs in Docker, so the host is `host.docker.internal`):

```
AMPLIFY_ON_NOVERA=true
NOVERA_NOTIFY_URL=http://host.docker.internal:3003/internal/notifications
NOVERA_TOKEN_URL=http://host.docker.internal:3003/token
NOVERA_CLIENT_ID=mock
NOVERA_CLIENT_SECRET=mock
NOVERA_ALLOW_INSECURE_HTTP=true
```

`NOVERA_ALLOW_INSECURE_HTTP` maps to amplify-jobs `noveraAllowInsecureHttp`: local only, never set in Choreo. Then recreate the jobs container: `scripts/compose.sh up -d --build amplify-jobs` (not `make down`, which deletes local data).

The step-by-step is in `docs/HowToTestLocally/TestNovera.md`.

## Routes

All in `server.mjs`.

| Route | What it does |
| --- | --- |
| `POST /token` | Client-credentials token. Answers `{access_token: "mock-token", token_type: "Bearer", expires_in: 3600}` for any caller |
| `POST /internal/notifications` | Logs the JSON body, builds the card, writes `last-card.json` and `last-card-builder.json` to `OUT_DIR`, answers 202 `{accepted: true}`. 400 when the body is not JSON |
| `GET /card` | The last card, or 404 before the first notification |
| `GET /health` | `{status: "ok"}` |

Paste `last-card-builder.json` (the inner card only) into Google's Card Builder to see the real rendering.

## Settings

| Variable | Default | What |
| --- | --- | --- |
| `PORT` | 3003 | Listens on `0.0.0.0` |
| `OUT_DIR` | `./out/` | Where the card files go (gitignored) |
| `CHECK_URL` | empty | A real Novera `POST /internal/notifications` URL. The body is also sent there and its verdict logged: 400 means Novera's schema rejects it, 503 means the schema is fine (no Google key) |

## Files

| File | What |
| --- | --- |
| `server.mjs` | The mock and its card builder |
| `.gitignore` | Ignores `out/` |

## What it does not do

- It does not check tokens, scopes or the notification schema. Use `CHECK_URL` for that.
- It does not send to Google Chat.
- Its card builder is a copy of `buildCard()` in `wso2-digital-agents/po-agent/src/chat/notify.ts`. It can drift from the real one.
