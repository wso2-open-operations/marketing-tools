# Code review: Amplify UI, people-app and po-agent before the upstream PRs (2026-10-26)

Scope: the One WSO2 Amplify module and its wiring, the people-app service-client change, and the po-agent notification change. The dashboards UI (five boards, person and campaign popups, CSV export, House leaderboard) came after the 2026-10-19 review and gets most of the attention here.

Method: static read against the WSO2 Digital code-review checklist, the WSO2 Digital coding standards (React/TypeScript and Ballerina), and the engineering governance rules. Every UI file in the fork's diff against upstream was read; the dashboards and their dialogs line by line. Evidence is `file:line` at the pinned commits (one-wso2 `ff5f7801`, people-ops-suite `0dfbc2a3`, wso2-digital-agents `c10128d`). No source file was changed.

**No High findings.** The team's work holds up: auth is token-per-request with sub-scoped query keys, there is no XSS path (every API string renders as a text node, no `dangerouslySetInnerHTML`), no `console.*` or token/PII logging in the module, the CSV is formula-guarded on the server, and the role gates fail closed. What is left is Medium and Low, plus two PR-shape blockers.

## Checks run

| Check | Result |
|---|---|
| One WSO2 `vitest run` on `features/amplify`, route guards, side-rail, app-marks | 18 files, **188 tests pass** |
| One WSO2 `eslint` on the Amplify module and every wiring file in scope | Clean, no output |
| One WSO2 `tsc -b --noEmit` | Clean, no output |
| po-agent `tsc --noEmit` | Clean |
| people-app `bal test` | **Not run.** The app builds on Ballerina 2201.12.7 and the local toolchain is 2201.13.x; a run could rewrite `Dependencies.toml`. The 7 authorization tests were read, not executed |
| po-agent unit tests | None exist in the package (`package.json` has no `test` script) |
| `npm install` / lockfile changes | None |

## Carried forward from the 2026-10-19 review

| ID | Status | Evidence |
|---|---|---|
| B1 service token must be an application token | **Fixed** | `aut = APPLICATION` check in [authorization.bal:118-124][pa-auth]; tests for email-less user token, `APPLICATION_USER`, no marker, groups present in [service_client_test.bal][pa-test] |
| B2 route matched by joined string | **Fixed** | `path.length() == 2` plus the joined compare, [authorization.bal:134-136][pa-auth]; `employees%2Fbasic-info` test returns 403 |
| B3 unlisted email-less client gets 500 and a stack | **Still open** | Test `unknownServiceClientIsRefusedAsBefore` asserts 500 on purpose ([service_client_test.bal][pa-test]); no log names the client id |
| B4 no log for a successful service read | **Still open** | `employees/basic-info` handler in [service.bal:750-770][pa-svc] logs nothing on the service path |
| B5 assertion is decoded, not verified | **Still open** (inherited) | `jwt:decode` only, [authorization.bal:42][pa-auth]; the test comment says "the gateway verifies". See PA2 |
| A1 `refetchOnMount: false` hides fresh lists | **Fixed** | `refreshNow` uses `refetchType: "all"`, [useAmplifyMutations.ts:48-50][ui-mut]; regression test in `useAmplifyMutations.test.tsx` |
| A2 idempotency key minted inside `mutationFn`; Enter runs "Save & share now" | **Still open** | Key still generated per call, [useAmplifyMutations.ts:40-42,68][ui-mut]; `onSubmit` still calls `save(true)`, [NewPostPage.tsx:95-98][ui-new]. Buttons disable while pending, so a double click is covered; a retry after a lost response is not |
| A3 `postUrnFromUrl` not anchored to LinkedIn | **Fixed** | Origin allow list in [linkedinPost.ts:29-45,57-62][ui-lp]; hostile-input tests in `linkedinPost.test.ts`; amplify-api checks the same list |
| A4 confirm the SDK never consumes `?code&state` on the callback | **Still open** | Needs a run against the real IdP; the comment is still there at [LinkedInCallbackPage.tsx:36-37][ui-cb] |
| A5 any scheme on the redirect and on `<img src>` | **Partly fixed** | Redirect is now checked, [LinkLinkedInDialog.tsx:58][ui-link]. `imageUrl` is still unchecked at send ([NewPostPage.tsx:75][ui-new]) and at render ([PostCard.tsx:32][ui-pc]) |
| A6 invalidation keyed by a possibly unresolved `sub` | **Still open**, Low | `useAmplifySub()` still returns `undefined` while resolving ([useAmplifyMutations.ts:52-55][ui-mut]). The pages that fire the mutations only render after `sub` resolves, so no live path hits it |
| A7 Update Post always rewrites `closesAt`, can't clear the image | **Still open** | [EditPostDialog.tsx:64,67][ui-edit] |
| A7 only the first 50 posts are read | **Still open** | `AMPLIFY_PAGE_SIZE = 50`, one page, [useAmplifyData.ts:34,74][ui-data] |
| A8 `ThunderProvider` relies on an undeclared SDK prop | **Still open** | The spread is still how `wellKnownEndpoint` gets through, [ThunderProvider.tsx:36-38][ui-thunder]. See W1 |
| A9 / M1 null `workEmail` breaks the page | **Fixed** | `indexPeople` skips rows without an email, [useAmplifyPeople.ts:34-38][ui-people]; `usePersonLookup` guards the same way, [usePersonLookup.ts:62][ui-lookup]; test in `useAmplifyPeople.test.ts` |
| A9 CategoryPicker radio semantics | **Still open**, Low | Chips with `role="radio"` but no arrow-key roving, [CategoryPicker.tsx:43-57][ui-cat] |
| A9 local-vs-UTC date edge | **Still open**, Low | `PostCard` formats in the viewer's zone ([PostCard.tsx:45][ui-pc]); every dashboard date is UTC ([dashboardFormat.ts:48-52][ui-fmt]). The same post can show two dates |
| M2, M3 refresh herd, membership-blind ETag | **Superseded** | Accepted on 2026-10-19 (3-day roster TTL). Out of scope for this review |
| M4 directory not a declared Choreo connection | **Still open** | Plain `BAL_CONFIG_VAR_PEOPLEDIRECTORY*` fields, `marketing-tools/apps/amplify/.choreo/component.yaml:155-176` |
| M5 no startup check on directory OAuth config | **Still open** | `peopleDirectoryAuth()` accepts any token URL and an empty id or secret, `amplify-api/outbound.bal:117-122` |
| M6 `e2e-local.sh` silently takes over a user | **Partly fixed** | It now prints a note (`e2e-local.sh:54`); still no confirm, still `2>/dev/null \|\| true` and `LIMIT 1` with no `ORDER BY` (lines 49-51) |
| L1-L8 | **Mostly open** | `people-app-proto/gateway.mjs` now carries a "local prototype only" banner but still has no license header; `proxy.mjs:58` still logs emails. The rest were not re-read; they are all local-tooling items |

The test gaps from last time are half closed. `AmplifyDashboardRoute`, `useAmplifyMutations`, `PostCard`, `ShareDialog` and `linkedinPost` have tests. Still without any: `AmplifyEditorRoute`, `LinkedInCallbackPage` and `safeReturnTo` (not exported), `amplifyError`, `ThunderProvider`, `NewPostPage`.

## Dashboards UI (new, never reviewed)

The team's tests are a real asset. `boards.test.tsx` (492 lines) and `dashboardFormat.test.ts` cover the formatting maths, medal ranks, sort toggling, export range rules and the download happy path, and the `scoreBar` clamp logic handles non-finite input. The role gate is layered right: rail, route guard, `PersonLink`, then the API's own 403.

| ID | Sev | Finding | Fix |
|---|---|---|---|
| D1 | Medium | **Both popups have no accessible name.** `aria-label` on MUI `Dialog` lands on the modal root, not on the `role="dialog"` paper. MUI only wires `aria-labelledby` to the paper (`@mui/material/Dialog/Dialog.js:349`). A screen reader announces an unnamed dialog. [PersonDetailDialog.tsx:44][ui-pd], [CampaignDetailDialog.tsx:132][ui-cd]. `LinkLinkedInDialog` does it right with `aria-labelledby` ([line 73][ui-link]) | Give the `h2` an id and set `aria-labelledby` on the Dialog, as `LinkLinkedInDialog` does |
| D2 | Medium | **Sorting or picking a BU throws away the table and the keyboard focus.** The group board is keyed on sort, dir and BU, with no `placeholderData`. Each click makes the new key `isPending`, so `BoardState` returns the skeleton in place of `TeamTable`/`HouseTable`, which unmounts the header buttons and the BU chips that were just clicked. Keyboard and screen-reader users land on `body` after every click, and everyone sees a flash. [ParticipationBoard.tsx:381,392][ui-pb], [useAmplifyDashboards.ts:115][ui-dash] (the campaigns board already passes `keepPrevious`, [line 48][ui-dash]) | Pass `keepPrevious: true` for group boards; dim instead of replacing |
| D3 | Medium | **At A Glance reports a failed leaderboard or team board as an empty one.** Only `glance` goes through `BoardState`; `board` and `teams` are read as `board.data?.company ?? []` and show "No points yet." / "No teams to show." on a 500, a timeout or while still loading. Leadership reads "no points" when the call failed. [GlanceBoard.tsx:193-200][ui-gl] with the empties at [141,158][ui-gl] | Include both queries in `BoardState`, or show a per-block error and loading state |
| D4 | Medium | **The CSV export gives every amplify_* role raw per-person rows for up to 366 days.** Columns are `employee_id`, `employee_name`, `employee_email`, plus action and detail (`EXPORT_COLUMNS`, `amplify-api/dashboards.bal:446`). The route matrix gives it to PO, Marketing, SLT and Admin alike (`modules/auth/matrix.bal:97`). The UI offers it to all of them with no warning. Nothing in the repo records a data-owner or HR sign-off | Get the sign-off in writing, or limit export to PO/Admin; add a one-line notice on the panel |
| D5 | Low | **Export file handling.** (a) `new Blob([await res.text()])` decodes and re-encodes a body that can be tens of MB; use `await res.blob()`. (b) No UTF-8 BOM, so Excel garbles non-ASCII names (a real case for this employee base). (c) `URL.revokeObjectURL` runs in the same tick as the click; Safari can drop the download, so defer it. [useAmplifyDashboards.ts:131-133][ui-dash], [ParticipationBoard.tsx:266-275][ui-pb] | Three small edits |
| D6 | Low | Export errors use `humanizeHttpError`, so a 403 reads "Something went wrong (HTTP 403)" and a server `message`, if one is ever sent, shows verbatim. The rest of the module uses `describeAmplifyError` for exactly this reason. [ParticipationBoard.tsx:296][ui-pb] | Use `describeAmplifyError` (add a `ROLE_NOT_PERMITTED` path for 403) |
| D7 | Low | `ExportPanel` sits inside the funnel's `BoardState`, so a failed funnel call also hides the export. [ParticipationBoard.tsx:374,400][ui-pb] | Render it outside |
| D8 | Low | The per-day labels under the post popup chart are one `space-between` flex row of "Day N" text. With a 30-day window that is 30 labels in about 700 px, and they do not line up with the bars. [CampaignDetailDialog.tsx:199-203][ui-cd] | Label every fifth day, or put the labels in the SVG |
| D9 | Low | Every `PersonLink` calls `useAmplifyDashboardAccess()`, which runs `useAsgardeoGroups` (a `useAsgardeoSub` and a query observer). A 50-row board or a post with hundreds of reposters mounts hundreds of observers for one answer. [PersonLink.tsx:37][ui-plink] | Read the access once per board and pass a boolean, or put it in a context |
| D10 | Low | Chart colours are hard-coded hex (`#60A5FA`, `#F9A8D4`, `#94A3B8`, `#FF7300`) in nine places and skip the theme. The pink and grey have thin contrast on a light surface. Each chart is also backed by text counts, so this is polish and blocks no one. [OperationsBoard.tsx:138-141,160-164][ui-op], [GlanceBoard.tsx:47][ui-gl] | Move to theme tokens |
| D11 | Low | `RepostGrid` is a CSS grid with `display: contents` rows under `role="table"`; the bar row adds a fourth `cell` to a three-column header, so the table is ragged for assistive tech. [RepostGrid.tsx:56-113][ui-rg] | Use a real `<table>`, or mark the bar cell `presentation` |
| D12 | Low | Scorecard footnote hard-codes "(or ceiling for expired)". The next AT_MOST measure will make it wrong. `onTrack` is declared twice (outer count, inner const), which a no-shadow rule will flag later. [ScorecardBoard.tsx:81,105,147][ui-sc] | Say "ceiling" and rename one |
| D13 | Low | The directory is indexed twice with two code paths: `indexPeople` in `useAmplifyPeople` and the `byEmail`/`byId` maps in `usePersonLookup`. Each call of `usePersonLookup()` (every `PeopleColumn`, every dialog) rebuilds both maps over the whole company list. [usePersonLookup.ts:58-66][ui-lookup], [useAmplifyPeople.ts:32-41][ui-people] | One shared, memoised index |
| D14 | Low | Test gaps on the new code: `BoardState` 403 and error branches, `PersonLink` plain-text for a non-role user, `PersonDetailDialog` 404 and unknown-employee paths, `useDashboardExport` (Accept header, non-OK throw), `usePersonLookup` / `looksLikeId`. | Add these four to `boards.test.tsx` |

Checked and clean on the dashboards: query keys carry the `sub` ([useAmplifyDashboards.ts:34][ui-dash]); `employeeId` is `encodeURIComponent`'d ([line 83][ui-dash]); `campaignId` goes through `URLSearchParams`; `useSecureSignOut` clears the query cache so one user's board never reaches the next; the export filename is built from validated dates; no board data is logged; the CSV formula guard (`=`, `+`, `-`, `@`, tab, return) lives in `amplify-api/dashboards.bal:449-466` and covers names and titles.

## Wiring and the rest of the module

| ID | Sev | Finding | Fix |
|---|---|---|---|
| W1 | **Blocker (PR shape)** | **`ThunderProvider`, `authConfig.wellKnownEndpoint` and the `AuthProvider` switch in `AppWithConfig` ride along in the Amplify change.** They change which issuer the SDK trusts for every user of One WSO2, and they depend on an undeclared SDK prop ([ThunderProvider.tsx:36-38][ui-thunder]). They have no tests and nothing to do with Amplify. [AppWithConfig.tsx:77-80][ui-awc], [authConfig.ts:245][ui-auth] | Own PR, reviewed by whoever owns sign-in; add a test that the Asgardeo path is unchanged when no discovery URL is set |
| W2 | **Blocker (PR shape)** | **`SideRail.tsx` changes `mx: 1` to `mx: "-1px"` on the shared `GroupFrame`**, so every perspective's framed group moves, not just Amplify's. The comment says it fixes Celebrate's icon alignment. [SideRail.tsx:502][ui-rail] | Scope the offset to the Amplify group, or ship it as its own visual PR with screenshots of the other perspectives |
| W3 | Medium | `App.tsx` imports all 9 Amplify pages eagerly, while large features (PAR, for one) are `lazy()` ([App.tsx:93-95][ui-app]). The flag hides the routes but not the bytes: every user downloads about 6k lines of Amplify and the dashboards code. | `lazy()` the dashboards at least |
| W4 | Low | `ONE_WSO2_AMPLIFY_POST_LINK_ORIGINS` accepts any `http:` origin, so a production config typo makes the card link and the sign-in redirect plain HTTP. [linkedinPost.ts:36][ui-lp], [apiConfig.ts:1734-1740][ui-api] | Allow `http:` only for `localhost` / `127.0.0.1` |
| W5 | Low | 16 new files carry a license header cut short: the last line `// under the License.` is missing. Both route-guard files, the dashboards API hook, `usePersonLookup`, `DashboardParts`, `PersonLink`, `RepostGrid`, `CampaignDetailDialog`, `OperationsBoard`, `PersonDetailDialog`, `PostPerformanceBoard`, `dashboardFormat` and its test, `dashboardNav.test`, `useAmplifyDashboardAccess.test`, `boards.test`. Missing or wrong header is should-fix under the checklist. | Add the line; it is a mechanical edit |

Clean in the wiring: the preview flag gates every route and the rail entry; both guards wait for the token decode, explain a failed decode and redirect everyone else; `safeReturnTo` still refuses `//`, backslashes and whitespace; `isAllowedLink` covers send, render and redirect; the one-origin API base uses `encodeURIComponent` on every id; `config.js.example` documents each new key.

## people-app (service clients, `house`)

The change is small and the shape is right: default-off (an empty client list is the old behavior), one exact route, application-token marker, read-only. The 7 tests cover the cases that matter. Findings:

| ID | Sev | Finding | Fix |
|---|---|---|---|
| PA1 | Medium | **The claim names are guesses.** `azp` for the client id and `aut = APPLICATION` for the token type are the defaults, and `Config.toml.local` and `types.bal` both say to confirm them on a real gateway token. Wrong names fail closed (no service access), so this blocks turning it on and leaves merging open. [types.bal:30-42][pa-types], [Config.toml.local][pa-local] | Capture a real client-credentials token from the dev gateway, record the claim names in the PR description |
| PA2 | Medium | **Inherited: the assertion is decoded, never verified.** Anyone who can reach the backend without the gateway can send `{azp: <listed id>, aut: APPLICATION}` and read the directory. It does not widen access beyond what a forged `email` plus `groups` already allowed, but it lowers the bar: one guessable client id, no groups to know. [authorization.bal:42][pa-auth] | State in the PR that the backend is gateway-only, and point at the network rule that enforces it |
| PA3 | Low | A service caller gets the whole `EmployeeDirectoryInfo`: job band, start date and manager email as well as name, email, team, BU, house and photo. Amplify reads the second set only. [types.bal:129-160][pa-dbt] | Say so in the PR; consider a slimmer service view later |
| PA4 | Low | B3 and B4 above: an unlisted email-less client gets a 500 and an error stack with no client id in the log, and successful service reads leave no trace. [authorization.bal:67][pa-auth], [service.bal:755][pa-svc] | 403 plus a warning with a truncated claim value; one info line with the client id |
| PA5 | Low | Test gaps: the empty default list, a token with no `azp`, an `azp` that is not a string, a differently-cased `aut`. | Four short cases |
| PA6 | Low | `authorization.bal` ends with a stray blank line (the formatter will flag it). | `bal format` |

Clean: the `house` join is a `LEFT JOIN` with a nullable field (no row loss, additive for existing clients), no SQL string building, the new config block has fail-closed defaults, the new test module has its own port and `Config.toml`, license headers present.

## po-agent (notification `imageUrl` and `button`)

The change is small and tidy. `readLink` folds the old inline `link` check into one helper and adds the same null guard; `imageUrl` is https-only like `iconUrl`; unknown `button` fields are refused; the button label goes into a plain-text Chat field and the title/body stay escaped; the OpenAPI limits (`2000`, `40`) match `URL_MAX_LENGTH` and `LABEL_MAX_LENGTH`; `ARCHITECTURE.md` was updated in the same change.

| ID | Sev | Finding | Fix |
|---|---|---|---|
| AG1 | Low | No tests anywhere in `po-agent` for `readNotification` or `buildCard`, so the new fields and the `readLink` refactor are untested. [notify.ts:94-105,123-125,183-189][ag-notify] | Add a test script and cover: image present/absent, button valid/unknown-field/bad-URL, link unchanged |
| AG2 | Low | `button.url` allows `http:`. Confirm Chat accepts an `http` `openLink`; if it rejects the card, every DM fails after the API has already answered 202. [notify.ts:125][ag-notify], [openapi.yaml:93-98][ag-api] | Test once against the real space; restrict to https if it fails |
| AG3 | Low | Pre-existing, now used by two more fields: `readUrl` returns the raw string (not trimmed) and accepts `https://user:pass@host`. [notify.ts:78-92][ag-notify] | Return `new URL(value).href`; reject credentials |

## Things to fix before the PRs go out

Ranked, with blockers first.

| # | File | Item | Class |
|---|---|---|---|
| 1 | one-wso2 [ThunderProvider.tsx][ui-thunder], [AppWithConfig.tsx][ui-awc], [authConfig.ts][ui-auth] | Split the auth-provider change into its own PR (W1) | **Blocker** |
| 2 | one-wso2 [SideRail.tsx:502][ui-rail] | Scope the margin change to Amplify or ship it separately with screenshots of the other perspectives (W2) | **Blocker** |
| 3 | one-wso2, whole module (63 files, 6.8k lines) | Cut the Amplify change into small PRs. Suggested order: (a) config, flag, rail, route guards, access hooks; (b) Celebrate, share and link dialogs; (c) New Post and Current Posts; (d) dashboards; (e) the shared pieces with tests | **Blocker** (for "small PRs") |
| 4 | people-ops-suite [authorization.bal][pa-auth], PR text | Confirm `azp` and `aut` on a real gateway token and say the backend is gateway-only (PA1, PA2). Safe to merge as is, because it ships off, but not to enable | Blocker for enabling |
| 5 | [ParticipationBoard.tsx][ui-pb] export, `amplify-api/modules/auth/matrix.bal:97` | Get written sign-off for per-person email export to SLT and Marketing, or narrow it (D4) | Blocker for the dashboards PR |
| 6 | [PersonDetailDialog.tsx:44][ui-pd], [CampaignDetailDialog.tsx:132][ui-cd] | `aria-labelledby` on both dialogs (D1) | Should fix |
| 7 | [ParticipationBoard.tsx:381,392][ui-pb], [useAmplifyDashboards.ts:115][ui-dash] | Keep the previous group board on screen while the next loads (D2) | Should fix |
| 8 | [GlanceBoard.tsx:193-200][ui-gl] | Route `board` and `teams` through `BoardState` so failures do not read as "no points" (D3) | Should fix |
| 9 | the 16 files in W5 | Finish the license header (`// under the License.`) | Should fix, mechanical |
| 10 | [useAmplifyDashboards.ts:131-133][ui-dash], [ParticipationBoard.tsx:266-275,296][ui-pb] | `res.blob()`, UTF-8 BOM, deferred revoke, `describeAmplifyError` (D5, D6) | Should fix |
| 11 | [App.tsx:1015-1062][ui-app] | `lazy()` the Amplify pages (W3) | Should fix |
| 12 | [NewPostPage.tsx:75,95-98][ui-new], [PostCard.tsx:32][ui-pc] | https-only `imageUrl` on send and render; Enter runs plain Save; one idempotency key per intent (A5, A2) | Should fix |
| 13 | [boards.test.tsx][ui-bt], `AmplifyEditorRoute`, `amplifyError`, `ThunderProvider` | The test gaps in D14 and the carried list | Should fix |
| 14 | people-app [authorization.bal][pa-auth], [service.bal][pa-svc] | 403 plus warning for unlisted clients, info log for allowed reads, four more tests, `bal format` (PA4-PA6) | Consider |
| 15 | po-agent [notify.ts][ag-notify] | Add tests; check `http` `openLink` against Chat; trim and credential-check `readUrl` (AG1-AG3) | Consider |
| 16 | the Low UI items | D7 to D13, W4, the CategoryPicker keyboard behavior | Consider |

Anything I missed is my miss. Leave a comment on the PR and I will fix it up.

[ui-mut]: ../../../../../one-wso2/webapp/src/features/amplify/api/useAmplifyMutations.ts
[ui-new]: ../../../../../one-wso2/webapp/src/features/amplify/pages/NewPostPage.tsx
[ui-lp]: ../../../../../one-wso2/webapp/src/features/amplify/util/linkedinPost.ts
[ui-cb]: ../../../../../one-wso2/webapp/src/features/amplify/pages/LinkedInCallbackPage.tsx
[ui-link]: ../../../../../one-wso2/webapp/src/features/amplify/components/LinkLinkedInDialog.tsx
[ui-pc]: ../../../../../one-wso2/webapp/src/features/amplify/components/PostCard.tsx
[ui-edit]: ../../../../../one-wso2/webapp/src/features/amplify/components/EditPostDialog.tsx
[ui-data]: ../../../../../one-wso2/webapp/src/features/amplify/api/useAmplifyData.ts
[ui-thunder]: ../../../../../one-wso2/webapp/src/context/auth/ThunderProvider.tsx
[ui-people]: ../../../../../one-wso2/webapp/src/features/amplify/api/useAmplifyPeople.ts
[ui-lookup]: ../../../../../one-wso2/webapp/src/features/amplify/api/usePersonLookup.ts
[ui-cat]: ../../../../../one-wso2/webapp/src/features/amplify/components/CategoryPicker.tsx
[ui-fmt]: ../../../../../one-wso2/webapp/src/features/amplify/util/dashboardFormat.ts
[ui-pd]: ../../../../../one-wso2/webapp/src/features/amplify/pages/dashboards/PersonDetailDialog.tsx
[ui-cd]: ../../../../../one-wso2/webapp/src/features/amplify/pages/dashboards/CampaignDetailDialog.tsx
[ui-pb]: ../../../../../one-wso2/webapp/src/features/amplify/pages/dashboards/ParticipationBoard.tsx
[ui-dash]: ../../../../../one-wso2/webapp/src/features/amplify/api/useAmplifyDashboards.ts
[ui-gl]: ../../../../../one-wso2/webapp/src/features/amplify/pages/dashboards/GlanceBoard.tsx
[ui-op]: ../../../../../one-wso2/webapp/src/features/amplify/pages/dashboards/OperationsBoard.tsx
[ui-sc]: ../../../../../one-wso2/webapp/src/features/amplify/pages/dashboards/ScorecardBoard.tsx
[ui-plink]: ../../../../../one-wso2/webapp/src/features/amplify/components/PersonLink.tsx
[ui-rg]: ../../../../../one-wso2/webapp/src/features/amplify/components/RepostGrid.tsx
[ui-bt]: ../../../../../one-wso2/webapp/src/features/amplify/pages/dashboards/boards.test.tsx
[ui-awc]: ../../../../../one-wso2/webapp/src/AppWithConfig.tsx
[ui-auth]: ../../../../../one-wso2/webapp/src/config/authConfig.ts
[ui-api]: ../../../../../one-wso2/webapp/src/config/apiConfig.ts
[ui-app]: ../../../../../one-wso2/webapp/src/App.tsx
[ui-rail]: ../../../../../one-wso2/webapp/src/components/side-rail/SideRail.tsx
[pa-auth]: ../../../../../people-ops-suite/apps/people-app/backend/modules/authorization/authorization.bal
[pa-test]: ../../../../../people-ops-suite/apps/people-app/backend/modules/authorization/tests/service_client_test.bal
[pa-svc]: ../../../../../people-ops-suite/apps/people-app/backend/service.bal
[pa-types]: ../../../../../people-ops-suite/apps/people-app/backend/modules/authorization/types.bal
[pa-local]: ../../../../../people-ops-suite/apps/people-app/backend/Config.toml.local
[pa-dbt]: ../../../../../people-ops-suite/apps/people-app/backend/modules/database/types.bal
[ag-notify]: ../../../../../wso2-digital-agents/po-agent/src/chat/notify.ts
[ag-api]: ../../../../../wso2-digital-agents/po-agent/.choreo/openapi.yaml
