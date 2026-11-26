# ADR-017: One external-share claim per URL

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** audit C5

## Context

Two employees could claim points for the same evidence URL.

## Decision

`UNIQUE (evidence_url, action)` on `external_sharing.external_share`, with the URL normalized first (scheme, host case, trailing slash, tracking params). On conflict the API returns `EVIDENCE_ALREADY_CLAIMED`; My Campaign shows *"Someone else already submitted this url, contact PO Team for review"*.

## Consequences

- Duplicates are blocked in the DB, not just the UI.
- Normalization must be one shared function, tested, or the key is easy to dodge.

## Amendment 2026-11-26: LinkedIn post links and short links

LinkedIn's **Copy link to post** now gives only a `lnkd.in/p/<code>` short link. It 301s to
`/posts/<slug>-share-N-x/?highlightedUpdateUrn=urn:li:activity:M&rcm=<per person>`.

- **One key per post:** on `/posts/` URLs the parser takes the activity from the slug (`-activity-M`), else from
  `highlightedUpdateUrn`, else `-share-N` / `-ugcPost-N`. The claim key is the canonical feed URL of that URN, so
  the per-person `rcm` never splits one post into two claims.
- **Short links are resolved, once:** amplify-api sends one `GET https://lnkd.in/<code>` (3 s timeout, redirects
  not followed). Only the checked code is sent; query and fragment are dropped. The `Location` is accepted only
  when it parses as a LinkedIn post URL that names a post URN, and that URL is what is stored and keyed. Anything
  else, or a failed call, is `INVALID_EVIDENCE_URL` with "open it in your browser and paste the full link".
- **Egress:** amplify-api gains `lnkd.in` (`linkedInShortLinkBaseUrl`, empty turns it off). Other submitted URLs
  are still never fetched.

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (C5)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M5 S3)
