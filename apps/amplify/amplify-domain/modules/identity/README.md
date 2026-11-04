# amplify_domain.identity

Employee records keyed by the IdP `sub`, aliases for re-created accounts, and the leaver and erasure helpers. Tables: `identity_employee`, `identity_employee_alias`.

## Types and ports

File: `modules/identity/types.bal`.

- `Employee` (`employeeId`, `email`, `displayName`, `firstSeenAt`, `lastSeenAt`), `ResolvedEmployee` (the id every other table keeps for the person), `TokenClaims`.
- `EmployeeRepository` port: `findById`, `upsert`, `findByEmail`, `findAlias`, `addAlias`.

## Service

File: `modules/identity/service.bal`.

- `resolveEmployee(repo, sub, email)` decides who a sign-in acts as: an existing alias, the `sub` itself, the employee that owns the email (a re-created account, ADR-041, which adds an alias), or a new person. Two records that both claim one email give `EMAIL_CONFLICT`.
- `recordSeen(existing, claims, now)` creates the employee on first sight and refreshes name, email and `lastSeenAt`. `firstSeenAt` never moves.

## Leavers and erasure

File: `modules/identity/leavers.bal` (ADR-040).

- `leaverCandidates(db, directoryEmails, graceDays, limit)` returns employees missing from the directory and not seen for the grace period, oldest first.
- `countEmployees(db)` is the base for the leaver percentage cap.
- `eraseEmployee(db, employeeId, actor, reason)` calls the SQL function `identity_erase_employee`, which audits the call and keeps the ledger. Needs a role allowed to execute it (`amplify_jobs`).

## Events

None. This context publishes no domain event.

## Repository and tables

File: `modules/identity/repository.bal`. `PgEmployeeRepository` (takes a `postgresql:Client`) implements the port over `identity_employee` and `identity_employee_alias`. It does not write the outbox.

## Config

None. `identity.bal` holds `MODULE` for log context.

## Depends on

`amplify_common.types`, `amplify_domain.store`.

## Does not do

- No org data (team, business unit). The people directory owns that.
- No access-token validation or role checks (`amplify-api` does that).

## Tests

`modules/identity/tests/identity_test.bal` uses an in-memory repository. Integration tests are in the package `tests/` directory (see the component README).
