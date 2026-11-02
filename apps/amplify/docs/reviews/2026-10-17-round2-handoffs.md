# Round 2: the round 1 handoffs, implemented (2026-10-17)

Branch `rv2-backend` (off `feat/phase1-build` @ `8dd467d`). Round 1 had four reviewers, one per package
(`2026-10-17-deep-review-{amplify-common,amplify-domain,amplify-api,jobs-db-infra}.md`), and each left
HANDOFF items for code outside its own package. This round takes those handoffs across packages, adds a
regression test for each one, and adds item 12, the R-13 transaction gate
(`2026-10-17-r13-transaction-race.md`).

New versions: **amplify_common 0.6.0**, **amplify_domain 0.2.0**. New migration: **V013**.

## Status

| Item | Handoff IDs | Status | What changed | Main files | Tests |
|---|---|---|---|---|---|
| 1 | common H6 | Done | Bumped `amplify_common` to 0.6.0 and `amplify_domain` to 0.2.0. The `[[dependency]]` pins in domain, api and jobs and the CLAUDE.md version notes moved with them. The Dockerfiles and `test-all.sh` already pack common, then domain, then build, so no change was needed (verified by the e2e tier, which builds the images from a clean context). `file` and `os` show up in the bala dependency graph because `http` pulls them in (`http -> file -> os`). Only `id_token_test.bal` imports them directly, and test modules aren't in the bala, so I left them. | `apps/*/Ballerina.toml`, `Dependencies.toml`, `amplify-common/CLAUDE.md`, `amplify-domain/CLAUDE.md` | Every package builds and tests against the new versions (unit tier) |
| 2 | domain H-1 | Done | api and jobs default `dbSslMode` to `VERIFY_FULL` and take `dbSslRootCert`, passed as `sslRootCert` to the pool and to the jobs run-lock connection (both go through one `dbConfig()` per package). At start-up they log a warning when the server isn't verified and the host isn't local (loopback or a single-label Compose name), via `store:tlsWarning`. Compose keeps `DISABLE`. `BAL_CONFIG_VAR_DBSSLROOTCERT` is in both Choreo descriptors (with the file-mount note), both `workload.yaml`s and the README table. | `amplify-api/database.bal`, `amplify-jobs/database.bal`, `service.bal` (both), `amplify-domain/modules/store/store.bal`, `.choreo/component.yaml`, `apps/.choreo/component.yaml`, `workload.yaml` (both), `README.md` | `store_test:tlsWarningOnlyForUnverifiedRemoteHosts`, api `testDbConfigVerifiesTheServerByDefault`, jobs `dbConfigVerifiesTheServerByDefault`; `check-descriptors.sh` passes |
| 3 | common H4, domain H-2, jobs H2 | Done | Added `connection:resealToken` (wraps `TokenCipher.reseal`, same AAD) and `resealStaleTokens` (keyset pages over `PgTokenRepository.sealedWithOtherKey`, updates through the key-id-guarded `updateSeal`; a row that doesn't open is counted and left alone). In jobs, `resealOnUse` runs right after a successful `openToken`. It's best effort: it never fails the share and never logs token material. `POST /maintenance/partitions` now runs the rotation pass and reports `token_rotation {status, resealed, skipped, failed}`, which is never fatal. The jobs openapi `MaintenanceReport` has the new field. | `amplify-domain/modules/connection/{service,repository,types}.bal`, `amplify-jobs/{handlers,ports,types,service}.bal`, `amplify-jobs/openapi.yaml` | Two-key tests: domain unit `resealTokenMovesAnOldKeyRowToTheActiveKey`, `resealStaleTokensPagesThroughOldKeyRows`; domain IT `testResealStaleTokensAgainstTheDatabase`; jobs `aTokenOnAnOldKeyIsResealedOnUse`, `rotationStepReportsAndNeverFails` |
| 4 | common H1, api H1 | Done | New configurables `linkedinIdTokenValidation` (default `false`), `linkedinJwksUrl` and `linkedinOidcIssuer`. With the flag on, `completeConnect` calls `IdTokenValidator.validate(grant.idToken, ())` after the exchange and userinfo. It refuses a missing token or one that fails validation with 422 `OAUTH_STATE_INVALID` (the reason goes only to the log; JWKS unavailable gives 503), and it requires `claims.sub == profile.sub`. `/ready` reports `linkedinIdTokenJwks` without gating on it, and `ReadyStatus` in the openapi has it. No nonce, no PKCE. | `amplify-api/{outbound,handlers}.bal`, `amplify-api/openapi.yaml`, `.choreo/component.yaml`, `workload.yaml` | `id_token_test`: good, bad signature, wrong aud, expired, missing, sub mismatch, flag off; `/ready` reports without gating; contract drift test |
| 5 | common H5, jobs H1 | Done | `publishShare` gets `targetTitle: c is () ? () : c.title`. | `amplify-jobs/handlers.bal` | jobs `shareCarriesTheCampaignTitle`; jobs IT `testShareArticleCarriesTheCampaignTitleToLinkedIn` (a SHARE_COMMENTARY post through the Run reaches mock_linkedin, which stores `articleTitle`, and the title is the campaign's) |
| 6 | domain H-5 | Done | When `recordPublish` hits an engagement unique violation, jobs calls the new `PgShareRepository.recordDuplicatePublish`. It links the request to the employee's existing engagement and marks it `PUBLISHED`, with no new engagement and no `EngagementRecorded`, so nothing is scored twice. If no matching engagement exists, the share fails with `PROVIDER_REJECTED` / `DUPLICATE_ENGAGEMENT`. Either way the request never stays `QUEUED`. Pure helper: `sharing:asDuplicatePublish`. | `amplify-domain/modules/sharing/{service,repository}.bal`, `amplify-jobs/{handlers,ports}.bal` | domain unit `duplicatePublishSettlesOnTheExistingEngagement`; domain IT `testDuplicatePublishSettlesTheShare`; jobs `duplicatePublishSettlesOnTheExistingEngagement`, `duplicateWithoutAMatchingEngagementFailsTheShare` |
| 7 | api H2 | Done (test added) | The domain reviewer had already put the one-time insert retry in `store:claimIdempotencyKey` during round 1, untested. This round adds the regression test: a statement trigger, installed by the IT as the admin user, deletes the holder's row right after the conflicting INSERT, which forces the "0 rows inserted, then no row found" window. The claim now wins instead of returning NoRows (503). | `amplify-domain/modules/store/settings.bal` (unchanged logic) | domain IT `testIdempotencyClaimRetriesWhenTheHolderVanishes` |
| 8 | api H3 | Done | I picked the option where the token travels with the change: `ConnectionChange.tokenToInsert`. `completeConnection(..., token)` checks the row matches the command and its owner, and `PgConnectionRepository.save` inserts it first inside the connection's transaction. `completeConnect` no longer calls `tokenRepository().insert`. | `amplify-domain/modules/connection/{types,service,repository}.bal`, `amplify-api/handlers.bal` | domain IT `testConnectionWriteFailureLeavesNoTokenRow` (stale version, then member unique key: no token row either time); domain unit `completeConnectionHandsTheSealedTokenToTheSameSave`; api `testConnectCompleteFlowAndStateRules` (token handed to save, never inserted alone) |
| 9 | domain H-3b, H-4 | Done | `V013__idle_timeout_dashboard_indexes.sql` sets `idle_in_transaction_session_timeout = '30s'` on `amplify_api` and `amplify_jobs` (30 s per item 12.6, not 60 s; it runs as the bootstrap admin, before `SET LOCAL ROLE`). It adds `points_ledger (created_at)` and partial `share_request (failed_at)`, the two indexes the planner used in EXPLAIN on a seeded copy (30k ledger rows, 6k shares, 4k claims). The `published_at` and `decided_at` indexes weren't used, because those tiles aggregate the whole table with `FILTER`, so they aren't added. EXPLAIN output is in the dated note. | `amplify-database/migrations/V013__idle_timeout_dashboard_indexes.sql`, `docs/migrations/2026-10-17-v013-idle-timeout-dashboard-indexes.md`, `migrations/README.md`, `docs/migrations/README.md` | DB IT `testV013RoleIdleTimeoutAndIndexes` (role setting, a fresh session sees `30s`, both index definitions) |
| 10 | common RC-03 (H2), jobs H5 | Partial | mock_linkedin refuses `/rest/posts` with an article and no (or a blank) `content.article.title`, the way the real API does, and `/mock/posts` now shows `articleTitle`. Its Dockerfile pins both base images by the same digests as the Amplify Dockerfiles, and `check-descriptors.sh` now checks the mock's digests too. **Skipped: the optional RS256 `id_token` + JWKS in the mock.** Ballerina's `crypto` can't generate an RSA key or expose a key's modulus, so the mock would need a key file plus its JWK supplied through config, and test-all would have to mint both. That's more than reasonable effort for this round. The ID-token path is covered by api unit tests against the test gateway's JWKS instead. The e2e flow still passes. | `projects/linkedin/apps/mock_linkedin/{api_service.bal,types.bal,modules/store/store.bal,Dockerfile,README.md,tests/mock_linkedin_test.bal}`, `scripts/check-descriptors.sh` | mock `testArticlePostNeedsATitle`; jobs IT title test above; e2e tier |
| 11 | round 2 | Done | Both sites name the other lock and the required order. On the app side that's `store:RECOGNITION_LOCK_KEY`, `lockRecognition` and the two call sites. On the SQL side it's V013's `COMMENT ON FUNCTION` for `apply_ledger_entry`, `rerank` and `rebuild`, since V012 can't be edited. Added `store:RECOGNITION_SQL_LOCK_KEY`. Both locks stay. | `amplify-domain/modules/store/store.bal`, `scoring/repository.bal`, `recognition/repository.bal`, V013 | domain unit `testRecognitionLocksAreTakenInOrder` (scans domain, api and jobs: every `recognition.*` SQL call comes after `lockRecognition` in the same function), `testLockOrderScanCatchesAReversedCall`; DB IT `testRecognitionLockOrderOnTheSqlSide` (no SQL function takes 4242101; the three that take 1634561133 carry the order comment) |
| 12 | R-13 | Done | See below. | | |

## Item 12: the R-13 transaction gate

On Ballerina 2201.13.3, concurrent `transaction {}` blocks race on an unsynchronized HashMap in the runtime
(ballerina-lang #44737; fixed by PR #44747 in 2201.14 only). The race can throw a CME, can report a commit
that never happened, and leaks the pool connection.

1. **Gate.** `amplify_domain.store` gets `inTransaction(isolated function () returns error?)` and
   `inTransactionValue(isolated function () returns anydata|error)` (`modules/store/tx_gate.bal`). Both lock
   the same isolated variable `txGate`. The file cites #44737 / PR #44747 and says to remove it after the
   upgrade to 2201.14.1+.
2. **All 19 product transaction blocks go through it.** 17 are in amplify-domain and 2 in amplify-api
   (`auditTx`, which `recordDenial` and `recordAudit` now share, and `dashboardTx`); amplify-jobs has none of
   its own. Each block now sits in a non-public `...Tx` function, and the public method passes
   `cloneReadOnly()` copies into the closure. `scripts/check-transaction-gate.sh` (it has a `--self-test`,
   and both run from `make check`) fails if a block sits outside a non-public `...Tx` function, if a `...Tx`
   function is called on a line that doesn't call the gate, or on any `retry transaction`. One trap the IT
   caught: inside the gate the values are read-only, and `clone()` of a read-only value stays read-only, so
   a `...Tx` body that needs a mutable copy has to use `cloneWithType` (`asDuplicatePublish` does).
3. **`lockRecognition`.** I picked option 2, a shorter poll held inside the gate:
   `RECOGNITION_LOCK_WAIT_SECONDS` dropped from 10 s to 2 s. Inside one process the gate already
   serializes recognition writers, so the advisory lock only arbitrates between processes, and its holders
   keep it for milliseconds. This is documented at both call sites and on the constant. Option 3 (drop the
   app-level lock) would have conflicted with item 11's "keep both locks".
4. **No `retry transaction` anywhere.** The check script enforces it.
5. **Readiness.** HikariCP's "Connection is not available" error is a transient database error, so it
   already counts against the DB breaker. Once the threshold is reached the breaker opens and `/ready`
   answers 503 DOWN in both api and jobs. I proved it with an api unit test (`testPoolExhaustionFailsReady`),
   a jobs unit test (`poolExhaustionFailsReadiness`), and a jobs IT against a real pool of one connection
   held by `pg_sleep` (`realPoolExhaustionTripsTheBreaker`), which checks the real driver message too.
6. **V013 uses 30 s** (item 9 above).
7. **Concurrency IT.** `testGatedParallelWritesAllCommit` runs 5 rounds of 48 parallel PO adjustments
   through `scoring:adjustPoints -> PgLedgerRepository.append -> store:inTransactionValue`. It asserts that
   nothing fails, that committed rows equal reported successes (240), that no session is left
   `idle in transaction`, and that every write went through the gate.
   - **With the gate:** 5 of 5 local runs green (`240 successes, 240 committed, 0 failed, 0 idle in transaction`).
   - **Gate disabled locally once** (the lock removed from `inTransactionValue`, then restored): 2 of 3 runs red.
     - Run 1: `222 successes, 221 committed, 18 failed`. That's one lost commit (success reported, nothing
       committed), plus "The leaderboard is busy" and SQL errors.
     - Run 2: `239 successes, 239 committed, 1 failed`.
     - Run 3: green.

   The test does one sequential write first. Without it, the first parallel strands sometimes hit a separate
   CME in pure code (`types:adjustmentReference`, before any transaction starts) while the runtime is
   initializing. That one isn't SQL, and the gate doesn't cover it (see below).

## Observations for the owners

- **A second runtime race, outside SQL.** The first concurrent strands after start-up can throw
  `ConcurrentModificationException` from plain Ballerina code (seen in `scoring:adjustment` ->
  `types:adjustmentReference`). It looks like lazy runtime initialization; the round 1 concurrency test
  already warmed up for it. In production it would show as a rare 500 on the first burst after a deploy.
  It's worth checking against 2201.14.1 together with the R-13 upgrade.
- **The `amplify-database` runner still defaults `dbSslMode` to `REQUIRE`.** That was out of scope (item 2
  named api and jobs only). It runs once per release as the admin, so it should move to `VERIFY_FULL` too.
- **With a 2 s recognition-lock cap**, the gate-off run showed "The leaderboard is busy" under heavy
  in-process contention. With the gate on, contention only comes from other processes. Watch for that error
  in the M11 load test with several api replicas plus jobs.
- **The V013 `ALTER ROLE`** needs the bootstrap admin to hold ADMIN on the roles. It does on Aiven, because
  `avnadmin` created them in V001 (PostgreSQL 16+ grants the creator ADMIN).

## Doc claims the docs pass must update

- `architecture/security/token-and-oauth-notes.md`:
  - claim 2 (key rotation): re-seal on use plus the maintenance pass now exist, so an old key can leave the ring before its partitions drop;
  - claim 6 / §2 gaps (ID-token validation): now implemented, behind `linkedinIdTokenValidation`, default off; no nonce, no PKCE (native-client-only at LinkedIn);
  - §2 gap 3 / api H6 (redirect URI assertion): unchanged by this round, still pending the docs pass;
  - the issuer disagreement (common RC-13).
- `architecture/security/WSO2 Amplify Threat Model.docx`:
  - row 2.2 (ID token) and row 2.5;
  - AMP-R2 (key rotation);
  - row 4.6 wording (domain H-6, from round 1).
- `architecture/security/WSO2 Amplify Application Deployment Security Checklist.docx` lines ~100 and ~113: DB TLS goes from "Met w/ exception" to met once `BAL_CONFIG_VAR_DBSSLROOTCERT` is set per environment (the code default is `VERIFY_FULL`).
- `architecture/solution/Phase 1/phase1-data-model.md`:
  - "As built" should cover V011–V013;
  - the `idle_in_transaction_session_timeout` role setting;
  - the two new indexes;
  - the recognition lock order (4242101 then 1634561133);
  - the provider_token key-rotation pass;
  - the token row now commits with the connection change.
- ADR-025 / the jobs runbook: `POST /maintenance/partitions` also rotates token keys (`token_rotation` in the report); a share whose engagement already exists settles `PUBLISHED` (or `FAILED` `DUPLICATE_ENGAGEMENT`).
- ADR-028 / readiness docs: amplify-api `/ready` reports `linkedinIdTokenJwks` (not gating). Pool exhaustion trips the DB breaker and fails readiness.
- The R-13 write-up (`docs/reviews/2026-10-17-r13-transaction-race.md`):
  - the gate is in place (`store:inTransaction`, `scripts/check-transaction-gate.sh`);
  - `lockRecognition` waits 2 s;
  - V013 sets 30 s;
  - the remaining mitigation is the 2201.14.1 upgrade.
- Operations runbook: set `BAL_CONFIG_VAR_DBSSLROOTCERT` (Choreo file mount) per environment; consider alerting on sessions `idle in transaction` > 30 s.

## Final test-all

`scripts/test-all.sh` on the final commit, verbatim:

```text
== unit
  unit amplify-common                 155 passing  0 failing   0 skipped
  unit amplify-domain                  95 passing  0 failing   0 skipped
  unit amplify-api                     79 passing  0 failing   0 skipped
  unit amplify-jobs                    54 passing  0 failing   0 skipped
  unit amplify-database                20 passing  0 failing   0 skipped
  unit chat-stub                        2 passing  0 failing   0 skipped
== integration (postgres:18 on 55432)
  IT migrate runner                    16 passing  0 failing   0 skipped
  IT repositories + M5 flows           28 passing  0 failing   0 skipped
  IT the Run + DB down mid-run          5 passing  0 failing   0 skipped
== scheduler IT
  IT scheduler                          1 passing
  IT scheduler history retention        1 passing
== e2e (local Compose)
  e2e local Compose                     6 checks
== ALL GREEN: 462 passing across: unit it scheduler e2e
```

Checks:

```text
Descriptors in sync: 5 components.
check-logs-pii: 72 log call(s) scanned, 0 flagged
Transaction gate check self-test passed.
Transaction gate: all 19 transaction blocks run through store:inTransaction.
```

Second pass over the whole diff: one fix. `recordDuplicatePublish` could have matched another employee's
engagement through `activity_urn`, so it now matches only the same employee's engagement, and anything else
fails the share as `DUPLICATE_ENGAGEMENT`. The test-all above ran after that fix.
