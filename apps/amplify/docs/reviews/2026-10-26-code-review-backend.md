# Code review: Amplify backend (2026-10-26)

Reviewer: Claude (agent), for Developer Bechtel. Branch `main` of the marketing-tools fork at `e1620d9`, plus the uncommitted working tree.

## Scope

Everything under `apps/amplify` in these packages: [amplify-api](../../amplify-api/), [amplify-jobs](../../amplify-jobs/), [amplify-common](../../amplify-common/), [amplify-domain](../../amplify-domain/), [amplify-database](../../amplify-database/) and [amplify-scheduler](../../amplify-scheduler/). That covers Ballerina, SQL migrations and seeds, Dockerfiles and Choreo descriptors. I skipped `linkedin/resources`. In `local/` I only checked for anything unsafe.

This review replaces the four 2026-10-17 deep reviews. Every finding from them is carried forward with a status and evidence in the section "Carry-forward from the 2026-10-17 reviews". The code that landed after 2026-10-17 got most of my time: dashboards for the `amplify_*` roles, the person board, CSV export, scorecard configuration, the weekly top three, open leaderboards and the employee count cache, Novera announcements, share-as-repost, V011 to V014 and S005 to S007.

## Method

1. Read the four prior reports and their handoff lists first.
2. Listed what changed since 2026-10-17 with `git log --stat` and read each changed file in full: `dashboards.bal`, `dashboard_data.bal`, `groups.bal`, `topboard.bal`, `outbound.bal`, `service.bal`, `reporting/queries.bal`, `reporting/snapshot.bal`, `amplify-jobs/novera.bal`, `amplify-jobs/handlers.bal`, `config.bal`, V011 to V014, S005 to S007.
3. Applied the WSO2 Digital code review checklist, the WSO2 Digital coding standards and the engineering governance rules. Security items first: secrets, SQL parameterization, auth on every route, PII in logs.
4. Swept the whole tree for standards compliance: license headers on 226 source files, SQL building, log calls, `check`/`panic` use, dependency pins, Dockerfiles, descriptors, test layout.
5. Ran the repo's own gates and every unit test that needs no container.
6. Checked each carried-forward finding against the current code and tests.

I did not use the `code-reviewer` subagent. I did the review directly.

## Summary

| Severity | Count | Meaning |
| --- | --- | --- |
| Blocker | 3 resolved | Fix before the first upstream PR. A gate is red, or a change would break a running database. |
| Should fix | 9 | Fix before the slice it belongs to goes out. |
| Consider | 12 | Improvements, or decisions to record. |

All three blockers are resolved on 2026-10-26. The stale seed-count test now asserts `>= 7`. The `posts` property on the person board is renamed `campaigns` (contract, handler, tests and the One WSO2 popup), so `lint-openapi-names.sh` and `make check` are green. The comment edits in four scripts stay, because Developer confirmed no database has applied them. After the fixes `amplify-database` passes 23 tests, `amplify-domain` 109 and `amplify-api` 111, and the One WSO2 Amplify tests, type check and lint pass.

Most carried-forward findings are Fixed. Still open: api 23 (cron minimum interval), RC-12 (no nonce, by design) and D4/D5 (unused grants). Superseded: api 1 and R-13. The Won't fix decisions from October still stand. A few handoffs belong to the UI, docs or mock owners and are marked Not checked.

### What the team got right

- SQL is parameterized everywhere. The only dynamic pieces are `sql:queryConcat` over fixed fragments, and the `LIKE` prefix in `recognition/queries.bal:131` escapes `%`, `_` and `\`. No string-built SQL.
- Every dashboard handler reads from one repeatable-read snapshot ([snapshot.bal](../../amplify-domain/modules/reporting/snapshot.bal)) behind the transaction gate, and the tests pin each number without a database.
- The CSV export neutralizes formula injection ([dashboards.bal:454](../../amplify-api/dashboards.bal)) and the test covers it. Finding S1 below is about one side effect of that rule.
- `scripts/check-logs-pii.sh` scans 104 log calls and flags none. `scripts/check-transaction-gate.sh` finds all 20 transaction blocks behind `store:inTransaction`. `scripts/check-descriptors.sh` reports 5 components in sync.
- Dockerfiles pin base images by digest, run as a non-root user, and build the shared packages inside the build stage ([amplify-api/Dockerfile](../../amplify-api/Dockerfile)), so nothing depends on a developer's `~/.ballerina`.
- 222 of 226 source files carry the full Apache 2.0 header, matching the repo LICENSE. Four are missing it or have it cut off (see C8).
- No secrets are committed. `Config.toml` files hold test values only, and `local/.env.example` has empty secret fields.
- The team acted on the 2026-10-17 reviews. Almost every earlier finding has a regression test, and the tests pass.

## New findings

Line numbers are in the current working tree.

### Blockers

| ID | Where | Finding | Fix |
| --- | --- | --- | --- |
| B1 | [amplify-database/tests/main_test.bal:49](../../amplify-database/tests/main_test.bal) | `testShippedScriptsAreWellFormed` asserts 6 seed scripts. There are 7 since S007 (commit `ff4d031`). `bal test` in amplify-database fails: 22 passed, 1 failed (`expected '6' actual '7'`). The same test would fail again on every future seed. | Resolved 2026-10-26: asserts `>= 7`. |
| B2 | [V014:18](../../amplify-database/migrations/V014__point_actions_all_phases.sql), [S001:17](../../amplify-database/seed/S001__point_rules.sql), [S005:17](../../amplify-database/seed/S005__point_rules_pilot.sql), [S006:18](../../amplify-database/seed/S006__point_rules_all_values.sql) | Uncommitted edits change the comment path `docs/proposals/point-values.md` to `docs/requirements/point-values.md` in four applied scripts. The runner stores a SHA-256 of each script and stops on any change ([main.bal:245-248](../../amplify-database/main.bal): "was changed after it was applied; add a new script instead"). Every database that already applied these scripts (the local Compose volume, any dev database) will refuse to start the migrate step. The new path is correct, but the old one is frozen in the applied script. | Resolved by decision. No database has applied these scripts (confirmed by Developer, 2026-10-26), so the corrected comment path stays. If any database ever does apply them before this merges, put the corrected path in a README and revert the comments. |
| B3 | [amplify-api/openapi.yaml:1669](../../amplify-api/openapi.yaml) | `scripts/lint-openapi-names.sh` fails: the `posts` property on `DashboardPersonBoard` uses a banned L2-era word. `make check` is red on `main`. | Resolved 2026-10-26: renamed `posts` to `campaigns` in the contract, handler, tests and UI. |

### Should fix

| ID | Where | Finding | Fix |
| --- | --- | --- | --- |
| S1 | [dashboards.bal:454-467](../../amplify-api/dashboards.bal), [dashboards.bal:480](../../amplify-api/dashboards.bal) | `csvCell` puts a `'` in front of any cell that starts with `-`. The `points` column goes through it, so every reversal or negative adjustment exports as `'-5`. A spreadsheet then reads text, not a number, and sums are wrong. The test data ([read_fakes.bal:577-585](../../amplify-api/tests/read_fakes.bal)) has no negative points, so nothing catches it. | Skip the neutralizing for the `points` cell (it is an `int` we produced), or neutralize only when the text is not a plain integer. Add a negative-points row to the fake and the assertion in [dashboards_test.bal:235-253](../../amplify-api/tests/dashboards_test.bal). |
| S2 | [reporting/queries.bal:541](../../amplify-domain/modules/reporting/queries.bal), [dashboards.bal:473-483](../../amplify-api/dashboards.bal), [dashboards.bal:511-516](../../amplify-api/dashboards.bal) | The export loads up to 200,000 rows into a `ExportRow[]`, then builds one string in memory, for a range of up to 366 days. At the cap the data is cut silently: the file looks complete and is not. One export on a small Choreo container can also push the heap. | Query `LIMIT cap + 1`. When it returns more than the cap, answer 422 `EXPORT_TOO_LARGE` with a hint to narrow the range. Pick the cap from a measured heap, and document it in `openapi.yaml`. Streaming the body is the longer fix. |
| S3 | [dashboards.bal:498](../../amplify-api/dashboards.bal) (export), [dashboards.bal:573](../../amplify-api/dashboards.bal) (person board), [queries.bal:444](../../amplify-domain/modules/reporting/queries.bal) (reposter emails) | These routes return or export names and work emails of many employees, and nothing records who read them. Only denials are logged ([interceptors.bal:71](../../amplify-api/interceptors.bal)). The governance rule is that bulk personal-data access leaves a trail. | One `log:printInfo` per export and per person-board read with `employeeId` of the caller, the route, the date range and the row count, and no names or emails (stays inside `check-logs-pii.sh`). The audit table is an option if Security wants it durable. |
| S4 | Security docs under `architecture/security/` | The threat model (v0.3, 2026-10-19) and the deployment checklist have no rows for the new surface: dashboards and CSV export, the person board, open leaderboards that return every employee's email to any employee ([groups.bal:340](../../amplify-api/groups.bal)), `/headcount`, Novera egress with its client-credentials token, and ID-token validation. CLAUDE.md says the security docs keep covering later-phase endpoints. | Add the rows, and have the owner confirm the open-board email exposure (ADR-035) with a short note in the model. |
| S5 | [amplify-jobs/config.bal:73-80](../../amplify-jobs/config.bal) | The comments on `amplifyOnNovera` and `amplifyOnWebhook` say "Not acted on yet: the Novera sender does not exist". Both are acted on now ([outbound.bal:48](../../amplify-jobs/outbound.bal), [outbound.bal:58](../../amplify-jobs/outbound.bal)). The next reader will trust a comment that is wrong. | Rewrite both comments to say what each flag does today. |
| S6 | [docs/migrations/README.md:3-5](../migrations/README.md) | Lists scripts as V001 to V013 and S001 to S004. Current set is V001 to V014 and S001 to S007. No dated note exists for V011 or V014 (code review checklist item 11: context, changed files, revert steps). | Update the range and add `2026-10-xx-v011-...md` and `2026-10-xx-v014-...md` in the same format as the V012 and V013 notes. |
| S7 | [V013:23](../../amplify-database/migrations/V013__idle_timeout_dashboard_indexes.sql), [store.bal:159](../../amplify-domain/modules/store/store.bal), [tx_gate.bal:18](../../amplify-domain/modules/store/tx_gate.bal), [check-transaction-gate.sh:18](../../scripts/check-transaction-gate.sh), [CLAUDE.md:31](../../CLAUDE.md), [V012 note](../migrations/2026-10-17-v012-recognition-lock-maintenance-timeout.md), [V013 note](../migrations/2026-10-17-v013-idle-timeout-dashboard-indexes.md) | Source and docs cite the 2026-10-17 review files by path, including `2026-10-17-r13-transaction-race.md`, `...-deep-review-amplify-domain.md`, `...-deep-review-jobs-db-infra.md` and `...-round2-handoffs.md`. Deleting those reports leaves dead references. V013 is an applied script, so its comment cannot be repaired afterward. | Keep `2026-10-17-r13-transaction-race.md` (V013 depends on it). For the others, repoint the live files to this report or to an ADR in the same change that removes the old reports. |
| S8 | marketing-tools root | The fork has no `.github/workflows`. The five gates (`check-descriptors`, `check-logs-pii`, `check-transaction-gate`, `lint-openapi-names`, `bal test`) only run when someone runs them by hand. B3 sat red on `main` for that reason. With about 100 small upstream PRs, each needs the gates to run for it. | Add a workflow that runs the scripts and the unit tests per package. Needs the Ballerina 2201.13.3 image that the Dockerfiles use. |
| S9 | [amplify-jobs/handlers.bal:190-192](../../amplify-jobs/handlers.bal), [dashboards.bal:351](../../amplify-api/dashboards.bal) | Novera answers 202 before it sends ([novera.bal:6](../../amplify-jobs/novera.bal)). The handler marks the announcement `SENT` on that 202, and the scorecard measure "Chat cards delivered" counts those rows. A card that Novera accepted and never delivered still counts as delivered. | Rename the measure to "Chat cards accepted" until Novera reports delivery, or note it in the measure's `note`. |

### Consider

| ID | Where | Finding |
| --- | --- | --- |
| C1 | [outbound.bal:408-433](../../amplify-api/outbound.bal), [outbound.bal:529-560](../../amplify-api/outbound.bal) | Team index and employee count refresh with no single flight. At expiry, concurrent callers each fetch the whole directory. With the breaker at `requestVolumeThreshold: 1` the damage stays small, but one in-flight refresh and everyone else on the stale copy is cheap to add. Cache lifetimes are long (3 days for teams, 7 days for the count), so someone who leaves or changes teams stays on a roster for that long. That is a product call. Worth stating in the ADR. |
| C2 | [dashboard_data.bal:23-37](../../amplify-api/dashboard_data.bal), [topboard.bal:62-84](../../amplify-api/topboard.bal) | Same shape for the dashboard snapshot and the weekly totals: no single flight, so at a 60 s expiry several callers can each run the roughly 15 snapshot statements. Fine at pilot volume. `weeklyTotals` also clones the full totals array on every read. |
| C3 | [novera.bal:119-122](../../amplify-jobs/novera.bal) | `breaker()` returns `CLOSED` before the client has ever been built. ADR-028 uses `NOT_CONFIGURED` for a dependency with no client. Also 408 and 425 answers are treated as non-retryable `REJECTED`. |
| C4 | [queries.bal:444](../../amplify-domain/modules/reporting/queries.bal), [queries.bal:621](../../amplify-domain/modules/reporting/queries.bal), [queries.bal:186](../../amplify-domain/modules/reporting/queries.bal) | Reposters (2000), a person's posts (200) and campaigns on the board (200) cut off silently. Say so in `openapi.yaml`, so the UI can show "first 2000". |
| C5 | [amplify-domain/modules/reporting/snapshot.bal:117-118](../../amplify-domain/modules/reporting/snapshot.bal) | `checkpanic` on `int:fromString` of a substring of our own timestamp. Cannot fail today. A `check` costs nothing and keeps the "no panic" rule clean. |
| C6 | [matrix.bal:101](../../amplify-api/modules/auth/matrix.bal) | `useCase` says "against the scorecard.* targets". Targets moved to configuration (commit `59b72d4`). |
| C7 | [amplify-api/tests/dashboards_test.bal:120](../../amplify-api/tests/dashboards_test.bal) | Compile warning: `check byDay[0]` where the expression cannot be an error. |
| C8 | [unlink-linkedin-user.sh](../../scripts/unlink-linkedin-user.sh), [gateway.mjs](../../local/people-app-proto/gateway.mjs), [seed.sql](../../local/people-app-proto/seed.sql), [server.mjs:15](../../local/novera-mock/server.mjs) | Missing license header on the first three; the Novera mock header is cut off before "under the License.". The script's usage line ([line 4](../../scripts/unlink-linkedin-user.sh)) and two fixtures ([directory.json:126](../../local/people-stub/directory.json), [seed.sql:39](../../local/people-app-proto/seed.sql)) contain a real employee work email. Use `first.last@example.com`. |
| C9 | [.choreo/component.yaml:21,23](../../.choreo/component.yaml) | `resourceRef` values still say `REPLACE_WITH_ID`. Expected before the console steps in the deploy runbook. Make sure the runbook says to replace them per environment and the go-live check catches a leftover. |
| C10 | `apps/amplify/architecture/` | The folder is untracked. Source comments and READMEs link into it ([matrix.bal](../../amplify-api/modules/auth/matrix.bal), [amplify-api/CLAUDE.md](../../amplify-api/CLAUDE.md), [README.md](../../README.md), the domain and database READMEs), and code comments cite ADR-035, 036 and 037. If the PRs do not carry that folder, every link and ADR number dangles. A `.DS_Store` sits in `architecture/solution/`; keep it out. |
| C11 | Unit coverage from this run | amplify-common 98.2%, amplify-api 85.6%, amplify-jobs 76.7%, amplify-domain 39.6%, amplify-database 26.2%. The domain and database numbers are low because their real tests are the Postgres integration groups, which need a container and were not run (see "Commands and results"). The reporting queries are only exercised by `integration_reporting_test.bal`. |
| C12 | [openapi.yaml:98](../../amplify-api/openapi.yaml), [matrix.bal:104](../../amplify-api/modules/auth/matrix.bal) | Prior open items still stand and are not new: the cron minimum interval (api finding 23) and the app-role grants nobody uses (D4, D5). Listed here so the PR slicing does not forget them. |

## Things to fix before the PRs go out

Ranked. Blockers first. "Slice" means the PR group the fix belongs to, so it goes out in the same PR as the code it touches.

| Rank | ID | Severity | Fix | File | Slice |
| --- | --- | --- | --- | --- | --- |
| 1 | B1 | Resolved | Make the seed-count assertion `>=` 7 or derive it from the folder | `amplify-database/tests/main_test.bal:49` | amplify-database tests (S007) |
| 2 | B2 | Resolved | Comment edits in V014, S001, S005, S006 stay: no database has applied these scripts. Revisit only if one does | `amplify-database/migrations/V014__...sql:18`, `seed/S001:17`, `S005:17`, `S006:18` | amplify-database migrations and seeds |
| 3 | B3 | Resolved | Rename `posts` or add a reasoned lint exception. Gate must be green | `amplify-api/openapi.yaml:1669`, `scripts/lint-openapi-names.sh` | amplify-api contract |
| 4 | S1 | Should fix | Stop prefixing `-` on the `points` column, add a negative-points test | `amplify-api/dashboards.bal:454-467`, `tests/read_fakes.bal:577` | dashboards export |
| 5 | S2 | Should fix | Cap the export and fail loudly, do not truncate | `amplify-domain/modules/reporting/queries.bal:541`, `amplify-api/dashboards.bal:498-519` | dashboards export |
| 6 | S3 | Should fix | Log who exported or opened a person board (caller id, range, count), no PII | `amplify-api/dashboards.bal:498`, `:573` | dashboards export, person board |
| 7 | S4 | Should fix | Add threat model and checklist rows for dashboards, export, open boards, headcount, Novera, ID token | `architecture/security/the v0.3 threat model`, the v0.1 security checklist | docs slice before any endpoint slice that adds those routes |
| 8 | S7 | Should fix | Done 2026-10-26: the R-13 note is kept, the 17 Oct deep reviews are replaced by this report, and the live references now point here | `V013:23`, `store.bal:159`, `tx_gate.bal:18`, `scripts/check-transaction-gate.sh:18`, `CLAUDE.md:31` | wherever the old reports are removed |
| 9 | S8 | Should fix | Add a CI workflow that runs the gates and `bal test` per package | marketing-tools `.github/workflows/` | first slice, so every later PR runs it |
| 10 | S5 | Should fix | Fix the stale "not acted on yet" comments | `amplify-jobs/config.bal:73-80` | Novera announcements |
| 11 | S6 | Should fix | Update the migrations README and add V011 and V014 notes | `docs/migrations/README.md:3-5` | amplify-database migrations |
| 12 | S9 | Should fix | Call the scorecard measure "accepted", or add the note | `amplify-api/dashboards.bal:351`, `amplify-jobs/handlers.bal:190` | Novera announcements, scorecard |
| 13 | C10 | Consider | Decide how `architecture/` ships, or rewrite links before the READMEs and code comments go out | `amplify-api/modules/auth/matrix.bal`, READMEs, `CLAUDE.md` files | docs slices |
| 14 | C8 | Consider | Add or complete license headers, replace the real email in fixtures | `scripts/unlink-linkedin-user.sh`, `local/people-app-proto/*`, `local/novera-mock/server.mjs` | local tooling slice |
| 15 | C6, C7, C5, C4, C3, C2, C1, C9, C11, C12 | Consider | See the Consider table | various | whichever slice touches the file |

**Blockers for upstream: B1, B2, B3.** S8 is not a code blocker, but without it nothing stops the next red gate from reaching the fork.

## Carry-forward from the 2026-10-17 reviews

Status values: **Fixed** (the fix is in the current tree), **Superseded** (the code it described no longer exists), **Still open**, **Won't fix** (the earlier decision still stands, nothing changed). "Fixed" for the database and domain items rests on the unit tests that pass here plus the code. The matching integration tests need Postgres and were not run.

### amplify-api (17 Oct deep review)

| ID | Status | Evidence |
| --- | --- | --- |
| 1 | Superseded | The per-viewer roster call is gone. Teams come from the cached directory index ([outbound.bal:408-433](../../amplify-api/outbound.bal)). The parse error is kept out of the log ([outbound.bal:441](../../amplify-api/outbound.bal)). |
| 2 | Fixed | [handlers.bal:131-150](../../amplify-api/handlers.bal) applies the patch to the checked row and calls `repo.update(changed, body.version)`. |
| 3 | Fixed | [scheduler_sync.bal:150](../../amplify-api/scheduler_sync.bal) uses `freshSettings`. Test in `tests/writes_test.bal`. |
| 4 | Fixed | Generation counter in [settings.bal:99-108](../../amplify-api/settings.bal). Test in `tests/writes_test.bal`. |
| 5 | Fixed | [handlers.bal:198-199](../../amplify-api/handlers.bal) refuses backslash, whitespace and control characters. |
| 6 | Fixed | [handlers.bal:209-213](../../amplify-api/handlers.bal) and `checkRedirectUri` in [outbound.bal](../../amplify-api/outbound.bal). |
| 7 | Fixed | [reads.bal:234](../../amplify-api/reads.bal) drops the ETag on a degraded body. |
| 8 | Fixed | [reads.bal:192-195](../../amplify-api/reads.bal) sends `ETag` and `Cache-Control` on the 304. |
| 9 | Fixed | `breakerOf` returns `NOT_CONFIGURED` ([outbound.bal](../../amplify-api/outbound.bal)). |
| 10 | Fixed | [openapi.yaml:1056-1063](../../amplify-api/openapi.yaml) lists the codes. |
| 11 | Fixed | `tests/contract_drift_test.bal` passes. |
| 12 | Fixed | `testHistoryScope` passes. |
| 13 | Fixed | [idempotency.bal:56-58, 80-82](../../amplify-api/idempotency.bal) use `loggable` and `recordDbFailure`. |
| 14 | Fixed | Reads go through `okJson` and `jsonBody` ([service.bal](../../amplify-api/service.bal), [json_body.bal](../../amplify-api/json_body.bal)). |
| 15 | Fixed | [matrix.bal:104](../../amplify-api/modules/auth/matrix.bal) states the real rule. |
| 16 | Fixed | `DASHBOARD_CACHE_MAX = 24` ([reads.bal:358](../../amplify-api/reads.bal)). |
| 17 | Fixed | [interceptors.bal:148](../../amplify-api/interceptors.bal) defaults to `no-store`. |
| 18 | Fixed | [handlers.bal:118-121](../../amplify-api/handlers.bal). |
| 19 | Fixed | [interceptors.bal:194](../../amplify-api/interceptors.bal) uses `METHOD_NOT_ALLOWED`. |
| 20 | Fixed | Test clients run with the cache off. All 110 api tests pass. |
| 21 | Fixed | The retry insert is in `claimIdempotencyKey` ([store/settings.bal:149-163](../../amplify-domain/modules/store/settings.bal)). Handoff H2 done. |
| 22 | Fixed | `completeConnection` takes the token and writes it with the connection ([handlers.bal:241-249](../../amplify-api/handlers.bal)). Handoff H3 done. |
| 23 | Still open | [schedule.bal:75-96](../../amplify-api/modules/scheduler/schedule.bal): the minimum only applies to `@every`. A cron such as `* * * * *` passes. Needs the ADR 026 wording decision first. |
| 24, 25, 26 | Won't fix | Unchanged (ADR-024, the ETag contract, ADR-005). |
| 27 | No change | Unchanged. |
| H1 | Fixed, off by default | ID-token validation is wired ([handlers.bal:236](../../amplify-api/handlers.bal), [outbound.bal:67-69](../../amplify-api/outbound.bal)) behind `linkedinIdTokenValidation = false`. No nonce and no PKCE, as the code comment explains. Turning it on is a go-live decision. |
| H5, H6 | Not checked | One WSO2 UI and docs owners. Outside this code. |

### amplify-common (17 Oct deep review)

| ID | Status | Evidence |
| --- | --- | --- |
| RC-01 | Fixed | `IdTokenValidator` in `id_token.bal`, wired in the api (H1 above). |
| RC-02 to RC-09 | Fixed | The regression tests are present and pass (`evidencePostsUrnKeepsTheUrnInvariant`, `webhookPlainHttpOnlyForExactLoopbackHosts`, `cardImageRejectsTrailingDotAndNumericHosts`, `exchangeCodeRejectsUnusableTokenBodies`, `awardReferenceRejectsUntrimmedParts`, `loggableRedactsWrapperMessages`, the reseal tests). 158 common tests pass. |
| RC-03 follow-up (H5) | Fixed | [handlers.bal:283](../../amplify-jobs/handlers.bal) passes `targetTitle`. |
| RC-10 | Fixed | Test ports moved into the 182xx range. 158 tests pass in parallel without clashes. |
| RC-11 | Won't fix | LinkedIn offers PKCE to native clients only. |
| RC-12 | Still open, by design | The library supports the nonce. The api sends none, and says why ([outbound.bal:67-69](../../amplify-api/outbound.bal)). |
| RC-13 | Fixed | The validator defaults to `linkedin:LINKEDIN_OIDC_ISSUER`, configurable ([outbound.bal](../../amplify-api/outbound.bal)). |
| RC-14 to RC-17 | Won't fix | Unchanged. |
| RC-18 | Not rechecked | Doc only. |
| RC-19 | Fixed | All consumers are on `amplify_common` 0.6.0 and `amplify_domain` 0.3.0 ([amplify-api/Ballerina.toml](../../amplify-api/Ballerina.toml)). |
| H4 (rotation) | Fixed | `updateSeal` ([repository.bal:210](../../amplify-domain/modules/connection/repository.bal)), `resealToken` ([service.bal:231](../../amplify-domain/modules/connection/service.bal)), jobs step reports failures ([types.bal:71](../../amplify-jobs/types.bal)). |
| H2 (mock ID token) | Not checked | Lives in `linkedin/`, out of scope. |

### amplify-domain (17 Oct deep review)

| ID | Status | Evidence |
| --- | --- | --- |
| R-01 | Fixed | `lockRecognition` in [scoring/repository.bal:242](../../amplify-domain/modules/scoring/repository.bal) and [recognition/repository.bal:117](../../amplify-domain/modules/recognition/repository.bal), plus V012. IT not run here. |
| R-02 | Fixed | `markedBy` ([events.bal:66](../../amplify-domain/modules/external_sharing/events.bal)). `claimantCantMarkOwnClaimAmplified` passes. |
| R-03 | Fixed | `auditOf` carries `before`. Covered by `testAuditBeforeAfterAndVersionConflictRollsBack` (IT, not run). |
| R-04 | Fixed | `dbSslMode` defaults to `VERIFY_FULL` and both apps pass `sslRootCert` ([api database.bal:49,148](../../amplify-api/database.bal), [jobs database.bal:38,162](../../amplify-jobs/database.bal)). |
| R-05 | Fixed | See RC H4 above. |
| R-06 | Fixed | [announcements/repository.bal:113-119](../../amplify-domain/modules/announcements/repository.bal). |
| R-07 | Fixed | `pageWindow` in scoring, recognition and external sharing queries. |
| R-08, R-09 | Fixed | [store/settings.bal:149-163](../../amplify-domain/modules/store/settings.bal). |
| R-10, R-11, R-12 | Fixed | Tests present in `tests/integration_review_test.bal`. IT, not run. |
| R-13 | Superseded | The runtime race is handled by the transaction gate (ADR-032, `check-transaction-gate.sh` passes: 20 of 20 blocks) and the 30 s idle timeout in V013. The platform bug remains until Ballerina 2201.14.1. |
| R-14 | Fixed | `recordDuplicatePublish` settles the request ([handlers.bal:292-299](../../amplify-jobs/handlers.bal)). Test `duplicatePublishSettlesOnTheExistingEngagement` passes. |
| R-15 | Fixed in part | V013 adds `points_ledger (created_at)` and `share_request (failed_at)`. The other two were left out after `EXPLAIN` showed the planner did not use them (V013 header). |
| R-16 | Fixed | Same change as api 22. |
| R-17, R-18, R-19 | Won't fix | Unchanged. |

### amplify-jobs, amplify-database, infra (17 Oct deep review)

| ID | Status | Evidence |
| --- | --- | --- |
| J1 | Fixed | `GET /ready` ([service.bal:57](../../amplify-jobs/service.bal), [ready.bal](../../amplify-jobs/ready.bal)). |
| J2 | Fixed | `trap` around acquire and execute ([run.bal:81-88](../../amplify-jobs/run.bal)). |
| J3 | Fixed | `validateRunConfig` runs at start ([service.bal:32](../../amplify-jobs/service.bal), [ready.bal:67](../../amplify-jobs/ready.bal)). |
| J4 | Fixed | `aShareThatNeverReachesLinkedInDoesNotUseTheCeiling` passes. |
| J5 to J8 | Won't fix | Unchanged. J8 (no caller auth on `/runs`) still rests on Project visibility. |
| D1, D2 | Fixed | V012. The V013 test covers the lock order. IT not run. |
| D3 | Fixed | `testMisnamedSqlScriptStopsTheRun` passes. |
| D4, D5 | Still open | No `REVOKE` migration exists beyond V001 and V003. App roles still hold grants nothing uses. Needs the data-model owner's decision. |
| D6 to D9 | Won't fix | Unchanged. |
| D10 | Superseded | The ranges went stale again. See S6. |
| I1 | Fixed | Every `FROM` and compose `image:` has a digest. `check-descriptors.sh` checks for it. |
| I2 | Fixed | [history-retention.sql](../../amplify-scheduler/history-retention.sql) exists. |
| I3, I6 | Fixed | `check-descriptors.sh` passes. |
| I4, I5, I7 | Won't fix | Unchanged. |
| I8, I9 | Not rechecked | Docs only. |

## Standards sweep

| Check | Result |
| --- | --- |
| License header, current year, Apache 2.0 to match LICENSE | 222 of 226 files pass. Four fail, see C8. |
| Secrets in tracked files | None. Test configs hold test values. `.env.example` secret fields are empty. |
| SQL parameterization | Pass. Only fixed fragments are concatenated. `arrayLiteral` output always goes in as a bound `${}` value. |
| Logging without PII | `check-logs-pii.sh`: 104 calls, 0 flagged. A manual grep for email, name, commentary and token near log calls found nothing. |
| Typed errors, no raw error to callers | Pass. `failure()` maps to problem details and logs with `resilience:loggable`. |
| `check`/`panic` | One `checkpanic` pair in `snapshot.bal` (C5) and one in `ledger.bal:179` on a fixed hex digit. |
| Auth on every route | Pass. Every new route has a matrix row. `DASHBOARD_READERS` excludes plain employees. Default deny is unchanged. |
| Config not hardcoded | Pass. Scorecard targets, cache lifetimes and Novera settings are `configurable` and in `.choreo/component.yaml` and `workload.yaml`. |
| Dependencies | `Dependencies.toml` committed in all packages. One distribution (2201.13.3). |
| Dockerfiles | Digest pinned, non-root user, shared packages built in-stage. |
| Descriptors | `check-descriptors.sh`: in sync. Only the `REPLACE_WITH_ID` placeholders remain (C9). |
| Tests | See next section. |

## Commands and results

All run from `apps/amplify`, with Ballerina 2201.13.3 (the version the Dockerfiles use). No Docker, no Compose, no `bal push`, no `make`, no integration groups.

| Command | Result |
| --- | --- |
| `bash scripts/check-descriptors.sh` | Pass: 5 components in sync |
| `bash scripts/check-logs-pii.sh` | Pass: 104 calls scanned, 0 flagged |
| `bash scripts/check-transaction-gate.sh` | Pass: 20 of 20 blocks gated |
| `bash scripts/lint-openapi-names.sh` | **Fail:** `posts` (B3) |
| `bal test --code-coverage` in amplify-common | 158 passed, 0 failed. Coverage 98.2% |
| `bal test --code-coverage` in amplify-domain | 108 passed, 0 failed. Coverage 39.6% (integration groups not run) |
| `bal test --code-coverage` in amplify-api | 110 passed, 0 failed. Coverage 85.6%. One compile warning (C7) |
| `bal test --code-coverage` in amplify-jobs | 60 passed, 0 failed. Coverage 76.7% |
| `bal test --code-coverage` in amplify-database | 22 passed, **1 failed** (B1). Coverage 26.2% |
| amplify-scheduler | No Ballerina code. `history-retention.sql` and its IT (`scripts/it-scheduler-history.sh`) not run |

Not run, because they need containers: the domain and database integration groups (`AMPLIFY_IT`), `scripts/test-all.sh`, `make e2e`, the scheduler IT, the load test. Every "Fixed" that rests only on one of those is marked "IT not run" above.

Compared with 2026-10-17: api went from 75 to 110 tests, jobs from 45 to 60, common from 155 to 158, domain from 83 to 108. The build stayed green except for B1.

## Not covered

- `linkedin/resources` (vendor exports) and the mock server code, by instruction.
- The One WSO2 UI, people-app and the Choreo console steps.
- Integration tests and any behavior that needs a running Postgres, such as whether `SET TRANSACTION ISOLATION LEVEL` must come first inside the gated transaction. The test suite from 2026-10-22 says it does, and I did not re-run it.
- Load behavior of the export at the 200,000 row cap (S2). I read the code. I did not measure the heap.
