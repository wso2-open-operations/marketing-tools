# ADR-048: Automatic Coins conversion via the WSO2 Coins transaction service

Status: Proposed (2026-11-26); amended 2026-11-26 (pre-coin verification, below)

## Context

Phase 2 turns Amplify points into WSO2 Coins. The settings exist since S012 (`coin.block_points = 100`,
`coin.block_coins = 10`, `coin.schedule = MONTHLY`, `coin.wallets_enabled = false`) and the ledger has had the
settlement columns (`status`, `paid_at`, `coin_reference`) since V006, with PAID blocked by a phase 1 check.

The WSO2 Coins transaction service (wso2-coin `operations/transaction-service`) is the ledger for Coins. What it offers
a calling application, from its code:

- `POST /wallets/master/transfer {toAddress, amount}` moves Coins from the master wallet mapped to the caller's client id
  (`client_master_wallet`). It answers 201 with a reference the service generates; it takes **no caller reference**, so
  a repeated call is a second transfer.
- `GET /wallets/master/balance`, `GET /transactions/{reference}` and `POST /transactions/search` (from and to wallets,
  date range, paged).
- `GET /wallets/me` lists the signed-in user's wallets (address, balance, default flag). It needs the service token and
  the user's own token in `X-User-Assertion`; the Swag Store forwards its caller's Choreo `x-jwt-assertion` the same
  way. `GET /wallets` has no email, so it can't map employees to wallets.
- Service calls authenticate with a client-credentials token through the Choreo gateway.

## Decision

1. **Automatic, once a period.** No approval step. The scheduler calls amplify-jobs `POST /coins/convert` on
   `coin.schedule` (MONTHLY: the 1st, 02:00 UTC; WEEKLY: Mondays; DAILY), only while `coin.wallets_enabled` is true.
   Points keep counting while it is off.
2. **Whole blocks, carry, caps.** Per employee: eligible = the carry of their last paid conversion + their HELD ledger
   points no conversion has taken (reversals count negative). Coins = floor(eligible / `coin.block_points`) ×
   `coin.block_coins`, within `coin.max_coins_per_person` (one run) and `coin.max_coins_per_run` (the period, everyone,
   oldest waiting first); everything else carries over. Only HELD rows convert: a row flagged action required
   (status NULL) does not, which is the seam for the pre-coin verification that comes later.
3. **Wallet capture with the user's own token.** `POST /me/coins/wallet` (amplify-api) calls `GET /wallets/me` with
   Amplify's service token and the caller's backend JWT as `X-User-Assertion` (as the Swag Store does), takes the
   default wallet (else the first) and stores it in `scoring_coin_wallet`. The conversion only pays captured wallets;
   others are `SKIPPED_NO_WALLET` and keep their points. Erasure deletes the captured wallet.
4. **Three steps per employee, money outside the transaction.** (1) One transaction writes the issue
   (`scoring_coin_issue`) PENDING with our own `CNV-` reference and sets that reference on exactly the ledger rows it
   takes. (2) The transfer, outside any transaction. (3) One transaction marks the rows PAID (final from then on: the
   V021 guard refuses any change to a PAID row) and the issue SENT with the service's transfer reference.
5. **Retry safety without a caller reference.** A definite refusal (4xx, nothing reached the service) marks the issue
   FAILED and gives the rows back; they convert in a later run. No clear answer (timeout, 5xx, an unreadable 201)
   marks it UNKNOWN, keeps the rows tagged so nothing can take them twice, and stops the run. Before anything is sent
   again, the next run (at least 10 minutes later) reconciles every open issue with `POST /transactions/search`:
   master wallet → that wallet, from the attempt on, the same amount, a transfer reference no other issue holds. One
   match is SENT, none is FAILED, more than one stays UNKNOWN (`RECONCILE_AMBIGUOUS`) for an operator. An issue left
   PENDING (a crash between steps) is reconciled the same way.
6. **No partial sends.** The run checks the master balance against the whole run before the first transfer and stops
   (`INSUFFICIENT_BALANCE`) when it can't cover it. Re-running a period sends nothing for its SENT issues.

## Consequences

- New tables (V026): `scoring_coin_wallet`, `scoring_coin_run`, `scoring_coin_issue`; PAID allowed on the ledger and
  final. Seed S014 adds the two caps (admin settings). The scoring context owns all of it (ADR-005, ADR-043).
- New egress from amplify-api and amplify-jobs to the Coins service (config `COINS*`, secret as a secret).
- `GET /me/points` shows Coins received, the carry and the captured wallet (masked).
- Reconciling depends on Amplify's master wallet being Amplify's alone: a transfer from it by anyone else to the same
  wallet, for the same amount, in the window, could be taken for Amplify's. Ambiguity is never guessed.

## Open asks to the Coins team

1. **A caller reference on `POST /wallets/master/transfer`** (an idempotency key, as `POST /payments` has), so a retry
   can be replayed instead of reconciled. With it, step 5 becomes a plain retry with the issue's `CNV-` reference.
2. **An Amplify client application** subscribed to the Coins API, mapped to a **funded master wallet** used by Amplify
   only.
3. **Amplify's backend JWT accepted as the user assertion** on `GET /wallets/me` (issuer and audience of the Choreo
   gateway in front of Amplify), as for the Swag Store.

## Rejected alternatives

- **Approval step per conversion:** S012 already fixed the conversion as automatic; the PO team changes the rate.
- **Mapping employees to wallets with `GET /wallets`:** it carries no email.
- **Retrying a timed-out transfer at once:** without a caller reference it can pay twice.

## Amendment 2026-11-26: verify engagement before Coins are issued (Task #1767, V027, S015)

Points from LinkedIn activity can outlive the activity: an employee can delete a repost, a reaction or a comment after
it was scored. Before Coins are paid, the activity behind every engagement row the conversion could take is checked
again.

1. **A separate scheduler job, an hour before the conversion.** `amplify-coins-verify` calls amplify-jobs
   `POST /coins/verify` at 01:00 UTC on the conversion day (`coin.schedule`: the 1st, Mondays or daily), only while
   `coin.wallets_enabled` is true. Chosen over the conversion calling verification first: the LinkedIn calls (budgets,
   429s, an outage) never eat the conversion's time limit or block it, and the conversion stays one thing. Both take
   the Coins advisory lock (`COINS_LOCK_KEY`) on their own connections, so a verification never reverses a row under a
   conversion that already planned it.
2. **The conversion takes only recently verified engagement rows.** An ENGAGEMENT row converts while its LinkedIn
   activity was seen within `coin.verify_max_age_hours` (default 48, at least 2), or after a PO cleared it. Own posts
   (EXTERNAL_SHARE: a PO approved the evidence), adjustments and reversals are never checked. A reversed row converts
   with its reversal (they net to zero); a reversal waits while the row it reverses is action required. A row no run
   reached is simply left for the next conversion.
3. **Outcomes** (ledger columns `verification`, `verified_at`, `verification_reason`; the V021/V026 guard allows them):
   still there → `VERIFIED`; gone (404/410) → `REMOVED`, and the system appends the reversal with the reason "No longer
   on LinkedIn" in the same transaction (recognition updates, B12); can't be checked → `UNVERIFIABLE` with a reason
   (`NO_TOKEN`, `TOKEN_EXPIRED`, `NOT_PERMITTED`, `NO_ACTIVITY`, `SOURCE_NOT_FOUND`, `MEMBER_ERASED`) and the row
   becomes action required (status NULL). The PO clears it on Points & corrections (`POST /po/points/{reference}/settlement`
   `HELD`, recorded as `PO_CLEARED`, never re-checked) or reverses it; `GET /po/points/action-required` lists them.
   A row verified more than half the max age ago is checked again.
4. **Which read.** An in-app share or a native reshare: `GET /rest/posts/{urn}` with the employee's own Share on
   LinkedIn token, else (no usable token, or 401/403) with the page token. A reaction: `GET /rest/reactions/(actor,entity)`
   with the page token. A comment: `GET /rest/socialActions/{post}/comments/{id}` with the page token. A 429 or LinkedIn
   being down stops the run without recording anything for the row.
5. **Budgets.** Page-token reads count against `engagement.daily_call_budget` with the engagement sync; member-token
   reads against `coin.verify_member_daily_call_budget` (default 1000), both in `sharing_api_usage` per UTC day. A spent
   budget stops the run (`BUDGET_REACHED`); a manual re-run later carries on with what is still due.
6. **Contexts (ADR-005).** Scoring owns the ledger side (`verifyForCoins`, `PgVerificationRepository`) and never reads
   sharing tables. The check is a port (`EngagementChecker`) that amplify-jobs builds from sharing (the engagement, the
   record of each answer in `sharing_engagement_verification` / `last_verified_at` / `deleted_at`, the budgets),
   connection (the tokens) and LinkedIn, like the engagement sync.

Consequence: until the page connection or an employee's own connection can read a member's post (LinkedIn may answer
403 for both), such rows land with the PO team as `NOT_PERMITTED`, which is the designed fallback, not an outage.
