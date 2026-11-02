# Runbook: Employee Data-Deletion Request (interim, phase 1 pilot)

Status: Draft (2026-10-16). Valid while the checklist exception is open.
Owner: Amplify technical owner. Backup: a second Amplify engineer with prod DB access.
Why it's manual: [ADR-016](../../architecture/decisions/ADR-016-erasure-deferred.md).

## When to use this

An employee (or Legal / Privacy on their behalf) asks WSO2 to delete or anonymize their Amplify data. Requests can arrive through the privacy channel, PO, IT support or directly. **Whoever receives it forwards it to the owner the same day.**

If the employee only wants Amplify to stop posting for them, point them to **Me › Settings › My Connections › Remove Connection** first. That deletes the LinkedIn token immediately and needs no ticket.

## Timeline

| Step | Target |
| --- | --- |
| Acknowledge the request | 2 working days |
| Complete the change | 15 working days, and always inside the legal deadline Legal gives (typically one month) |
| Confirm to the requester | Same day as completion |

Legal / Privacy confirms these targets before go-live.

## Steps

1. **Log it.** Open a private ticket (security/privacy tracker) with the request date, requester, the employee's email, and who verified identity. Never put the employee's data in a public channel.
2. **Verify identity.** The request must come from the employee's own WSO2 account, or from Legal / Privacy. Find the Asgardeo `sub`:
   ```sql
   SELECT employee_id, email, display_name, first_seen_at, last_seen_at
   FROM identity.employee WHERE email = $email;
   ```
3. **Ask Legal / Privacy what to keep.** Default for the pilot: delete the LinkedIn link and token, remove name and email everywhere, keep ledger and audit rows keyed only by the pseudonymous `sub`. Record their answer in the ticket.
4. **Prepare the call** (below). A second engineer reviews it. Run it in **non-prod first** against a test user.
5. **Back up** the affected rows to an encrypted file in the restricted project store, kept only until the change is confirmed (max 7 days), then delete it. Note the deletion in the ticket.
6. **Run in prod** as `amplify_migrate` (the only user allowed to change these columns), inside one transaction, with the second engineer watching.
7. **Check the result** (queries at the end), then confirm to the requester and close the ticket.
8. **Tell the requester** to also remove the "WSO2 Amplify" app in LinkedIn › Settings › Data privacy › Permitted services. Amplify can't do that from our side.

## The erase function

Run as `amplify_migrate` (the schema owner). The work is one function, `identity.erase_employee`, added in V018 and
covered by an integration test, so the manual runbook and the worker's leaver sweep erase exactly the same things.
Replace `:sub` with the employee's `employee_id`, `:operator_sub` with your own, `:ticket_id` with the ticket.

```sql
SELECT identity.erase_employee(:'sub', :'operator_sub', :'ticket_id');
```

It runs in one transaction, can be repeated safely (a second call reports zeros), and writes the audit row itself
(`EMPLOYEE_DATA_ERASED`, with the counts and the ticket id). It returns what it changed, for example
`{"tokens": 1, "connections": 1, "oauthStates": 0, "consents": 1, "idempotencyKeys": 3, "commentary": 2,
"engagements": 4, "employee": 1, "standings": 2}`. Put that in the ticket.

What it does:

- **Deletes** the LinkedIn connection row (the member URN lives there), its token rows, any OAuth state in flight,
  the consent record (with the profile URL the person typed) and the person's idempotency keys.
- **Clears** repost commentary and replaces the member URN stored on each engagement with `urn:li:person:erased`.
- **Replaces** name and email on `identity.employee` with `Former participant` and a unique placeholder address
  (`erased-<hash>@amplify.invalid`; the column is `NOT NULL UNIQUE`, so it cannot be set to NULL) and on
  `recognition.standing` with `Former participant` and no email.

It does **not** remove the LinkedIn member URN from the append-only audit log or from outbox rows (payload and idempotency key) until retention purges them, and the tokens are deleted but not revoked at LinkedIn. If the person is reachable, ask them to use Remove Connection first (it revokes) and to remove the app in LinkedIn settings (step 8). Legal / Privacy should confirm the retained URN is acceptable. The audit row records the database user that called the function next to the actor you name.

The earlier hand-written template tried `email = NULL`, which the schema refuses, and left the member URN behind.

## Gotchas

- **If the person is still an employee and opens Amplify again**, `amplify-api` upserts their email and name on the next call. Remove them from the Amplify pilot group in Asgardeo, or agree with them that their next use re-creates a profile.
- **Recognition rebuild** (`POST /maintenance/rebuild-recognition`) reads names from `identity.employee`, so it keeps the anonymized values. Run it only after step 3.
- **Backups** still hold the old data until backup retention ends. Say so in the confirmation.

## Checks after the change

```sql
SELECT count(*) FROM connection.provider_token WHERE owner_id = :'sub';                  -- 0
SELECT count(*) FROM connection.member_connection WHERE employee_id = :'sub';            -- 0
SELECT email, display_name FROM identity.employee WHERE employee_id = :'sub';            -- erased-...@amplify.invalid, Former participant
SELECT count(*) FROM recognition.standing WHERE employee_id = :'sub' AND email IS NOT NULL;  -- 0
SELECT action, at, after FROM audit.audit_log WHERE entity_id = :'sub' ORDER BY at DESC LIMIT 1;  -- EMPLOYEE_DATA_ERASED
```
