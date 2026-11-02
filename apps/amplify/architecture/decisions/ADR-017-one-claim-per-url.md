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

## Links

- [requirements-map.md](../solution/Phase%201/requirements-map.md) (C5)
- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M5 S3)
