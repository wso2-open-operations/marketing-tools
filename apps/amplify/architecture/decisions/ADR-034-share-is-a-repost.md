# ADR-034: The Amplify action is a REPOST of the campaign post (D5 spike passed)

- **Status:** Accepted
- **Date:** 2026-10-20
- **Source:** plan M0 D5

## Context

Plan D5 asked whether a member token with `w_member_social` can reshare an **organization's** post through `POST /rest/posts` with `reshareContext.parent`, or whether Amplify must fall back to `SHARE`: a new post by the member with a link card to the original. Until it was answered, the UI shipped `SHARE` (ADR-006, phase 1 scope), and all four kinds (`REPOST`, `REPOST_COMMENTARY`, `SHARE`, `SHARE_COMMENTARY`) already existed in the enums (B4).

## Decision

**The Amplify action is a `REPOST`.** The share dialog, and with it the Celebrate Amplify button and the Google Chat card button (which opens Celebrate with `?share=<campaignId>`), sends `kind: "REPOST"`. `SHARE` stays in the enums and the adapter as the fallback kind; `REPOST_COMMENTARY` is sent when the employee adds their own thoughts in the dialog (see the 2026-10-21 addendum); `SHARE_COMMENTARY` stays unused.

Evidence, 2026-10-20, real LinkedIn with a non-prod app (scopes `openid profile w_member_social`):

- Test org page `urn:li:organization:143998207`, post `urn:li:share:7518440281881534464`, registered as a campaign.
- `POST /campaigns/{id}/shares {"kind":"REPOST"}` as a connected member, then one jobs Run.
- LinkedIn accepted it on the first attempt: share `PUBLISHED`, kind `REPOST`, no error, and returned a new reshare `urn:li:share:7518440439495028737`.
- Earlier the same day the old `SHARE` kind also published (a new post with an article card), so both kinds work; REPOST is the one that shows as a repost.

## Consequences

- Points tiers stay as designed: the repost is the lowest tier (T1), and `SHARE` prices like its repost equivalent if it is ever used.
- There is **no automatic fallback** to `SHARE`. If LinkedIn refuses a reshare for someone, the share ends `FAILED` with the provider error code and the user can ask again. Add the fallback only if real failures show up.
- The spike proved one member and one page. A different member, a page post from another org, or an app in LinkedIn's review states may behave differently; watch `failure_reason` and `last_error_code` in the pilot.
- amplify-api still accepts all four kinds. Nothing in the UI sends the others.
- One share per campaign per employee is unchanged, whatever the kind.

## Addendum 2026-10-21: commentary works (D5b spike passed)

`POST /rest/posts` with `reshareContext.parent` plus `commentary` is accepted for a member token with `w_member_social`.

- Test org page `urn:li:organization:143998207`, post `urn:li:share:7518758210866921472` ("test demo 6"), registered as a campaign.
- `POST /campaigns/{id}/shares {"kind":"REPOST_COMMENTARY","commentary":"... @mention #hashtag [brackets] (parens) & ampersand."}` as a connected member, then one jobs Run: share `PUBLISHED` on the first attempt.
- On LinkedIn the repost shows the text above the original post. `#hashtag` becomes a hashtag link; `@mention` stays plain text (we send plain text, no mention markup); the other characters pass through unchanged.

**Decision:** the share dialog gets an optional "Add your thoughts" box. Text present sends `REPOST_COMMENTARY`; empty sends `REPOST`. Points: the commentary tier (5) already exists in `point_rule` (D6).

**Two things the spike found:**

- **A post that refuses reshares returns `403 FORBIDDEN`, for plain `REPOST` too.** A different post on the same page returned 403 for `REPOST_COMMENTARY` and then for `REPOST`, so commentary isn't what LinkedIn objected to. Resharing turned off on the parent is the likely cause; we can't read that flag back. The share ends `FAILED` with `last_error_code = FORBIDDEN`. Still no automatic `SHARE` fallback.
- **A feed link carries `urn:li:activity:<id>`, and reposts of that form fail with `REJECTED`.** The campaign must be registered with `urn:li:share:<id>` (or `ugcPost`). Plan D5b tracks converting or refusing the activity form at registration.

**Not yet verified:** the 3000-character cap (LinkedIn publishes no maximum; plan D5b).

## Links

- [ADR-006](ADR-006-phase1-scoring-scope.md), [phase1-domains.md](../solution/Phase%201/phase1-domains.md), [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md) (Kinds, B4)
- [Plan M0 D5](../../docs/requirements/phase1-planned-todos.md)
