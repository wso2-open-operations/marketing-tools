# ADR-039: An internal key and a scheduler key protect amplify-jobs

- **Status:** Accepted (amended 2026-11-01: scoped scheduler key)
- **Date:** 2026-10-30
- **Source:** Security review, "back-office components have no authentication"; refines ADR-003, ADR-026

## Context

amplify-jobs runs the strongest operations Amplify has (`POST /runs`, `/maintenance/partitions`, `/maintenance/rebuild-recognition`)
and had no authentication: Choreo Project visibility was the only control. The scheduler (the pinned `akorn/scheduler`
image, ADR-026) cannot authenticate its own callers at all.

## Decision

1. **A shared secret header.** Every call to amplify-jobs except `GET /health` and `GET /ready` must carry
   `X-Amplify-Internal-Key`. Jobs compares it in constant time and answers 401 otherwise, logging the route and whether a key
   was sent, never the key.
2. **Fail closed.** Jobs does not start without `internalApiKey` of at least 32 characters. amplify-api does not start without it
   when `jobsUrl` or `schedulerUrl` is set.
3. **Who sends it.** amplify-api on its "Save & Share Now" trigger, and the scheduler: amplify-api sets the header on each job it
   registers (`scheduler_sync.bal`), so a manual edit in the scheduler UI that drops the header is overwritten by the next reconcile.
4. **One secret per environment**, the same value on both components (`INTERNALAPIKEY` in Choreo secrets; `AMPLIFY_INTERNAL_API_KEY`
   locally, filled by `make env`). Rotation is a config change on both, then a scheduler sync.

## Consequences

- A pod in the project that does not hold the key can no longer start a run, a rebuild or partition maintenance.
- **Residual risk:** the scheduler's own API still has no authentication (the image has none), and the key now also sits in the
  scheduler's own database as a job header. Anyone who can reach the scheduler can read it and change jobs. Keep the scheduler behind
  a network policy that admits amplify-api only; that is a Platform action, listed in the security actions file.
- OAuth client credentials (a signed, expiring token) would be stronger but the scheduler cannot fetch tokens, so it would need a sidecar.

## Links

- Code: `amplify-jobs/auth.bal`, `amplify-api/outbound.bal` (`internalApiKey`), `amplify-api/scheduler_sync.bal`

## Amendment (2026-11-01): a scoped scheduler key

The scheduler stores each job's headers in its own database and its API has no authentication, so the key it holds is the one most
likely to leak. One shared key meant that leak opened `rebuild-recognition` and the leaver sweep too.

- **Two keys.** `internalApiKey` keeps full access and is what amplify-api uses for its own triggers ("Save & Share Now"). A new
  `schedulerApiKey` is the only key registered on the scheduler's jobs (`schedulerKeyHeaders()` in `scheduler_sync.bal`).
  amplify-jobs accepts the scheduler key **only** for `POST /runs` and `POST /maintenance/partitions`. On any other route (including
  `/maintenance/rebuild-recognition`, `/maintenance/leavers`, any other method) it answers **403**. A missing, wrong or partial key is 401.
  Probes stay open.
- **Fail closed, both ways.** amplify-jobs does not start unless both keys are at least 32 characters (after trim) and differ from each
  other. amplify-api requires the internal key when `jobsUrl` is set, the scheduler key when `schedulerUrl` is set, and refuses equal values.
- **Compare both every time.** The interceptor evaluates both constant-time comparisons for every request (no early exit), trims as
  before, and never logs either key.
- **Config.** `schedulerApiKey` on both components (Choreo secret `SCHEDULERAPIKEY`; locally `AMPLIFY_SCHEDULER_API_KEY`, filled by
  `make env`, which also backfills older `.env` files). Rotation of either key: change it on both components, then a scheduler sync
  (`PUT /admin/settings` or an amplify-api restart) so the registered jobs pick up a new scheduler key.
- **Network policy dropped for phase 1 (Scott, 2026-11-01).** The "network policy admits amplify-api only" mitigation is not being done;
  the scoped key is the control instead. The scheduler's API stays unauthenticated, so a reader of its database or API still gets the
  scheduler key and can run `/runs` and partition maintenance (both are bounded: the run lock, LinkedIn ceilings and idempotent
  maintenance) but nothing else. The scheduler is going to be replaced later; revisit then.
- **Asgardeo client-credentials tokens considered and rejected for now.** The pinned scheduler image sends static headers and cannot
  fetch tokens, and a token-fetching sidecar is not worth building for a component that will be replaced. Revisit when the scheduler is
  replaced.
