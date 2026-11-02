# ADR-002: PostgreSQL, schema per context, daily token partitions

- **Status:** Accepted (Choreo extension check still open, see plan D2)
- **Date:** 2026-10-16
- **Source:** plan D2 / domains D2

## Context

Phase 1 needs a relational store with clear context boundaries. LinkedIn member tokens are sensitive and expire, so bulk deletion matters.

## Decision

PostgreSQL, one schema per bounded context. LinkedIn tokens live in a **daily time-partitioned** table; a partition is dropped once every token in it is past expiry plus a grace period (default 1 day).

## Consequences

- Context boundaries show up in the data.
- Expired tokens go in bulk, no row-by-row deletes.
- Depends on `citext` and `pg_trgm` on the Choreo (Aiven) database. Run `apps/amplify/amplify-database/checks/d2_extensions.sql` and record the result before M3; if either is missing, revisit the design (B18).
- Grace period, key rotation and evidence URL retention are still open (plan D7).

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D2, D7)
- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md) (token partitions)
