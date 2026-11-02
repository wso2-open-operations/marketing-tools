# ADR-032: Process-wide transaction gate on Ballerina 2201.13.x (R-13)

- **Status:** Accepted (interim, remove after the Ballerina upgrade)
- **Date:** 2026-10-17
- **Source:** deep review finding R-13 ([amplify-domain review](../../docs/reviews/2026-10-26-code-review-backend.md)), [R-13 write-up](../../docs/reviews/2026-10-17-r13-transaction-race.md), [round 2 item 12](../../docs/reviews/2026-10-17-round2-handoffs.md)
- **Related:** ADR-001 (Ballerina), ADR-028 (DB breaker, readiness)

## Context

On Ballerina 2201.13.3, concurrent `transaction {}` blocks race on an unsynchronized `HashMap` in the runtime singleton `TransactionResourceManager` ([ballerina-lang #44737](https://github.com/ballerina-platform/ballerina-lang/issues/44737)). The race happens before any SQL is sent and has three outcomes: a `ConcurrentModificationException` returned as a `sql:Error`, a commit reported as successful that never happened (the session stays `idle in transaction` holding its locks), and a pool connection leaked for good. The probe measured it at every pool size and with one client per strand; only the `transaction` statement triggers it, and `retry transaction` made it about 15 times worse.

The fix ([PR #44747](https://github.com/ballerina-platform/ballerina-lang/pull/44747)) is in 2201.14.0+ only; the 13.x backport was closed. 2201.14.x needs JDK 25, so upgrading means new base images and CI as well as a full regression run. Amplify had 19 product `transaction` blocks (17 in amplify-domain, 2 in amplify-api) and concurrent api requests match the reproduction exactly: a 200 whose ledger row, outbox event and audit row never landed, and about 10 incidents to exhaust the api's 10-connection pool.

## Decision

1. **One gate per process.** `amplify_domain.store` has `inTransaction(isolated function () returns error?)` and `inTransactionValue(isolated function () returns anydata|error)` (`modules/store/tx_gate.bal`). Both `lock` the same isolated variable, so every transaction in the process runs one at a time. Separate `lock` statements on different variables don't exclude each other, which is why it's one helper and not a `lock` per call site.
2. **Every product transaction goes through it.** Each `transaction` block sits in a non-public `...Tx` function, and the public method passes `cloneReadOnly()` copies into the closure (inside the gate a `...Tx` body that needs a mutable copy uses `cloneWithType`, because `clone()` of a read-only value stays read-only).
3. **Enforced in the build.** `scripts/check-transaction-gate.sh` (with `--self-test`, both in `make check`) fails on a `transaction` block outside a non-public `...Tx` function, on a `...Tx` call on a line that doesn't call the gate, and on any `retry transaction`.
4. **Nothing slow inside the gate.** `lockRecognition` polls the recognition advisory lock for at most 2 s (was 10 s); inside one process the gate already serializes recognition writers, so the advisory lock only arbitrates between processes.
5. **Backstops kept after the upgrade too:** V013 sets `idle_in_transaction_session_timeout = '30s'` on `amplify_api` and `amplify_jobs`, so a lost commit releases its locks; pool exhaustion counts against the DB breaker and fails `/ready` (ADR-028 amendment); the operations runbook alerts on sessions idle in transaction for more than 30 s.

## Consequences

- **Writes are serialized per process.** Phase 1 transactions are short (milliseconds), so throughput at pilot volume is fine, but one slow transaction delays every other write in that replica. Several replicas still run in parallel with each other; cross-process ordering stays with PostgreSQL row locks and the advisory locks.
- With the gate on, the concurrency IT (`testGatedParallelWritesAllCommit`, 5 rounds of 48 parallel PO adjustments) was green 5 of 5 times: 240 successes, 240 committed, 0 idle in transaction. With the gate removed locally, 2 of 3 runs failed, including one lost commit.
- Under heavy in-process contention the 2 s recognition wait can answer "The leaderboard is busy; retry". With the gate on, that contention only comes from other processes; watch for it in the M11 load test with several api replicas plus jobs.
- **Not covered:** a separate start-up `ConcurrentModificationException` in plain Ballerina code (seen in `types:adjustmentReference` on the first concurrent burst after start). It isn't a transaction, so the gate can't help; it would show as a rare 500 on the first burst after a deploy. Re-check it on 2201.14.1.

## Removal trigger

Upgrade to **Ballerina 2201.14.1 or later** (needs **JDK 25**: base images, CI and the Dockerfiles change; connector versions stay). Then rerun the full suite and the R-13 probe, inline the `work` bodies again, delete `tx_gate.bal` and `scripts/check-transaction-gate.sh`, drop the check from `make check`, and mark this ADR superseded. Keep the item 5 backstops.

## Alternatives considered

- **Upgrade to 2201.14.1 now.** The real fix, measured at 0 failures over 19,200 transactions. Rejected for phase 1 timing: it moves the JDK (21 → 25) and every base image close to the pilot (go-live date still open with the PO), and needs a full regression and a check that the Choreo build path supports JDK 25. It's the planned exit.
- **Single-statement refactor** (no `transaction` blocks: one CTE statement, or autocommit with explicit `BEGIN`/`COMMIT` on one connection). Measured clean, but it rewrites all 19 units of work (aggregate + outbox + audit, ledger + recognition) and loses the readable transaction boundaries the domain relies on, for a problem that goes away with the upgrade.
- **`retry transaction`.** Rejected: on 13.x it raised the CME rate about 15 times and exhausted the pool.
- **Do nothing and rely on the idle timeout and readiness.** Rejected: those limit the damage (locks released, pod restarted) but don't stop a 200 that lost its write.

## Amendment 2026-11-01: phase 1 stays on 2201.13.3 (Scott's decision)

**Decision.** Ballerina stays on **2201.13.3** for phase 1. The gate in this ADR stays in the code. The upgrade to 2201.14.1 or later is still the planned exit, after the pilot decision, not before.

**Why the upgrade is still needed.** The gate is one process-wide lock held across database I/O. A slow dashboard read or a recognition rebuild that runs inside a gated transaction stalls every other write in that replica until it finishes, and nothing in 13.x can make the lock narrower, because the race it hides is inside the runtime. The fix in 2201.14.1 removes the race itself: measured at 0 failures over 19,200 transactions, so the gate, the `...Tx` split and `scripts/check-transaction-gate.sh` can all go.

**Why not now.** 2201.14.x needs JDK 25. Moving to it changes every base image, the CI jobs and each Dockerfile (api, jobs and database) close to the pilot, and the go-live date is still open with the PO. A regression run on a new JDK that late is a worse risk than a serialized write path whose transactions take milliseconds at pilot volume.

**What limits the damage meanwhile.**

- V013: `idle_in_transaction_session_timeout = '30s'` on `amplify_api` and `amplify_jobs`, so a lost commit releases its locks.
- `/ready` goes DOWN when the database breaker opens or the pool is exhausted (ADR-028), so a stuck replica is restarted.
- The runbook alert on sessions idle in transaction for more than 30 s (`operations.md`).
- `make check`, which fails the build on a transaction outside the gate, a gate call that bypasses `...Tx`, and any `retry transaction`.
- The recognition advisory lock waits at most 2 s, so a busy leaderboard answers "busy, retry" instead of queueing behind the gate.

**Open check (unverified).** Does Choreo accept a JDK 25 runtime image for a Docker component? Nobody has built or deployed one there yet. Until that is answered, the upgrade cannot be scheduled, so it is the first thing to try once the pilot date is known.

The Removal trigger above is unchanged.
