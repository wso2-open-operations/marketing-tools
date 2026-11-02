# Test Novera locally

Novera (internal codename PO Agent) is the Google Chat agent in `projects/wso2-digital-agents/po-agent`. It's a Node/TypeScript Express app with MySQL, Anthropic Claude and Asgardeo, and it's registered as a **Google Workspace add-on**. This guide covers running it on your machine and testing it without the production Chat app.

Source of truth: `po-agent/CLAUDE.md` (quick start), `RUNBOOK.md`, `docs/google-setup.md`, `SECURITY.md`, `src/config.ts`. Line references below are as of 2026-10-16.

> Heads-up: Novera and One WSO2 both default to **port 3000**. If you run them together, start Novera with a different port and use it in its Asgardeo redirect URI. `3001` is a good choice unless something already holds it: on Lead Developer's machine a Colima SSH forward does, so the examples below use **3002**.

---

## 1. Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| Node | **20** | The Dockerfile uses `node:20-alpine`. There's no `.nvmrc`, so Node 22 probably works too, but 20 matches production |
| MySQL | **8.x** | The schema uses JSON columns, `PREPARE` and `CREATE EVENT`, and needs `event_scheduler=ON`. Your Homebrew MySQL 9.7 will probably work, but `mysql:8.4` in Docker matches the managed DB better |
| mysql CLI | any | Used to load the schema |
| A tunnel (cloudflared or ngrok) | optional | Only for end-to-end tests with a real Chat app (step 7). Neither is installed on this machine yet |

There's **no test or lint script** in `package.json`, and CLAUDE.md says not to make one up. The checks are `npm run build` (tsc) plus the manual tests below.

## 2. Database

```bash
# Option A: Docker (matches prod most closely)
docker run -d --name novera-mysql -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=devpass mysql:8.4 --event-scheduler=ON

# Load the schema (it creates the po_agent database itself)
mysql -h 127.0.0.1 -u root -pdevpass < projects/wso2-digital-agents/po-agent/src/db/schema.sql
```

- `schema.sql` hard-codes `CREATE DATABASE po_agent; USE po_agent` (lines 1–2), so keep `DB_NAME=po_agent` unless you edit it.
- It's idempotent, with inline migrations. There's no seed data: the policy, training and menu tables fill themselves at runtime.
- **Don't** run `scripts/backfill-dm-spaces.mjs` locally. It's a production ops tool and its output contains personal data.

## 3. `.env`

```bash
cd projects/wso2-digital-agents/po-agent
npm install
cp .env.example .env
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"   # → TOKEN_ENCRYPTION_KEY
```

The app **fails fast** on any missing required variable, including variables for features you've turned off. Fill it in like this:

| Group | Local value |
| --- | --- |
| **Must be real** | `ANTHROPIC_API_KEY` (or point `ANTHROPIC_BASE_URL` at a mock), `TOKEN_ENCRYPTION_KEY` (64 hex chars), `DB_HOST=127.0.0.1`, `DB_USER=root`, `DB_PASSWORD=devpass` |
| **Change from the example** | `DB_SSL=false`, `TRUST_PROXY=false` (the example's `true` is wrong outside a proxy; see SECURITY.md MEDIUM-1), `HR_POLICY_SYNC_ENABLED=false`, `TRAINING_SYNC_ENABLED=false`, `PORT=3001` if One WSO2 is running |
| **Asgardeo (for /connect)** | Client ID and secret for a **non-prod Asgardeo** app with redirect `http://localhost:3002/auth/callback`, and `ASGARDEO_REDIRECT_URI` set to exactly that. Scopes requested: `openid email groups offline_access` |
| **Placeholders are fine** | `LETTER_REQUEST_FORM_URL`; the `LEAVE_`, `MENU_`, `PEOPLE_`, `RELEASES_` and `SUBSCRIPTION_BACKEND_URL` variables; `CHOREO_TOKEN_ENDPOINT`, `CHOREO_CLIENT_ID` and `CHOREO_CLIENT_SECRET` (required but never used); the four `HR_POLICY_*` Google values; `ISSUES_SHEET_ID`; `TRAINING_TEAM_EMAIL`, `CERTIFICATION_TEAM_EMAIL`, `TRAINING_TEAM_LEADS` |
| **Webhook auth** | `GOOGLE_CHAT_WEBHOOK_AUDIENCE` and `GOOGLE_CHAT_WEBHOOK_CALLER_EMAIL`. See step 5 for the local values |
| **Optional** | `GOOGLE_SERVICE_ACCOUNT_KEY`. Without it, every Chat API send is skipped with a warning (`proactive.ts:24-26`), so async replies show up only in the logs |

`LOG_LEVEL=debug` logs raw backend response bodies. Use it locally only, and never paste those logs anywhere.

> Pick one `TOKEN_ENCRYPTION_KEY` and keep it. Changing it later silently wipes linked users' tokens and conversation history on next read (RUNBOOK.md:197-224).

## 4. Run it

```bash
npm run dev            # ts-node src/index.ts
# or
npm run build && npm start
curl http://localhost:3002/health        # → {"status":"ok"}
```

On boot it starts the hourly and daily purge timers, and runs any syncs you've enabled (retrying at 0 s, 30 s and 2 min).

## 5. Call the webhook without Google Chat

`POST /webhook` only accepts a Bearer **Google-signed ID token** whose `iss` is `https://accounts.google.com`, whose `aud` equals `GOOGLE_CHAT_WEBHOOK_AUDIENCE`, and whose `email` equals `GOOGLE_CHAT_WEBHOOK_CALLER_EMAIL` (`index.ts:73-113`). There's no bypass flag, so keep it that way.

**Without changing any code (recommended):** mint a real Google ID token for a test service account and point the two variables at it.

```bash
# One-time: a test service account in a non-prod GCP project. You need
# roles/iam.serviceAccountTokenCreator on it.
SA=novera-local-test@<test-project>.iam.gserviceaccount.com

# .env:
#   GOOGLE_CHAT_WEBHOOK_AUDIENCE=http://localhost:3002/webhook
#   GOOGLE_CHAT_WEBHOOK_CALLER_EMAIL=$SA

TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account="$SA" \
  --audiences="http://localhost:3002/webhook" --include-email)
```

I haven't tried this yet. The token carries `iss=accounts.google.com`, `aud` = the audience you asked for, and `email` = the service account, which is everything the middleware checks.

**Fallback:** patch `verifyChatRequest` to `next()` in a local-only change. **Never commit it** (SECURITY.md MEDIUM-3 explains why the check exists).

**A sample event** (shape from `src/types.ts:66-123`). Save it as `event.json`:

```json
{
  "commonEventObject": { "hostApp": "CHAT" },
  "chat": {
    "user": { "name": "users/123", "displayName": "Test User", "email": "test.user@wso2.com", "type": "HUMAN" },
    "eventTime": "2026-10-16T10:00:00Z",
    "messagePayload": {
      "space": { "name": "spaces/LOCAL1", "spaceType": "DIRECT_MESSAGE" },
      "message": {
        "name": "spaces/LOCAL1/messages/m1",
        "sender": { "name": "users/123", "displayName": "Test User", "email": "test.user@wso2.com" },
        "text": "/help",
        "slashCommand": { "commandId": "5" },
        "thread": { "name": "spaces/LOCAL1/threads/t1" }
      }
    }
  }
}
```

```bash
curl -s -X POST http://localhost:3002/webhook \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data @event.json | jq .
```

What comes back:

| Message | Response |
| --- | --- |
| `addedToSpacePayload` (bot added), `/connect` (`commandId: "4"`), `/help` (`"5"`) | Reply **in the HTTP response** (`hostAppDataAction…createMessageAction`) |
| Free text, `/leave` (`"1"`), `/status` (`"3"`) | `{}` in the response. The real reply is posted later through the Chat REST API, which needs `GOOGLE_SERVICE_ACCOUNT_KEY`. Without it, read the logs |
| An unlinked user | An "authorize" card. Unlinked users never reach Anthropic |

Limits: 16 KB body, attachments rejected, and a per-user rate limit.

## 6. Other endpoints

- **`GET /auth/callback?code&state`** completes `/connect`. Run `/connect`, open the `oauth2/authorize` URL from the reply in a browser, and sign in to non-prod Asgardeo. You come back to `localhost:3002/auth/callback`, and the encrypted tokens land in `agent_user_tokens`. After that, the same `users/123` email counts as linked. `state` is single-use and lasts 10 minutes, and the endpoint is limited to 30 requests a minute per IP.
- **`POST /internal/notifications`** (Amplify's announcement path, and the one TIL uses; the schema is in `.choreo/openapi.yaml`). In Choreo the gateway subscription is its only protection, so locally there's **no auth**:
  ```bash
  curl -i -X POST http://localhost:3002/internal/notifications -H "Content-Type: application/json" \
    -d '{"source":"local-test","title":"Hello","body":"Test card","link":{"url":"https://wso2.com","label":"Open"}}'
  # → 202 with a Google key; 503 without one (nothing sent). A 400 means the schema rejected it.
  # It broadcasts to every row in agent_dm_spaces, which is empty locally unless you seed one
  ```
  Fields: `source`, `title`, `body` (required); `subtitle`, `footer`, `link {url,label}`, `iconUrl` (https, beside the title), `imageUrl` (https, full width under the title) and `button {url,label}` (a button under the body). `imageUrl` and `button` are new (branch `feat/notification-image-button` in `wso2-digital-agents`) and a Novera without that change answers 400 `Unknown field`. Chat fetches images itself, so they must be public https.

## 7. Backends, Claude and the real Chat app

- **Backends** (leave, menu, people, releases, subscription) get `Authorization: Bearer <id_token>`. None is called at startup, so placeholder URLs boot fine and tool calls just fail and log. To exercise a tool, point its URL at a local mock. The per-tool identity guard compares the id_token email with the linked user's email, so a mock needs a JWT-shaped id_token that carries `email`.
- **Claude:** set `ANTHROPIC_BASE_URL` to a mock or proxy to test without spending tokens (it warns when the URL isn't https). Per-user quota: `USER_TOKEN_QUOTA_PER_DAY` (50k).
- **Issues sheet** reads on every turn. It fails open, so a placeholder `ISSUES_SHEET_ID` is fine.
- **End-to-end in real Google Chat:** you need a public HTTPS URL (`cloudflared tunnel --url http://localhost:3002`) and a **separate test add-on deployment in a non-prod GCP project** pointing at it. Never repoint the production add-on. `docs/google-setup.md` covers the service account and caller-email setup for Choreo, and the same steps apply to a test project.

## 8. Docker (same image as Choreo)

```bash
docker build -t novera:local projects/wso2-digital-agents/po-agent
docker run --rm -p 3001:3000 --env-file projects/wso2-digital-agents/po-agent/.env \
  -e DB_HOST=host.docker.internal novera:local
curl http://localhost:3002/health
```

The image runs as UID 10014 (inside the 10000–20000 range Choreo needs) and exposes 3000. There's no HEALTHCHECK; `/health` is the smoke test. `.env` isn't copied into the image (`.dockerignore`), so always pass `--env-file`.

## 9. Rules to keep while testing

- Don't log or store message payloads in the audit tables, and don't remove the identity guards (CLAUDE.md:62-70, SECURITY.md:167-183).
- `DB_SSL=true` uses `rejectUnauthorized:false`. That's fine for the managed DB but worth knowing.
- `/help` calls the people backend for linked users, so expect a logged failure there with placeholder URLs.

---

## 10. Try Amplify's announcement without posting to anyone

Amplify announces a new campaign by calling Novera's `POST /internal/notifications`. In production that reaches **every** employee who has a chat open with Novera, so never point a laptop at the production gateway or its client credentials. Two safe setups, cheapest first.

### A. The mock (no Google, no Novera needed)

Code: BechtelCanDoIt/marketing-tools PR #12 (`feat/amplify_on_novera`). It needs Novera's `imageUrl` and `button` fields (BechtelCanDoIt/wso2-digital-agents PR #1) deployed first in any real environment.

`apps/amplify/local/novera-mock/server.mjs` stands in for the gateway. It answers `POST /token` and `POST /internal/notifications`, logs each notification's JSON, and replies 202. Nothing reaches Google Chat.

```bash
cd apps/amplify/local/novera-mock
# optional: also check each body against a local Novera's schema (400 = rejected, 503 = accepted, no Google key)
CHECK_URL=http://localhost:3002/internal/notifications node server.mjs      # :3003
```

The mock is off by default: nothing uses it until you start it and set these in `local/.env`. `local/.env.example` carries them as a commented-out block; copy them in **instead of** the `NOVERA_*` lines (the stack runs in Docker, so the host is `host.docker.internal`). Then recreate the jobs container:

```
AMPLIFY_ON_NOVERA=true
AMPLIFY_ON_WEBHOOK=false
NOVERA_NOTIFY_URL=http://host.docker.internal:3003/internal/notifications
NOVERA_TOKEN_URL=http://host.docker.internal:3003/token
NOVERA_CLIENT_ID=mock
NOVERA_CLIENT_SECRET=mock
NOVERA_ALLOW_INSECURE_HTTP=true        # local only, default false, never set in Choreo; amplify-jobs otherwise insists on https
```

```bash
cd apps/amplify
scripts/compose.sh up -d --build amplify-jobs        # not `make down`: that deletes local data
```

Register a campaign (New Post in One WSO2, or `POST /campaigns`, see `TestAmplify.md`). When the scheduler fires the run, the mock logs the notification. Amplify's Novera path is `handleCampaignRegistered` in `amplify-jobs/handlers.bal`, the client is `amplify-jobs/novera.bal`, and the notification is built by `buildNoveraNotification` in `amplify-domain/modules/announcements/service.bal`.

What Amplify sends:

| Field | Value |
| --- | --- |
| `source` | `amplify` |
| `title` / `subtitle` | The campaign title; `Amplify` (or `Amplify · Priority`) |
| `body` | The campaign summary, or "A new post is ready to share." |
| `iconUrl` | `GOOGLE_CHAT_AVATAR_URL`, when https |
| `imageUrl` | The campaign image, else `GOOGLE_CHAT_DEFAULT_IMAGE_URL`, only when Chat can fetch it (public https; `localhost`, `.local`, `.internal` and plain http are dropped) |
| `button` | `Amplify`, opening `AMPLIFY_SHARE_PAGE_BASE_URL?share=<campaignId>` |

Novera answers 202 before it sends anything, so Amplify keeps no Chat message name. A 503, 429, 5xx or no answer is retried by the outbox; any other 4xx fails the announcement (a 400 usually means Novera isn't running the version with `imageUrl` and `button` yet). The token is requested on the first notification, not at start-up, so a Novera outage never stops amplify-jobs from starting.

### B. See the card in a browser

The mock also builds the Chat card exactly as Novera's `buildCard` does, and writes it next to the log (`OUT_DIR`, default `local/novera-mock/out/`, which is gitignored) and at `GET http://localhost:3003/card`.

1. Open Google's Card Builder: <https://addons.gsuite.google.com/uikit/builder>.
2. Paste **`last-card-builder.json`**: the inner `card` only (`{"sections": [...]}`). The builder rejects the full Chat message in `last-card.json` (`{"cardsV2": [...]}`) with "Unknown field in Card JSON".

The mock's card builder is a port of `po-agent/src/chat/notify.ts`. Re-sync it if that file changes.

### C. A real card in your own Chat DM

Needs a **non-prod** setup, because posting to a DM requires the bot's own service account:

1. A test Google Cloud project with its own Workspace Add-on and service account (never the production add-on; see step 7 and `docs/google-setup.md`).
2. Install the test add-on for yourself only, DM it once, and note your DM space name (`spaces/...`).
3. Seed only that row (a placeholder row is fine to start, as the mock path never uses it):
   ```bash
   docker exec novera-mysql mysql -uroot -pdevpass -e "INSERT INTO po_agent.agent_dm_spaces (space_name, display_name, email) VALUES ('spaces/XXXX','Your Name','you@wso2.com') ON DUPLICATE KEY UPDATE email=VALUES(email)"
   ```
4. Put the test project's key in Novera's `.env` as `GOOGLE_SERVICE_ACCOUNT_KEY`, and point Amplify's `NOVERA_NOTIFY_URL` at `http://host.docker.internal:3002/internal/notifications` (with `NOVERA_ALLOW_INSECURE_HTTP=true`).

Because `agent_dm_spaces` holds only your row, a broadcast can reach only you. Check `SELECT COUNT(*) FROM agent_dm_spaces` is 1 before every send.

### Local Novera database in one line

```bash
docker run -d --name novera-mysql -p 3306:3306 -e MYSQL_ROOT_PASSWORD=devpass mysql:8.4 --event-scheduler=ON
docker exec -i novera-mysql mysql -uroot -pdevpass < projects/wso2-digital-agents/po-agent/src/db/schema.sql
```
