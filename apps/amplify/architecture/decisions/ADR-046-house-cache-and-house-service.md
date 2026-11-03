# ADR-046: Houses are held in an in-memory cache, never in Amplify's database

Status: Proposed (2026-11-03). The source of truth for houses and for who belongs to a house is not decided.

## Context

A house is a company-wide grouping that cuts across business units and teams. The One WSO2 UI shows a team's members with
their house and a dashboard of how each house is participating. The HR Entity has no house field (ADR-045). People-app
keeps house in its own database (a `house` table, and `house_id` on the employee), and a second source with houses is
being discussed. Amplify stores no HR data (ADR-009), so it cannot keep the employee-to-house link in its own tables.
Until now Amplify knew a house by name only (`houseOf`, `HouseCount`).

## Decision

- **A house is `{houseId, name, imageUrl}`** and an assignment is `{email, houseId}`. The names are the concept's, not a
  source's: the real entity names are still to be confirmed.
- **`amplify_domain.house`** (a new bounded context in `amplify-domain`, used by amplify-api and amplify-jobs):
  - `HouseCache`: an in-memory map of `houseId` to house and of work email to `houseId`, with a reverse index from a
    house to its members. Reads are one lock and a map lookup, with no I/O. Every entry lives 30 days
    (`DEFAULT_HOUSE_TTL_SECONDS`) unless refreshed. A full reload replaces the cache in one step, so a reader never
    sees a half-loaded one. Each process holds its own copy and a restart empties it (cold start).
  - `HouseService` (`house_service.bal`): `populate()` at start-up, `refresh()` (one at a time; a failed refresh keeps
    what is cached), `refreshHouse(id)`, `removeHouse(id)`, `removeEmployee(email)`, and cache-only reads
    (`getHouse`, `houseOf(email)`, `membersOf(houseId)`).
  - `HouseSource`: the port the service loads from (`getHouses`, `getAssignments`). The source is undecided, so nothing
    else depends on where the data comes from. `StaticHouseSource` serves the local stack and tests.
- **Not in `amplify-database`.** That component is the migration runner: it applies the SQL scripts and exits, so a
  cache cannot live in it, and no table or migration is added.
- **Never stored.** Neither houses nor assignments are written to Amplify's database, the outbox or the logs (counts
  only).

## Not yet decided

- **The source** of houses and assignments (people-app, the HR Entity when it offers one, or a new people-ops source).
  Both reads should come from the same source so an assignment never names a house the cache lacks.
- **Who triggers a refresh.** The scheduler only calls amplify-jobs today, and a cache is per process, so a refresh run in
  jobs would not reach amplify-api's cache. Proposed: the scheduler also calls an internal refresh route on amplify-api,
  and each process loads at start-up; the 30-day expiry is the backstop.
- **Image URLs.** Whether the UI can load them directly or Amplify must proxy them.

## Consequences

- Dashboards that group by house read `houseOf(email)` and `membersOf(houseId)` from the cache instead of the directory
  index, and the house board and counts can use the id, the name and the image.
- After a restart the cache is empty until the first load finishes. House reads then answer `()` (no house), not an error.
- This ADR changes no API or database yet. Wiring the cache into amplify-api and the scheduler comes with the source.
