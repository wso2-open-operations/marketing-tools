# ADR-003: amplify-jobs is an HTTP-triggered worker, amplify-cron schedules it

- **Status:** Accepted; the scheduler part (amplify-cron, Choreo Scheduled Task) is superseded by [ADR-026](ADR-026-akornatskyy-scheduler.md). The worker shape stands.
- **Date:** 2026-10-16
- **Source:** plan D3 / domains D3

## Context

The Run (sharing, announcements, scoring) needs a schedule and an on-demand trigger for "Save & Share Now". Internal timers make the same image behave differently across Docker, Choreo and OpenChoreo.

## Decision

`amplify-jobs` has no internal timer. It exposes `POST /runs` (project visibility). `amplify-cron` (Choreo Scheduled Task) calls it on a schedule; "Save & Share Now" calls it right away (fire-and-forget behind a breaker, cron catches up).

## Consequences

- The schedule lives in one place.
- Same image runs in Docker, Choreo and OpenChoreo.
- `POST /runs` must be idempotent and safe to call concurrently.
- Choreo Scheduled Task minimum interval is still unverified (plan M0 D3 sub-item).

## Links

- [Phase 1 plan](../../docs/requirements/phase1-planned-todos.md) (M0 D3, M6)
- [phase1-domains.md](../solution/Phase%201/phase1-domains.md) (D3)
