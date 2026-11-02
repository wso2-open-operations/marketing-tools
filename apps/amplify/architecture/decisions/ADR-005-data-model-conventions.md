# ADR-005: Phase 1 data model conventions

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** domains D6 (no plan number)

## Context

The data model has to keep contexts liftable to separate services later and keep status from drifting.

## Decision

PostgreSQL 18, `uuidv7()` keys, **no cross-context FKs** (virtual FKs documented), status **derived from fact timestamps**, provider-agnostic tables, pre-built recognition tables for a fast One WSO2.

## Consequences

- Contexts can be split out later.
- Status can't drift from the facts.
- One schema serves Share on LinkedIn now and Community Management later.
- Integrity across contexts is enforced in code and tests, not FKs.

## Links

- [phase1-data-model.md](../solution/Phase%201/phase1-data-model.md)
- [phase1-domains.md](../solution/Phase%201/phase1-domains.md) (D6)
