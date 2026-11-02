# Runbook: Google Chat incoming webhooks (Club announcements)

Status: Draft (2026-10-16). Code side done in M6a (card builder, client, throttle, chat-stub, tests); the console steps below are still open in the [plan](../requirements/phase1-planned-todos.md) M6a.
Owner: Amplify technical owner. Dev test space first, test, then the WSO2 Club space.

`amplify-jobs` config keys referenced below live in `projects/marketing-tools/apps/amplify/amplify-jobs/config.bal` (Choreo: Configs & Secrets; local: `BAL_CONFIG_VAR_*` via `compose.yaml` / `local/.env`).

**The webhook URL is a secret.** It looks like `https://chat.googleapis.com/v1/spaces/SPACE/messages?key=…&token=…` and anyone holding it can post into the space as "Amplify". Never log it, never paste it into chat, tickets, PRs, screenshots or `Config.toml` in git. The code never logs it and never puts it in errors or `announcement.last_error` (tests: `webhookErrorsNeverCarryTheUrl`, `webhook400FailsOnceWithoutRetryStorm`). It also never reaches a trace: the Ballerina HTTP client would stamp the URL on its client span as `http.url`, so the webhook call goes through the JDK HTTP client (`amplify-common/modules/googlechat/transport.bal`), which is not instrumented. Do not switch it back to `http:Client` (`scripts/check-chat-transport.sh` fails the build).

## A. Workspace admin (once)

- [ ] **A1** Admin console › Apps › Google Workspace › Google Chat › **Chat apps** › "Allow users to add and use incoming webhooks" = **On** (for the OU that owns the spaces). Needs a Workspace admin.

## B. Create the webhooks (web Chat only; the mobile app can't)

Use the **team/common Amplify owner account** (not a personal account), so the webhook survives people leaving. Webhooks belong to the space, but only members can manage them.

- [ ] **B1 Dev test space.** Create a space, e.g. "Amplify dev test", with the common account plus the dev team.
- [ ] **B2 Add the webhook** (repeat for each space): open the space in **chat.google.com** › space name ▾ › **Apps & integrations** › **Add webhooks** › Name `Amplify`, Avatar URL = the public HTTPS Amplify avatar (same value as `chatCardAvatarUrl`) › **Save** › **Copy link**. Paste straight into B3; don't park it in a note.
- [ ] **B3 WSO2 Club space.** Same as B2 in the Club space, with the common account as a member. Only after the dev space checks in D pass.

## C. Store the URL (per environment)

| Environment | Key | Value |
| --- | --- | --- |
| dev / staging | `chatWebhookUrl` (**secret**) | dev test space webhook |
| dev / staging | `chatSpace` | `dev-test` |
| prod | `chatWebhookUrl` (**secret**) | WSO2 Club webhook |
| prod | `chatSpace` | `club` |
| all | `chatCardAvatarUrl` | public HTTPS Amplify avatar (optional) |
| all | `chatDefaultImageUrl` | public HTTPS **PNG or JPEG** shown on a card when the post has no image or an unusable one (Chat doesn't render SVG). Use the repo's `apps/amplify/amplify-jobs/img/WSO2-Amplify-Poster-Default.png` through a raw URL pinned to a commit SHA (`https://raw.githubusercontent.com/<org>/marketing-tools/<sha>/apps/amplify/amplify-jobs/img/WSO2-Amplify-Poster-Default.png`), never a branch name (the original image is in the Amplify Demo shared chat space). Empty = such cards go out without an image |
| all | `sharePageBaseUrl` | One WSO2 Celebrate page for the button, e.g. `https://one.wso2.com/amplify/celebrate` (must be HTTPS); the card adds `?share=<campaignId>`, which opens that post's share dialog |
| all | `chatMinIntervalSeconds` | `1` (Chat quota: 1 request/second per space, shared by every webhook in it) |
| all | `chatAllowInsecureHttp` | **leave unset (false)**; local stack only |

The webhook URL is a plain **secret** on amplify-jobs, not a Choreo connection: the descriptor has no `connectionReferences` for Chat, and the value is typed into the console, never kept in `component.yaml`. The URL carries its own key and token, so treat it like a password. Egress is controlled by the org allow-list in D5 of the Choreo deploy runbook, if the org uses one.

- [ ] **C1** Choreo › amplify-jobs › Configs & Secrets › add `chatWebhookUrl` as a **secret** for the environment. Redeploy amplify-jobs.
- [ ] **C2** Empty `chatWebhookUrl` = announcements wait (outbox rows are deferred, not failed), so it's safe to deploy before C1.

## D. Verify

- [ ] **D1** Create a test campaign in dev with "Save & Share Now". Within one run the card shows in the dev space: header with the avatar, image (the campaign's own when it is public HTTPS, else `chatDefaultImageUrl`), summary, **Amplify** button opening `{sharePageBaseUrl}?share={campaignId}` (Celebrate with that post's share dialog).
- [ ] **D2** `announcement.announcement` row: `sent_at` set, `chat_message_name` and `chat_thread_name` filled. A second card for the same campaign (admin retry after a failure) lands in the same thread (`threadKey = campaign-{id}`, `REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD`).
- [ ] **D3** amplify-jobs logs show the run, never the URL: `grep -c 'token=' <logs>` = 0.

## E. Rotate (leaked URL, owner change, or yearly)

There's no "regenerate" in Chat: rotation = new webhook, then remove the old one.

1. In web Chat, space ▾ › Apps & integrations › **Add webhooks** › add a new `Amplify` webhook, copy the link.
2. Choreo › amplify-jobs › Configs & Secrets › update `chatWebhookUrl` for that environment › redeploy.
3. Check D1 with a test campaign (dev) or wait for the next real card (prod).
4. Space ▾ › Apps & integrations › Webhooks › **delete the old webhook**. Its URL stops working immediately.
5. Leaked URL: do step 4 **first** (accept a short gap; cards wait in the outbox and go out after step 2), then 1–3.

## F. Failures

| Chat answers | What amplify-jobs does |
| --- | --- |
| 200 | `announcement.sent_at`, message and thread names stored, `CampaignAnnounced` emitted |
| 400 / 403 / 404 (bad card, deleted webhook) | announcement **FAILED** at once, no retry; fix the cause, then Admin › Announcements › Retry |
| 429 | retry with backoff via the outbox (ADR-025); the 1 rps throttle keeps this rare |
| 5xx / timeout | retry with backoff; FAILED after `maxAttempts`, then admin retry |

A 404 on every card usually means the webhook was deleted: rotate (E1–E3).

## G. Local

- `docker compose --env-file local/.env up` starts `chat-stub` and points amplify-jobs at it. Cards show in `docker compose logs -f chat-stub`; `docker compose --env-file local/.env exec chat-stub wget -qO- localhost:9095/stub/messages` lists them (no host port since M8a).
- Script failures: `curl -X PUT localhost:9095/stub/status/429` (or 400, 500, 503; 200 resets).
- **Send to dev space** toggle: set `GOOGLE_CHAT_WEBHOOK_URL` in `local/.env` to the **dev test** webhook (never the Club one) and restart amplify-jobs. Clear it to go back to the stub.

## H. Known gap: campaign images

Chat fetches card images itself, so the URL must be public HTTPS. The card builder leaves the image widget out when it isn't (localhost, private IPs, plain http), and the card still goes out. LinkedIn CDN URLs (`media.licdn.com`) carry an expiry (`e=` parameter): old cards may show a broken image later. Re-hosting campaign images on a WSO2-owned public URL is a later item (plan M6a).
