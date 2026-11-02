# ADR-040: One audited erase function, a leaver sweep, narrower token grants, outbox alerting

- **Status:** Accepted
- **Date:** 2026-10-30
- **Source:** Security review (privacy, lifecycle, least privilege, resilience); supersedes the manual-only part of ADR-016

## Decision

1. **`identity.erase_employee(employee_id, actor, reason)` (V018)** is the only way personal data is erased. It deletes the LinkedIn
   connection (member URN), tokens, OAuth state, consent record with the profile URL, and idempotency keys; clears repost commentary
   and the member URN on engagements; replaces name and email with `Former participant` and a unique `erased-<hash>@amplify.invalid`
   (the column is `NOT NULL UNIQUE`, which broke the old runbook template). The points ledger, engagements, external shares, audit rows and
   monthly totals stay, keyed only by the pseudonymous id. It writes its own audit row and is safe to repeat. Only `amplify_jobs` may
   execute it.
2. **Leaver sweep in amplify-jobs**, part of the daily maintenance run, off by default (`leaverSweepMode`: `OFF`, `DRY_RUN`, `ERASE`).
   A person is a leaver when they are **missing from the people directory and have not used Amplify for `leaverGraceDays` (30)**.
   Two limits stop a broken directory from erasing active people: a directory that lists fewer than `leaverMinDirectorySize` (100)
   people skips the sweep, and more than `leaverMaxPerRun` (10) leavers, or leavers over `leaverMaxPercent` (10%) of the employees Amplify knows, erases nobody and logs an error (the percentage scales with the pilot; the absolute cap alone would let a partial directory erase a few active people while Amplify is small). Identity is matched by the sign-in email against the directory work email, so anyone who signs in with a different address looks like a leaver: that is why `DRY_RUN` comes first. Roll out `DRY_RUN` first.
3. **Token grants (V017):** `amplify_api` loses `UPDATE` and `amplify_jobs` loses `INSERT` on `connection.provider_token`. Both keep
   `SELECT` (the API revokes at LinkedIn when a person removes their connection). Moving that revoke into the worker would remove the API's
   read access too; that is a separate change because it alters the 503-on-revoke-failure behaviour.
4. **Outbox alerting:** gauges `amplify_outbox_pending`, `amplify_outbox_failed`, `amplify_outbox_oldest_pending_seconds`, an `outbox`
   block on jobs' `GET /ready`, and a warning log. Alert on an oldest pending row older than `outboxAlertSeconds` (1 hour) or any failed row.

5. **Token partition runway:** two weeks ahead (V009), created at amplify-jobs start-up as well as in the daily run, with
   `amplify_token_partition_days_ahead` and a `/ready` block; alert below 3 days. No DEFAULT partition: it would stop the
   day-based drop of expired token days from working cleanly.

## Not decided here

- Whether two POs may adjust each other's points without a second approval (a business rule; the self-review rule stays).
- Retention windows for tokens and keys, member URN retention after removal, the DPIA, and the LinkedIn terms question: owner and Legal items.

## Links

- Runbook: `docs/runbooks/data-deletion-interim.md`, `docs/runbooks/operations.md` (outbox alerts)
- Code: `amplify-database/migrations/V017*`, `V018*`, `amplify-domain/modules/identity/leavers.bal`, `amplify-jobs/leavers.bal`, `amplify-jobs/backlog.bal`
