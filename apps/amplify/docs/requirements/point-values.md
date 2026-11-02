# Point values proposal (D6)

- **Status:** **Decided 2026-10-19** (pilot points table from the business; see "Decided values" below). The original proposal follows for history.
- **Date:** 2026-10-16, decided 2026-10-19
- **Owner:** Lead Developer
- **Decides:** the `scoring.point_rule` seed for phase 1 (plan M3 seed scripts, D6)
- **Scope:** points only. Coins and any Coin conversion rate are phase 2 and not part of this proposal.

## Decided values (pilot, 2026-10-19)

From the business:

| Action | Points |
|---|---|
| Like or comment on an Amplify post on LinkedIn | 1 |
| Repost with no added text | 2 |
| Share with your own commentary | 5 |
| Original WSO2 post (own work, event, culture) | 10 |
| Original post featured by official WSO2 channels or an SLT member | +15 bonus |
| Amplify Challenge entry | 10 |
| Amplify Challenge winner | 25 |

How they land in the system (seed `S005__point_rules_pilot.sql`, effective 2026-10-19 00:00 UTC; S001's values stay for anything awarded before then):

| Business row | `point_rule.action` | Points |
|---|---|---|
| Repost with no added text | `SHARE`: the Amplify button posts it for the employee (**phase 1**). `REPOST`: a native LinkedIn repost, tracked from LinkedIn (**phase 4**) | 2 |
| Share with your own commentary | `REPOST_COMMENTARY`: a native repost with the employee's thoughts, tracked from LinkedIn (**phase 4**). `SHARE_COMMENTARY` gets no pilot version: no phase uses it, since LinkedIn's API can't post the employee's own words for them | 5 |
| Original WSO2 post | `OWN_POST` (**phase 3**, employee submissions) | 10 |
| Featured by WSO2 channels or an SLT member | `OWN_POST_AMPLIFIED` = **25 total** (10 + 15). The ledger adds a 15-point top-up row on the existing `OWN_POST` award (C4) | +15 |
| Like or comment | none yet. Reactions and comments are tracked in **phase 4** (2026-10-19 breakdown); needs new actions and a rule then | (1) |
| Amplify Challenge entry / winner | none yet. Award them as **PO points adjustments** with a reason ("Amplify Challenge entry" / "winner"), audited like any adjustment, until challenges are modelled | (10 / 25) |

Two notes on the pilot table. "SLT member" answers the open question below on "senior leader". And own posts (and so the bonus) arrive through employee submissions, which the 2026-10-19 breakdown puts in phase 3, so in phase 1 only the repost and share rows can actually be earned.

## Proposed values (2026-10-16, superseded)

The action is the tier: the more effort and reach behind the action, the more it's worth.

| Action (`point_rule.action`) | What the employee did | Proposed points | Range for PO to pick from |
|---|---|---|---|
| `REPOST` | Reposted a campaign post as-is from Amplify | **5** | 5 (fixed) |
| `REPOST_COMMENTARY` | Reposted with their own thoughts added | **12** | 10–15 |
| `OWN_POST` | Their own post or other promotion, submitted through My Campaign and approved by the PO | **20** | 20–25 |
| `OWN_POST_AMPLIFIED` | An own post that WSO2 or a senior leader then amplified | **40** total | 35–50 |

How `OWN_POST_AMPLIFIED` lands in the ledger: the employee already has the `OWN_POST` row, so the amplified award is a **top-up row** worth `OWN_POST_AMPLIFIED − OWN_POST` (20 with the numbers above). It never updates the earlier row.

## Why these numbers

- **Repost at 5** is the baseline. One click from Amplify, so it's worth the least.
- **Repost with thoughts at 12** is more than double a plain repost. Adding a sentence in your own words gets much better reach on LinkedIn than a bare repost, and it's the behaviour we most want to grow.
- **Own post at 20** pays for writing something original, and it goes through PO review.
- **Amplified at 40** rewards posts good enough that WSO2 or a senior leader picks them up. Keeping it at 2× own post makes the top tier clearly worth aiming for.
- Small whole numbers keep the leaderboard easy to read.

## Rules that stay the same whatever the numbers

- Once per post per person per action (ledger reference plus the `engagement` unique key).
- Points are `HELD` in phase 1. Comments and reactions don't score in phase 1 (B5).
- A change to a value is a new `point_rule` row with a later `effective_from`. Points already earned are never recalculated.
- See [ADR-018](../../architecture/decisions/ADR-018-share-verification-and-metrics-need-community-management.md): phase 1 can't check whether a share was later deleted, so the PO may need to reverse by hand on the Team page.

## Questions for the PO

1. Pick a value for each row (or accept the bold defaults).
2. Is "senior leader" a named list (who maintains it?) or a job grade from HR data?
3. Should a Marketing-registered company campaign and an employee's own My Campaign post score the same `OWN_POST` value? (Ties to the open M0b question on company campaigns vs. individual posts.)
4. Seed note: the plan's seed list also names `SHARE` and `SHARE_COMMENTARY`. They only matter if the reshare prototype shows a member can't repost an organization post (domains open question 1) and Amplify falls back to a new post that links to it. If that happens, we'd suggest the same values as `REPOST` / `REPOST_COMMENTARY`. Otherwise drop them from the seed.

## Where every value lives (2026-10-22)

All ten values of the pilot table are seeded, so none waits on its phase to be remembered. They stay in the database as effective-dated `scoring.point_rule` rows (S005 and S006, effective 2026-10-19); PO changes one with a new row through the point-rules API. They are deliberately **not** env or Choreo configuration: a config value has no effective date, so past awards could not keep the value they earned.

| Table row | Action | Points | Seed | Awarded today by |
| --- | --- | --- | --- | --- |
| Repost with no added text | `REPOST`, `SHARE` | 2 | S005 | Amplify (phase 1) |
| Share with your own commentary | `REPOST_COMMENTARY`, `SHARE_COMMENTARY` | 5 | S005, S006 (`SHARE_COMMENTARY`) | Amplify (phase 1) |
| Original WSO2 post | `OWN_POST` | 10 | S005 | PO review of an external share (phase 3) |
| Featured by WSO2 channels or an SLT member | `OWN_POST_AMPLIFIED` | 25 total (10 + 15 bonus) | S005 | PO marks the claim amplified (phase 3) |
| Like | `REACTION` | 1 | S006 | Nothing yet: needs Community Management (phase 4) |
| Comment | `COMMENT` | 1 | S006 | Nothing yet (phase 4) |
| Amplify Challenge entry | `CHALLENGE_ENTRY` | 10 | S006 | PO adjustment with a reason |
| Amplify Challenge winner | `CHALLENGE_WINNER` | 25 | S006 | PO adjustment with a reason |

`V014` widens the action checks on `scoring.point_rule` and `scoring.points_ledger` so these rows can exist. `SHARE_COMMENTARY` needed a row too: without it S001's old value of 12 would still apply to that fallback kind. `sharing.engagement.action` is unchanged until comments and reactions are synced.
