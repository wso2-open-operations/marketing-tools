# ADR-001: Ballerina for all phase 1 services

- **Status:** Accepted
- **Date:** 2026-10-16
- **Source:** plan D1 / domains D1

## Context

The Choreo L2 assumed TypeScript. The team standard for integration services is Ballerina, and the LinkedIn mock is already Ballerina.

## Decision

`amplify-api`, `amplify-jobs` and `amplify-cron` are written in Ballerina.

## Consequences

- One language and toolchain across the three services and the mock.
- Supersedes the L2's TypeScript choice.
- Coding follows the WSO2 Digital Ballerina standards.

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D1)
- [phase1-domains.md](../solution/Phase%201/phase1-domains.md) (decision table)
