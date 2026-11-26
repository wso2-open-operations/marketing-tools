# ADR-048: Automatic Coins conversion via the WSO2 Coins transaction service

Status: Proposed (2026-11-26)

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
