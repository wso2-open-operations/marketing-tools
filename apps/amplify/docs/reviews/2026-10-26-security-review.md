# Security review before the upstream PRs, 2026-10-26

Scope: everything the fork adds on top of upstream, read as `git diff $(git merge-base upstream/main origin/main) origin/main` in each repo. This was a read-only review. I changed no source files, other docs or the threat model, and I built and ran nothing.

| Repo | Reviewed | Skipped |
|---|---|---|
| `projects/marketing-tools` | `apps/amplify` (api, domain, common, jobs, database, scheduler image, compose, local tooling) | `apps/amplify/linkedin/resources` |
| `projects/one-wso2` | `webapp/src/features/amplify` and the wiring (route guards, config, auth provider) | |
| `projects/people-ops-suite` | `apps/people-app/backend` (service-client path, `house` column) | |
| `projects/wso2-digital-agents` | `po-agent` notification schema and card builder | |

Method: the `security-review` skill, adapted to a fork-versus-upstream diff. I traced each candidate from the input to the sink, then checked it against the existing controls. The findings below are the ones that held up. Everything that did not hold up is in the "Not an issue, checked" list so nobody repeats the work.

Carried forward from the v0.3 threat model, the v0.1 security checklist, token-and-oauth-notes.md and the earlier reviews in this folder: see the last section. I did not edit any of them.

## Summary

| Severity | Count | IDs |
|---|---|---|
| High | 0 | |
| Medium | 3 | F-1, F-2, F-3 |
| Low | 6 | F-4 to F-9 |

Blocks sending upstream: nothing. No committed secret, no SQL injection, no auth bypass, no way to turn the dev JWT on in prod.

F-1 and F-3 were fixed on 2026-10-26, before the pilot. F-2 belongs in the people-ops-suite PR description, because the change adds a code path on top of a trust gap that people-app already has.

## Findings

### F-1 Medium: points history shows PO reasons and PO ids to teammates

**Fixed 2026-10-26.** `history()` now returns adjustment and reversal rows to non-PO callers with the fixed label "Adjusted by the PO team" and no `actorId` (`ledgerDtoForTeammate` in `dto.bal`). A PO still sees the full row. The contract makes `actorId` optional. Test: `testHistoryHidesPoReasonAndIdFromTeammates`.

- Category: data exposure. Confidence: 9/10.
- Evidence:
  - [`reads.bal:319-358`](../../amplify-api/reads.bal) `history()`. A non-PO caller may read another employee's history when `teamVisibility == "COMPANY"` or the target is on the caller's roster team (default `TEAM`).
  - [`dto.bal:276-288`](../../amplify-api/dto.bal) `ledgerDto()` returns `reason` and `actorId` for every row, for every viewer.
  - [`matrix.bal:104`](../../amplify-api/modules/auth/matrix.bal) allows the route to every employee.
- Exploit scenario: a PO reverses a colleague's points with the reason "Duplicate claim, HR looking at conduct" or "Posted from a personal account". Anyone on that colleague's team calls `GET /team/{employeeId}/history` and reads the reason and the PO's employee id. Under `COMPANY` visibility, anyone in the company can.
- Why it matters: threat model row 5.4 says adjustment reasons are internal ("Reason is internal; logs redact row values"), but the API hands them out. Reasons are free text up to 1000 characters and PO-written, so they are the field most likely to hold personal data.
- Fix: in `history()`, when the caller is not a PO, build the DTO without `reason` and `actorId` (return a fixed label such as "Adjusted by the PO team" for `ADJUSTMENT` and reversal rows). Decide separately whether an employee may see the reason on their own rows. Add a test next to the existing `TEAM_SCOPE` tests.

### F-2 Medium: people-app service-client path decides on an unsigned token

- Category: authentication. Confidence: 8/10. Inherited trust gap (AMP-R9), but this change adds a new way to use it.
- Evidence: `projects/people-ops-suite/apps/people-app/backend/modules/authorization/authorization.bal:42` decodes `x-jwt-assertion` with `jwt:decode` and never verifies the signature. Lines 51-62 admit a caller when the token has no `email` and no `groups`, `aut == APPLICATION`, and `azp` is in `directoryClientIds`. `allowedServiceClient` is at line 118, `isServiceClientRoute` at line 134. The local gateway prototype says it plainly: "The assertion is unsigned: people-app only decodes it" (`projects/marketing-tools/apps/amplify/local/people-app-proto/gateway.mjs`, header comment).
- Exploit scenario: anyone who can reach people-app without going through the gateway builds `{"azp":"<amplify client id>","aut":"APPLICATION"}`, base64s it, and calls `GET /employees/basic-info`. They get the full directory: work emails, manager emails, start dates, thumbnails, team, house. Before this change, a forged call needed a real employee email and a valid group name. Now it needs one client id.
- What holds: the path is read-only, one route, exact segment match, user tokens never take it (tests in `service_client_test.bal` cover an encoded slash, a trailing segment, POST, and a listed `azp` on a user token). `directoryClientIds` defaults to empty, so nothing changes until someone lists a client.
- Fix, in order of preference: verify the assertion's signature against the gateway JWKS in `JwtInterceptor` (fixes the user path too); or confirm in writing that people-app is reachable only through the gateway and put that in the PR description. Keep `directoryClientIds` empty in the checked-in `Config.toml.local` (it is).
- Also note for the PR: the directory response carries more than Amplify reads. Amplify drops the extra fields on parse and never stores them. A narrower service route is a later cleanup.

### F-3 Medium: a PO can adjust or reverse their own points

**Fixed 2026-10-26.** `adjustment()` and `reversal()` in the scoring service return `SELF_REVIEW` (403) when the actor is the person the points belong to. Test: `aPoCannotAdjustOrReverseTheirOwnPoints`. I did not add the database `CHECK`; it would need a new migration.

- Category: authorization (separation of duties). Confidence: 9/10.
- Evidence:
  - [`handlers.bal:425-444`](../../amplify-api/handlers.bal) `adjustPoints` passes the body `employeeId` and `p.employeeId` straight through. No comparison.
  - [`service.bal:290-297`](../../amplify-domain/modules/scoring/service.bal) `adjustPoints` and `adjustment()` (line 184) check only for non-zero points and a reason.
  - `reverseEntry` ([`handlers.bal:447`](../../amplify-api/handlers.bal)) has no check either. Compare external shares, where `ensureDecidable` and `markAmplified` return `SELF_REVIEW` (threat model 4.6).
  - No database constraint stops it: `scoring.points_ledger` has `actor_id` but no `actor_id <> employee_id` check (`amplify-database/migrations/V006__scoring.sql:45`).
- Exploit scenario: a PO posts `{"employeeId": "<own id>", "points": 10000, "reason": "correction"}` to `/po/points/adjustments` and tops the company leaderboard. The audit row exists, but nobody is told. Phase 2 Coins would turn that into money.
- Fix: return `SELF_REVIEW` (403, same code the claims use) when the target is the caller, in both `adjustPoints` and `reverseEntry` (a reversal's target is the original entry's `employeeId`). Add the same `CHECK` on the ledger for adjustments if you want the database to agree. Cap `points` further than 10000 only if the PO team wants it.

### F-4 Low: outbound trust URLs are not forced to https outside local

- Category: transport security. Confidence: 8/10 that the check is missing. Carries forward M5 from the 19 Oct code review, still open.
- Evidence: `gatewayJwksUrl` ([`config.bal:28`](../../amplify-api/config.bal)), `peopleDirectoryTokenUrl` ([`outbound.bal:49`, `117-123`](../../amplify-api/outbound.bal)) and `noveraTokenUrl` ([`config.bal:86`](../../amplify-jobs/config.bal)) have no scheme check. `NoveraClient.init` checks only the notify URL ([`novera.bal:81`](../../amplify-jobs/novera.bal)). LinkedIn base URLs default to https but nothing enforces it.
- Exploit scenario: a descriptor typo or a copy of the local values into a shared environment sends the directory client secret, or the Novera client secret, in clear. A plain-http JWKS URL lets a network attacker substitute signing keys, which is full authentication bypass.
- Why it is only Low: these are deployment configuration, set by the team, not by a user.
- Fix: one helper, `requireHttpsUnlessLocal(url, environment)`, called at startup for each of these URLs. `checkRedirectUri` already does this for the LinkedIn redirect.

### F-5 Low: Novera buttons accept any http or https URL, for every subscribed app

- Category: phishing surface. Confidence: 7/10.
- Evidence: `projects/wso2-digital-agents/po-agent/src/chat/notify.ts:95-103` (`readLink`) allows `http:` and `https:` with any host for `button.url`, and `buildCard` puts it in an `openLink` button that goes to every Novera DM. `imageUrl` (line 123) is https only. `POST /internal/notifications` is protected only by the gateway subscription (`po-agent/CLAUDE.md`: "its only protection").
- Exploit scenario: any application subscribed to the Novera API, or a leaked client secret, broadcasts a card with a button labeled "Amplify" that opens a credential-phishing page, in the DM of every employee who talks to Novera. The existing `link` field already allowed an arbitrary URL, but as small inline text. A button draws far more clicks.
- What holds: Amplify's own button URL is built from `sharePageBaseUrl` config plus a campaign UUID ([`announcements/service.bal`, `buildNoveraNotification`](../../amplify-domain/modules/announcements/service.bal)). Amplify cannot be steered into a hostile URL by a PO. Card text is escaped by Novera.
- Fix: make `button.url` https only, and either an allow-list of hosts (config) or require the host to match a configured list of One WSO2 origins. Same for `imageUrl` if you want to stop tracking pixels. Do this in the po-agent PR.

### F-6 Low: `POST /maintenance/rebuild-recognition` is missing from the threat model's unauthenticated jobs list

- Category: attack surface documentation. Confidence: 9/10.
- Evidence: [`amplify-jobs/service.bal:128-142`](../../amplify-jobs/service.bal) exposes a third unauthenticated mutation next to `/runs` and `/maintenance/partitions`. the v0.3 threat model rows 7.1 and 7.5 and risk AMP-R1 name only the first two. The jobs endpoint is project-visibility in [`workload.yaml`](../../amplify-jobs/workload.yaml) and not published by Compose.
- Impact: same class as AMP-R1. A same-project caller can force a full rebuild of every recognition table, which is expensive and briefly changes ranks. No data leaves, nothing is written that the ledger cannot regenerate.
- Fix: add the endpoint to AMP-R1 and rows 7.1 and 7.5 when the threat model is regenerated. A shared-secret header between api and jobs would close the whole class, but ADR-026 accepted the residual.

### F-7 Low: `amplify_api` holds more on `provider_token` than it needs

- Category: least privilege. Confidence: 6/10 on whether the API ever reads the table directly, so check before changing.
- Evidence: `amplify-database/migrations/V003__connection.sql:113` grants SELECT, INSERT, UPDATE, DELETE on `connection.provider_token` to both `amplify_api` and `amplify_jobs`. The API inserts a token at connect and deletes it at remove. Only jobs decrypts and re-seals. The API also holds the key ring (`tokenKeys`), so it needs the key to seal.
- Impact: a compromised API process can read ciphertext and has the key, so it can decrypt every member token. Narrowing the grant removes the read half of that.
- Fix: give `amplify_api` INSERT and DELETE only on `provider_token` (the status view runs with the view owner's rights). If the API does read it, leave this alone. The longer fix is a seal-only key for the API, which is a design change and not for this PR.

### F-8 Low: two local mock servers listen on every interface

- Category: local tooling exposure. Confidence: 9/10 on the bind, impact limited to a developer's LAN.
- Evidence: `projects/marketing-tools/apps/amplify/local/novera-mock/server.mjs:98` binds `0.0.0.0` and logs and stores every notification body. `projects/marketing-tools/apps/amplify/local/people-app-proto/gateway.mjs:68` listens with no host, so also all interfaces, and mints unsigned assertions for any client holding a secret from `CLIENTS`. The dev proxy (`local/one-wso2-proxy/proxy.mjs:155`) correctly binds `127.0.0.1`.
- Impact: on a shared network, another host can post cards into the mock (log noise, a stored fake) or call the gateway stub if it has a client secret. The stub's upstream is a local prototype database with made-up people.
- Fix: bind both to `127.0.0.1`, or to the Compose network only. The files say "local only" in their headers; the bind should agree.

### F-9 Low: the activity matrix promises an evidence host allow-list that the code does not have

- Category: documentation drift that misleads reviewers. Confidence: 9/10.
- Evidence: [`matrix.bal:78`](../../amplify-api/modules/auth/matrix.bal) says `POST /external-shares` enforces a "host allow-list". [`evidence_url.bal:57-172`](../../amplify-common/modules/types/evidence_url.bal) accepts any public https host (no credentials, no IP literal, valid labels). Threat model 4.4 describes the code correctly and never claims an allow-list.
- Impact: nothing server-side fetches the URL, so no SSRF. A reviewer who trusts the matrix text will assume a PO can only open LinkedIn or Medium links. A PO opens an employee-supplied URL in their own browser.
- Fix: change the matrix text to "https only, no credentials or IP hosts". Show the host prominently in the PO review screen when it is built (there is no review UI in the One WSO2 diff yet, which also leaves checklist item 11 open).

## Not an issue, checked

| Area | What I checked | Result |
|---|---|---|
| Backend JWT verification | [`token.bal:122-201`](../../amplify-api/modules/auth/token.bal) | RS256 only (`alg: none` and HS* rejected before any key lookup), signature verified before any claim is read, then `exp` (required), `nbf`, `iss`, `aud`, `sub`, `email`. Token length capped. Failure codes carry no token content. |
| Dev JWT bypass in prod | [`config.bal:23-103`](../../amplify-api/config.bal), [`compose.yaml`](../../compose.yaml) | `environment` defaults to `prod`. `checkDevSwitch` stops startup when the switch is on and `environment != local`, or when `devIssuer` is blank or equals the gateway issuer. A token claiming the dev issuer is checked only against dev keys, and only when the switch is on. No Choreo descriptor sets either value. Compose hardcodes `local` and defaults the switch to `false`. The dev key and `jwks.json` are gitignored and generated on first `make up`. |
| Role matrix, default deny | [`matrix.bal`](../../amplify-api/modules/auth/matrix.bal), [`interceptors.bal:29-60`](../../amplify-api/interceptors.bal) | Unlisted route gets 403. Unlisted method (HEAD, OPTIONS) has no row and gets 403. Only GET `/health` and `/ready` skip auth. Encoded slashes arrive as one segment and match no row. Denials are audited. |
| Dashboards, person board, CSV export | [`matrix.bal:95-100`](../../amplify-api/modules/auth/matrix.bal) | All seven routes are `DASHBOARD_READERS` (po, marketing, slt, admin), never a plain employee. `/dashboards/people/{employeeId}` is a PO-class lookup by design. The UI route guards are convenience only, the server enforces. |
| CSV formula injection | [`dashboards.bal:449-483`](../../amplify-api/dashboards.bal) | `=`, `+`, `-`, `@`, tab and CR get a leading quote; quotes, commas and line breaks are quoted and doubled. Filename comes from two validated `YYYY-MM-DD` dates. Range capped at 366 days. |
| IDOR on campaigns | [`reads.bal:100-112`](../../amplify-api/reads.bal), [`handlers.bal:321-345`](../../amplify-api/handlers.bal) | Non-editors get 404 for any campaign that is not open. Archived campaigns are 404 for non-editors on share. Ids go through `uuidOf`. |
| IDOR on shares, connection, state | `/me/shares`, `DELETE /connections/linkedin`, `completeConnect` | All keyed to `p.employeeId`. OAuth state is bound to the employee in the `DELETE ... WHERE employee_id` statement. |
| Team history scope | [`reads.bal:319-358`](../../amplify-api/reads.bal) | Scope check is correct (self, roster teammate, or PO; `COMPANY` opens it by setting). The leak is in what it returns (F-1), not who may call it. |
| LinkedIn OAuth state | [`oauth_state.bal`](../../amplify-domain/modules/connection/oauth_state.bal) | 244 random bits, 10 minute TTL, single use through `DELETE ... RETURNING`, bound to the employee, consumed before the code exchange. A state from another user fails. |
| Redirect URI | [`handlers.bal:209-215`](../../amplify-api/handlers.bal), [`outbound.bal:171-182`](../../amplify-api/outbound.bal) | Startup check: absolute https (http only on `local`), no query, fragment, credentials, backslash or space. The token exchange always sends the configured value, so an omitted `redirectUri` from the client cannot change where LinkedIn sends the code. |
| `returnTo` open redirect | [`handlers.bal:198`](../../amplify-api/handlers.bal) and `LinkedInCallbackPage.tsx` `safeReturnTo` | Single leading slash, no second slash, backslash, whitespace or control character. Same rule on both sides. The UI also refuses an `authorizationUrl` off LinkedIn's origin before `window.location.assign`. |
| ID-token validation | [`id_token.bal`](../../amplify-common/modules/linkedin/id_token.bal) | When on: RS256 only, JWKS keyed by `kid` with a refresh gate, `iss`, `aud` (plus `azp` when there are several), `exp`, `nbf`, `iat` range, `sub` must match userinfo. Off by default is a carried item, not a new gap: the code is exchanged server to server with the client secret. |
| Token at rest | [`token_cipher.bal`](../../amplify-common/modules/crypto/token_cipher.bal) | AES-256-GCM through the JDK, 32-byte key enforced, 96-bit nonce built from the random bytes of a UUIDv4 (bytes 0-5 and 10-15, which hold no version or variant bits), AAD `tokenId|ownerId|provider` with `|` rejected in parts, per-row `key_id`, duplicate key ids refused. Reseal on use and in maintenance, guarded by the old `key_id`. Decrypt errors say "wrong key, row or tampered data" and nothing else. Plaintext is never logged (checked `handlers.bal:267`: the logged value is the error). |
| SQL injection | every `sql:queryConcat` and raw query in domain and api | All values are bound parameters. The dynamic parts (`ORDER BY`, filters) are chosen from fixed enum branches, never from request text. `GROUP_SORTS`, `by`, `dir`, `scope` and `period` are allow-listed before use. Group board sorting happens in memory ([`groups.bal:92-127`](../../amplify-api/groups.bal)). The `ILIKE` prefix escapes `%`, `_` and `\`. |
| `by=` and `sort` parameters | [`groups.bal:202-250`](../../amplify-api/groups.bal) | Rejected with 400 unless in the fixed list. `bu` capped at 100 characters and looked up in the directory index, unknown value is 404. |
| SSRF | all outbound clients | Hosts come from configuration only. Evidence URLs are never fetched. Chat and Novera image URLs are fetched by Google, not by us, and must be public https. The scheduler job URLs are built from config, not settings. |
| Campaign image and link | `campaign/service.bal`, V002 migration, `linkedinPost.ts` | https enforced in code and by a database `CHECK`. The UI shows a post link only if its origin is on the allow-list (LinkedIn by default). No `dangerouslySetInnerHTML`, `innerHTML` or `eval` anywhere in the Amplify UI diff. |
| UI token handling | `useAmplifyData.ts`, `apiConfig.ts` | The access token comes from the auth SDK per request. No `localStorage`, `sessionStorage` or cookie code added. Path ids are `encodeURIComponent`-ed. `target="_blank"` links carry `rel="noopener noreferrer"`. |
| Google Chat card | [`card.bal`](../../amplify-common/modules/googlechat/card.bal), [`client.bal`](../../amplify-common/modules/googlechat/client.bal) | Summary is HTML-escaped, title is plain text, button URL is built from config plus a UUID. Webhook must be https (plain http only for exact `localhost` or `127.0.0.1`, host parsed correctly so `localhost.evil` fails). The webhook URL is never logged. |
| Secrets in tracked files | grep of every added line in all four repos, `git ls-tree` of `apps/amplify/local` | No real secret. `local/.env` and `Config.toml.local` for the mock are gitignored (`git check-ignore` confirmed). `.env.example` has empty values and made-up local ids. Test files carry obvious dummy values (`it-secret`, `test-client-secret`, `it-*-password-*`). `make env` generates random secrets with `openssl rand` and sets mode 600. |
| Docker images | `Dockerfile` for api, jobs, scheduler | Base images pinned by digest, multi-stage, non-root user 10014, `.dockerignore` excludes `Config.toml` and `local/.env`. Compose publishes only on `127.0.0.1`. |
| PII in logs | grep of `log:print*` calls, `scripts/check-logs-pii.sh` | Logs carry codes, routes and correlation ids. Denial logs carry no email or token. Error mapping returns stable codes, never provider or SQL text. |
| Idempotency | [`idempotency.bal`](../../amplify-api/idempotency.bal) | Keys are scoped to the caller's employee id, the request hash includes method, route and body, a different body under the same key is 422, 5xx outcomes are released. Award writes also sit behind unique constraints. |
| Scheduler and jobs exposure | [`workload.yaml`](../../amplify-jobs/workload.yaml), [`compose.yaml`](../../compose.yaml) | Both are project-visibility, the scheduler has no host port. Residual (AMP-R1) is accepted and bounded; see F-6 for the one addition. |
| people-app route match | `authorization.bal:134-136` and its tests | Exactly two segments, GET only, joined and compared to `employees/basic-info`. Encoded slash, extra segment and POST all 403. A user token that carries a listed `azp` stays a user. A token with `groups` is never a service. |
| Evidence URL parser | [`evidence_url.bal`](../../amplify-common/modules/types/evidence_url.bal) | https only, control characters and spaces refused, `@` in the authority refused (so `host\@other` tricks fail), bracketed IPv6 refused, any all-numeric or `0x` last label refused (decimal, hex and dotted IPv4), label regex rejects backslashes. |
| Chat/Novera notification from Amplify | [`announcements/service.bal`](../../amplify-domain/modules/announcements/service.bal) | `imageUrl` passes `isPublicHttpsUrl` (no IP forms, no `localhost`, `.local`, `.internal`, private ranges) or falls back to the default image. Icon must be https. Title and body are cut to Novera's limits. |
| LinkedIn post payload | [`adapter.bal`](../../amplify-common/modules/linkedin/adapter.bal) | Author is the member URN stored at connect, never request data. Org owner on new campaigns must equal the configured WSO2 organization URN. Employee commentary is length-capped and `escapeLittleText` neutralizes mention and hashtag syntax. Commentary is cleared after publish. |
| DB roles | `V001`, `main.bal` | Roles are created `NOLOGIN`. Passwords come from secrets through a bind-parameter function, 16 characters minimum. `amplify_readonly` has no grant in the connection schema. TLS defaults to `VERIFY_FULL`. |
| Rate limiting | `docs/runbooks/rate-limiting.md` | Out of scope here, proxy-level by design. |

## Carried forward from the existing security docs

| Item | Source | Status after this review |
|---|---|---|
| AMP-R1 unauthenticated scheduler and jobs on the Project network | threat model | Accepted (ADR-026). One more endpoint to list: F-6. |
| AMP-R2 token theft via backups and master key custody | threat model | Open. Code side is sound (see the cipher row above). F-7 narrows one grant. |
| AMP-R5, AMP-R9 people-app trusts the gateway assertion unsigned; client-id claim (`azp`) not confirmed on a real token | threat model | Open, and worth saying in the people-ops-suite PR: F-2. The `aut` and `azp` claim names are still guesses (`Config.toml.local` says "Confirm the client-id claim name against a real gateway token"). A wrong name fails closed (nobody gets in). |
| AMP-R6 consent copy, AMP-R7 data deletion, AMP-R8 Ballerina transaction race | threat model | Unchanged, not code findings. |
| Redirect check runs only when One WSO2 sends `redirectUri` | token notes section 2 | Fixed on the UI side: `LinkedInCallbackPage.tsx` sends it on every completion. The server-side skip stays harmless because the exchange uses the configured value. |
| ID-token validation off by default, no PKCE, no nonce | token notes section 2 | Unchanged, accepted. Turn it on per environment once a real LinkedIn app returns the token. |
| Item D4: confirm the auth SDK does not consume `?code=&state=` on the callback route | people-data and UI review A4 | Still open. Needs a real Asgardeo or ThunderID run on dev. |
| M5: no startup check on the directory OAuth token URL | people-data and UI review | Still open: F-4. |
| Evidence-link rendering with `rel="noopener noreferrer"` (checklist item 11) | deployment checklist | The Amplify UI in this diff has no external-share review screen, so there is nothing to render yet. The post-link component does set the rel attribute. |
| One WSO2 web-app headers, session timeout, logout | deployment checklist section 8 | Owned by One WSO2, unchanged. |
| FOSSA, Xray, Trivy onboarding, WAF, MFA, `pgaudit`, restore test | deployment checklist | Console and people items, not code. Not re-reviewed. |
