# chat-stub

A local stand-in for the Google Chat incoming webhook. It records every card amplify-jobs posts and can answer with a scripted failure. Nothing reaches Google Chat. Ballerina package `amplify_chat_stub`.

## What it is and how it is triggered

The Compose service `chat-stub` (`compose.yaml`) starts it with `make up`. amplify-jobs posts to it because the default `chatWebhookUrl` in Compose is `http://chat-stub:9095/v1/spaces/local/messages?key=local&token=local`. Nothing else starts it. It has no host port: reach it with `docker compose exec chat-stub wget -qO- localhost:9095/stub/messages`.

To see real cards, set `GOOGLE_CHAT_WEBHOOK_URL` in `local/.env` to the dev test space's webhook (never the Club). See `local/google-chat-webhook.md`.

## Routes

All in `main.bal`.

| Route | What it does |
| --- | --- |
| `POST /v1/spaces/{space}/messages` | Takes a card like the Chat API does. Query parameters `threadKey` and `messageReplyOption` are recorded. Answers 200 with `{name, thread: {name}}`, or a scripted error status |
| `PUT /stub/status/{code}` | Sets the sticky status (200 to 599) every later call gets. 400 outside that range |
| `GET /stub/messages` | Lists the last received messages: space, `threadKey`, `messageReplyOption`, status, card body |
| `DELETE /stub/messages` | Clears the list |

A space named `status-NNN` (for example `status-429`) answers with that status for that call, and wins over the sticky status.

## Settings

| Setting | Default | What |
| --- | --- | --- |
| `port` | 9095 | Listener port |
| `defaultStatus` | 200 | Status when nothing else is set |
| `keepMessages` | 50 | How many messages `GET /stub/messages` keeps |

## Files

| File | What |
| --- | --- |
| `main.bal` | The service, the status logic, the response body |
| `tests/stub_test.bal` | Tests: it answers like Chat and keeps the card; scripted status |
| `Dockerfile` | Builds the jar, runs it as UID 10014 on port 9095 |
| `Ballerina.toml`, `Dependencies.toml`, `.dockerignore` | Package and build files |

## Run and test

```sh
bal test     # from this folder
bal run      # port 9095
```

Watch cards in the Compose stack: `docker compose logs -f chat-stub`.

## What it does not do

- It does not check the card against the Chat schema or render it.
- It does not check the webhook key or token.
- It keeps messages in memory only. A restart clears them.
