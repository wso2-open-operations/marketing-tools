# ADR-041: A re-created Asgardeo account is an alias of the person's first employee id

- **Status:** Accepted (recommended default, 2026-11-01; Scott approved re-keying by email, the mechanism is open for his answer on the fleet board)
- **Date:** 2026-11-01
- **Source:** upstream review of marketing-tools PR 233 (`identity/repository.bal`: a re-created account 409s forever)
- **Related:** ADR-005 (no cross-context FKs), ADR-009 (employee from token claims), ADR-016/ADR-040 (erasure keeps the pseudonymous id), ADR-029 (ledger references carry the employee id)

## Context

`identity.employee.email` is unique. A person whose Asgardeo account is deleted and re-created signs in with a new `sub` and the same email, the insert hit the unique key, and every call answered 409 `EMAIL_CONFLICT` with no way out.

The obvious fix is to re-key the employee row to the new `sub`. The employee id is not only on that row. It is the key of `scoring.points_ledger` (and inside its `reference` strings, ADR-029), `recognition.standing` and the monthly totals, `connection.*`, `sharing.*`, `external_sharing.external_share`, `messaging.idempotency_key` and `audit.audit_log`, with no foreign keys between contexts (ADR-005). Rewriting all of that in one transaction means editing an append-only ledger and an audit trail, rewriting idempotency references, and merging standing rows when the new `sub` already acted. Not rewriting it leaves the person's points and connection behind under an id nobody signs in with.

## Decision

1. **The first employee id is the person's id for good.** A new `sub` whose email belongs to an existing employee becomes an **alias** of that employee: `identity.employee_alias (alias_sub PK, employee_id, created_at)` (V020). Nothing in any other table is rewritten.
2. **Resolved once per request, in the interceptor, after the token verifies.** `identity:resolveEmployee` gives the id to act as, and `amplify-api` puts it in the principal, so every route, the ledger and the audit log see the first id. The result is memoized per `sub` for `identityCacheSeconds` (300 s, memory only); a clash is never memoized.
3. **Rules.** Alias exists: its employee (unless the token's email now belongs to a different employee). `sub` has its own row: itself (same exception). `sub` is new and the email belongs to an employee: create the alias, once, with an `EMPLOYEE_ALIASED` audit row (ids only, no email). Otherwise: itself.
4. **A genuine clash is `EMAIL_CONFLICT`** (typed, domain code `ERR_EMAIL_CONFLICT`, 409): two employee records that both claim one email are two people as far as Amplify can tell, and nothing is merged by guessing. The body is generic ("This sign-in can't be matched to an Amplify profile, contact the Amplify admins") and says nothing about the other record, which closes the account-enumeration oracle the architecture review found in the old message.

## Consequences

- History stays correct without a migration of data: points, shares, connections and audit rows keep one key.
- Every authenticated route now does an identity lookup on a cold `sub` (one or two indexed reads), and a database outage answers 503 where an unauthenticated-by-DB path used to pass. All business routes need the database anyway.
- `identity.employee.email` still updates to the latest token email through `/me`; if that email now belongs to someone else the unique key answers the same generic `EMAIL_CONFLICT`.
- The alias holds two opaque ids. `identity.erase_employee` (V018) does not delete alias rows; they identify no one without the employee row. Revisit if Privacy disagrees.
- The first `sub` stays valid: if both accounts sign in, both act as one person.

## Alternatives considered

- **Rewrite the id everywhere in one gated transaction** (a `SECURITY DEFINER` function like `erase_employee`). Cleaner afterwards, but it edits ledger rows and idempotency references, needs a merge rule for a new `sub` that already acted, and is hard to undo. Open for Scott on the fleet board if he prefers it.
- **Re-key only `identity.employee`.** Leaves the person's history under the old id: they would restart at 0 and the old standing row would keep their email.
- **An admin repair runbook.** Second best, and every re-created account is a support ticket.
