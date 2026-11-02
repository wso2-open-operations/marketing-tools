# ADR-029: Points ledger reference encoding (deterministic base64url, append-only ledger)

- **Status:** Accepted for phase 1 (encoding re-checked after phase 1 against wso2-coin)
- **Date:** 2026-10-17
- **Source:** audit C1

## Context

`scoring.points_ledger.reference` is a `varchar(66)` primary key and the phase 1 dedupe boundary (K4: automated duplicate prevention). The original design was `AMP-` + a hex sha256 of the award facts, which is **68 characters in a 66-character column** (C1). The reference must also be **deterministic**: a re-run of a score pass, or a second replica, must produce the same key so the insert can be `ON CONFLICT (reference) DO NOTHING` and never double-award (the anti-farming rule "once per action per post per person", R6/K4).

The wso2-coin reference rules that will govern the eventual payment reference are **not ready**, so this decision fixes the phase 1 encoding and is revisited after phase 1 (todo C1, plan M0c).

## Decision

The ledger is **append-only with a deterministic reference**:

1. **Awards** — `AMP-` + **unpadded base64url** (RFC 4648 §5) of `sha256(provider LF target LF employeeId LF action)`. The 32-byte digest is 43 base64url characters, so the reference is **47 characters** — it fits `varchar(66)` with 19 characters to spare. Re-running the pass yields the same key, so the award insert is `ON CONFLICT (reference) DO NOTHING`.
2. **Adjustments** (PO) — `ADJ-` + a UUIDv7. **Reversals** — `REV-` + a UUIDv7, with `reverses_reference` pointing at the row they cancel and `UNIQUE (reverses_reference)` (at most one reversal per row).
3. **Facts never change.** Only `status`, `status_changed_at`, `paid_at` and `coin_reference` are updatable, through column-level grants; `points`, `employee_id`, `reference` are physically immutable to app roles. A correction is a **new row**, never an update. The T4 award is a top-up row (`OWN_POST_AMPLIFIED` − `OWN_POST` points), not an update (C4).
4. The column stays `varchar(66)`. A unit test pins the 47-character award length and asserts it fits the column.
5. The encoding is revisited after phase 1 **against the wso2-coin reference rules**; the phase 1 column has headroom so a longer suffix can fit without a migration if the coin contract needs one.

## Rejected alternatives

- **Hex sha256** (`AMP-` + 64 hex = 68): the original defect — one character over the column. Widening the column pushes a change into the coin contract.
- **Numeric / serial reference**: not deterministic across re-runs or replicas, so no natural idempotency key and no `ON CONFLICT` dedupe.
- **Random UUID per award**: same problem — a redelivered event would double-award; would need a separate dedupe key beside the PK.
- **Hash over more fields** (commentary, timestamps): commentary is not part of the anti-farming key (once per post per person), and timestamps would break determinism.
- **A signed reference**: no verifier consumes the ledger outside Amplify in phase 1; signing adds key management for no benefit.

## Consequences

- 47 characters, URL/path-safe, deterministic across replicas and re-runs; the ledger PK is the dedupe boundary (K4).
- base64url is case-sensitive and uses `-`/`_` (already covered by the `AMP-[A-Za-z0-9_-]{43}` parse rule).
- If the wso2-coin contract requires a different encoding, the todo covers the re-check and the column headroom avoids a migration for a longer suffix.
- `amplify_common` ships the encoding (`AWARD_PREFIX`, `awardReference`, `newUuidV7`) and the length constants.

## Verified

- `amplify-common/modules/types/tests/ledger_test.bal` `awardReferenceIsDeterministicAnd47Chars` asserts `length() == 47` and `<= 66`.
- `amplify-database/migrations/V006__scoring.sql`: `reference varchar(66) PRIMARY KEY CHECK (reference ~ '^(AMP|ADJ|REV)-')`; `points_ledger_no_paid_phase1_ck` blocks `PAID` in phase 1.

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (C1, R6, R8, K4, Q5)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md) (ledger section: references)
- [ADR-005](ADR-005-data-model-conventions.md), [ADR-015](ADR-015-failed-share-retry-reuses-row.md), [ADR-017](ADR-017-one-claim-per-url.md)
- Code: `amplify-common/modules/types/ledger.bal`, `amplify-database/migrations/V006__scoring.sql`
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M2, M3, M0c C1)
