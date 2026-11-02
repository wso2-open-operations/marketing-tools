# R-13: parallel `transaction` blocks on Ballerina 2201.13.3

Follow-up to finding R-13 in [2026-10-26-code-review-backend.md](2026-10-26-code-review-backend.md). The reproduction, scripts and raw results are outside the repo, in `amplify-wt/r13-probe/` (`main.bal`, `run-variants.sh`, `results-2201.13.3.txt`, `results-2201.14.1.txt`).

## Status (2026-10-17)

Mitigated on 2201.13.3; the fix (the upgrade) is still open. Details in [round 2 item 12](2026-10-17-round2-handoffs.md#item-12-the-r-13-transaction-gate) and [ADR-032](../../architecture/decisions/ADR-032-transaction-gate-ballerina-2201-13.md).

**In place**

- **Gate.** `amplify_domain.store:inTransaction` / `inTransactionValue` (`amplify-domain/modules/store/tx_gate.bal`) lock one isolated variable. All **19** product `transaction` blocks run through it: 17 in amplify-domain, 2 in amplify-api (`auditTx`, `dashboardTx`); amplify-jobs has none of its own. (The "20" under Impact below was counted before round 2 merged `recordDenial` and `recordAudit` into `auditTx`.)
- **Check.** `scripts/check-transaction-gate.sh` (plus `--self-test`) runs in `make check`. It fails on a block outside a non-public `...Tx` function, a `...Tx` call that doesn't go through the gate, and any `retry transaction`.
- **`lockRecognition`** polls for at most **2 s** (`store:RECOGNITION_LOCK_WAIT_SECONDS`, was 10 s), because it now waits inside the gate.
- **V013** sets `idle_in_transaction_session_timeout = '30s'` on `amplify_api` and `amplify_jobs`.
- **Pool exhaustion fails readiness** in api and jobs: "Connection is not available" counts against the DB breaker, which opens and makes `/ready` answer 503 (api `testPoolExhaustionFailsReady`, jobs `poolExhaustionFailsReadiness`, jobs IT `realPoolExhaustionTripsTheBreaker`).
- **Alert** on sessions idle in transaction for more than 30 s: [operations.md](../runbooks/operations.md) §11.
- **Concurrency IT** `testGatedParallelWritesAllCommit` (5 rounds × 48 parallel PO adjustments through `store:inTransactionValue`):
  - gated: **5 of 5 green**, 240 of 240 committed, 0 failed, 0 idle in transaction;
  - gate removed locally: **2 of 3 red** (one run had 222 successes but 221 committed, so one lost commit, plus 18 failures; another had 1 failure).

**Open**

- **The upgrade to Ballerina 2201.14.1+** (JDK 25, base images and CI). Then rerun the suite and the probe and remove the gate (ADR-032 removal trigger).
- **A second start-up CME in plain Ballerina code** (`scoring:adjustment` → `types:adjustmentReference`, before any transaction starts) on the first concurrent strands after start. The gate doesn't cover it; the IT warms up with one sequential write to avoid it. In production it would show as a rare 500 on the first burst after a deploy. Re-check on 2201.14.1.
- The upstream asks below are still drafts, not filed.

## Verdict: confirmed platform bug

Concurrent `transaction` blocks race on an unsynchronized `java.util.HashMap`. It sits in the runtime singleton `io.ballerina.runtime.transactions.TransactionResourceManager` (`resourceRegistry`, plus the committed/aborted/trx/xid registries), and every transaction in the process shares it. The race happens before any SQL is sent. It causes three failures:

1. **`ConcurrentModificationException`.** `register()` throws while it adds the borrowed connection, and the caller gets a `sql:Error`.
2. **Success reported, nothing committed.** A concurrent write drops another transaction's registry entry. `notifyCommit()` then finds no resources, commits nothing, closes nothing, and still returns success. `check commit` passes, the rows never land, and the session stays `idle in transaction` holding its locks.
3. **Permanent pool leak.** `ballerina/sql` 1.19.0 borrows the connection and sets autoCommit to false *before* `register`, and never closes it if `register` throws. A lost commit never closes its connection either. In every run, leaked connections equalled CME errors plus lost commits.

The SQL, connector version, pool size and one-client-per-strand setting make no difference. Only the `transaction` statement triggers it.

## Measured failure rates (50 runs × 48 transactions per variant)

**2201.13.3, JDK 21**

| Variant | Pool | CME | Lost commits | Runs with a loss | Leaked connections |
|---|---|---|---|---|---|
| shared client | 12 | 7 | 4 | 4/50 | 11/12 |
| shared client | 2 | 1 | 0 (first pass 1) | 0 | 1/2 |
| shared client | 50 | 22 | 3 | 3/50 | 25/50 |
| client per strand | 12 | 6 | 8 | 8/50 | 0 (clients closed) |
| `retry(3) transaction` | 12 | 101 | 5 | 3/47 | 12/12, pool exhausted |
| one `lock` around the transaction, autocommit, explicit BEGIN/COMMIT on 1 connection, single CTE statement | — | 0 | 0 | 0 | 0 |

**2201.14.1, same connectors, JDK 25:** 0 CME, 0 lost commits and 0 leaks in every variant. A stress run of 16 strands × 200 runs (19,200 transactions) had none either.

Stack trace (`-Xlog:exceptions=info`):

```
ConcurrentModificationException thrown in java.util.HashMap.computeIfAbsent   (ForkJoinPool-1-worker-13)
 <- io.ballerina.runtime.transactions.TransactionResourceManager.register(...)
 <- io.ballerina.stdlib.sql.datasource.SQLDatasource.getConnection(...)
 <- io.ballerina.stdlib.sql.nativeimpl.ExecuteProcessor.nativeExecuteExecutable  (returned as sql:Error)
```

## Upstream

- [ballerina-lang #44737](https://github.com/ballerina-platform/ballerina-lang/issues/44737), "Concurrent transaction JDBC calls produce CME and Hikari pool checkout timeouts". It is open and marked Priority/Blocker, and the maintainer confirmed the unsynchronized `resourceRegistry` and the pool leak. *(Verified 2026-10-17.)*
- [ballerina-lang PR #44747](https://github.com/ballerina-platform/ballerina-lang/pull/44747), "Fix concurrent access to transaction resource registries". It merged to master on 2026-09-21 and changes `TransactionResourceManager.java`. *(Verified 2026-10-17.)* The probe confirmed the fix is in the 2201.14.0 / 2201.14.1 tagged source and missing from 2201.13.7, the latest 13.x. The 13.x backport (#44740) was closed without merging.
- [ballerina-lang #44742](https://github.com/ballerina-platform/ballerina-lang/issues/44742) / [PR #44743](https://github.com/ballerina-platform/ballerina-lang/pull/44743), still open: a separate register-vs-cleanup race against 2201.13.x.
- [ballerina-library #9129](https://github.com/ballerina-platform/ballerina-library/issues/9129): the same CME and leak in another WSO2 product. The workaround listed there is a `lock`.
- postgresql 1.19.1 and sql 1.19.0 are already the latest, so a connector upgrade won't help.

## Impact on Amplify

- There are 20 `transaction {}` blocks in product code, and none use `retry`. Concurrent amplify-api requests match the reproduction exactly.
- The API can return 200 while the ledger row, outbox event and audit row silently disappear. Orphaned sessions keep holding locks.
- amplify-api has a 10-connection pool. About 10 incidents leave every call failing with `Connection is not available` until a restart.
- amplify-jobs has a pool of 1. That narrows the window but doesn't close it.
- R-01's recognition lock prevents the hang. It doesn't prevent the lost write or the leak.

## Mitigation

1. **Fix: upgrade to Ballerina 2201.14.1+.** It needs JDK 25, so the base images and CI change too. The connector versions stay the same. After upgrading, rerun the full suite and the probe.
2. **Until then, on 2201.13.3: put one process-wide gate around every transaction.** The measured `lock` variant had 0 failures and 0 leaks. Separate `lock` statements don't exclude each other, so route all 20 call sites through one helper in `amplify_domain.store` that uses a single isolated variable as the lock. Transactions then run one at a time per process, which is fine for short phase 1 writes. Two cautions:
   - `lockRecognition` polls the advisory lock for up to 10 s and must not do that while it holds the gate. Shorten the poll or take the advisory lock outside the gate.
   - Don't add `retry transaction` on 13.x. It raised the CME rate about 15× and exhausted the pool.
3. **Keep after the upgrade too:**
   - Set `idle_in_transaction_session_timeout` per app role.
   - Alert on sessions that stay `idle in transaction` for more than 30 s.
   - Make repeated `Connection is not available` errors fail readiness so the pod restarts.

## Draft upstream asks (not filed)

- **ballerina-lang:** "[2201.13.x] Backport #44747: concurrent `transaction` blocks silently lose commits and leak pool connections". Ask for #44747 (and #44743) to be backported to 2201.13.x. Also ask that `notifyCommit` fail when a connection was used but no resources are registered, instead of returning success. Attach the minimal reproduction (48 concurrent `start insertRow(...)` per run, then compare reported successes to committed rows).
- **ballerina-library (comment on #9129):** "sql: `SQLDatasource.getConnection` leaks the borrowed connection when transaction registration throws". Close or roll back the connection and undo the local registration when `TransactionResourceManager.register` fails.
