# ADR-046: Houses are held in an in-memory cache, never in Amplify's database

Status: Proposed (2026-11-03). House ids, names and assignments now come from the HR Entity (hr_entity 1.1.1). The
source of the house image URL is not decided, and the cache is not wired.

## Context

A house is a company-wide grouping that cuts across business units and teams. The One WSO2 UI shows a team's members with
their house and a dashboard of how each house is participating. **(2026-11-03):** the HR Entity (the employee source,
ADR-045) now exposes `houseId: Int` and `house: String` (the house name) on `Employee` (digiops-hr PR #2005, merged
2026-11-03, `hr_entity` 1.1.1). Both are null when the employee has no house, and the name is still returned after a
house is deactivated. It has no image URL, and `EmployeeFilter` has no house filter. There are four houses: CloudBots,
Titans, Legions and Wild Boars. Whether each Amplify environment already runs 1.1.1 is not confirmed. amplify-api asks
for the two fields only when `hrEntityIncludeHouse` is on (ADR-045). Amplify stores no HR data (ADR-009), so it cannot
keep the employee-to-house link in its own tables. The directory index knows a house by name (`houseOf`,
`houseMembers`, `HouseCount`), and `DirectoryRecord` now also carries `houseId`.

## Decision

- **A house is `{houseId, name, imageUrl}`** and an assignment is `{email, houseId}`. The HR Entity's `houseId` is an
  integer; the cache keys houses by a string id, so the loader converts it.
- **In `amplify-api`, next to the directory index** (`house_types.bal`, `house_cache.bal`, `house_service.bal` beside
  `outbound.bal`), not in `amplify-domain`. A house is the same kind of data about an employee as the directory index
  holds, the api is what serves the UI, and each process holds its own copy anyway, so a shared library buys nothing.
  The types are package-private:
  - `HouseCache`: an in-memory map of `houseId` to house and of work email to `houseId`, with a reverse index from a
    house to its members. Reads are one lock and a map lookup, with no I/O. Every entry lives 30 days
    (`DEFAULT_HOUSE_TTL_SECONDS`) unless refreshed. A full reload replaces the cache in one step, so a reader never
    sees a half-loaded one. Each process holds its own copy and a restart empties it (cold start).
  - `HouseService` (`house_service.bal`): `populate()` at start-up, `refresh()` (one at a time; a failed refresh keeps
    what is cached), `refreshHouse(id)`, `removeHouse(id)`, `removeEmployee(email)`, and cache-only reads
    (`getHouse`, `houseOf(email)`, `membersOf(houseId)`).
  - `HouseSource`: the port the service loads from (`getHouses`, `getAssignments`). `StaticHouseSource` serves the
    local stack and tests.
- **Ids, names and assignments come from the directory read.** The rows the index already reads carry `houseId` and
  `house`, so a `HouseSource` built from the index gives both the houses `{houseId, name}` and the assignments
  `{email, houseId}`, with no second fetch. Only the image URL needs another source.
- **Not in `amplify-database`.** That component is the migration runner: it applies the SQL scripts and exits, so a
  cache cannot live in it, and no table or migration is added.
- **Never stored.** Neither houses nor assignments are written to Amplify's database, the outbox or the logs (counts
  only).

## Not yet decided

- **The image URL source.** The HR Entity has none. Options: a config map of the four houses, a static asset in the
  One WSO2 UI, or a people-ops source. Also whether the UI loads images directly or Amplify proxies them.
- **Who triggers a refresh.** This need is smaller now. The directory read already refreshes every 24 hours
  (`rosterCacheSeconds`), so populating the house cache on start-up and on each directory refresh keeps it current
  without a scheduler call. A separate refresh route is only needed if the image source changes on its own schedule.
  If amplify-jobs ever needs houses, it holds its own copy.

## Consequences

- Dashboards that group by house read `houseOf(email)` and `membersOf(houseId)` from the cache instead of the directory
  index, and the house board and counts can use the id, the name and the image.
- After a restart the cache is empty until the first load finishes. House reads then answer `()` (no house), not an error.
- This ADR changes no API or database yet. Nothing calls `populate()` or `refresh()`. Until the cache is wired, the
  house board, `by=HOUSE` counts and My Team's house names read the directory index, which has houses once
  `hrEntityIncludeHouse` is on.
