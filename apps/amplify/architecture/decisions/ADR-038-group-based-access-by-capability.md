# ADR-038: Group-based access by capability, groups from configuration

- **Status:** Accepted
- **Date:** 2026-10-30
- **Source:** Lead Developer, 2026-10-30; refines ADR-010 to ADR-013 and ADR-036 (who holds each endpoint), not what the endpoints do

## Context

The four Amplify groups (`amplify_po`, `amplify_marketing`, `amplify_slt`, `amplify_admin`) were constants in `amplify-api/modules/auth/matrix.bal`, and the matrix rows listed role columns (`PO`, `MKT`, `SLT`, `ADM`). One WSO2 also hard-coded the group names to show New Post, Current Posts and Dashboarding. That made several open business questions code changes: should Marketing adjust points (plan D14), who may download the CSV of names and emails (R16), and whether reports are for SLT only or PO too (the client requirements list "PO, SLT"). A second team needing the same access, or a renamed Asgardeo group, also needed a release in two repos.

Other One WSO2 backends already work this way: Marketing Ops maps Asgardeo groups to capabilities in its backend and returns them from `/api/me`; the UI never sees a group name.

## Decision

1. **Nine capabilities, one per business need.** Each matrix row requires exactly one grant: `EMPLOYEE` (every signed-in employee) or one of `CAN_CAMPAIGN`, `CAN_DASHBOARD`, `CAN_EXPORT`, `CAN_REVIEW_SHARES`, `CAN_POINT_RULES`, `CAN_ADJUST_POINTS`, `CAN_PO_DASHBOARD`, `CAN_REPORTS`, `CAN_ADMIN` (`modules/auth/access.bal`). An open business question gets its own capability so the answer is configuration.
2. **Groups come from configuration.** Each capability has a configurable list of Asgardeo groups, `can<Capability>Groups` (`BAL_CONFIG_VAR_CAN<CAPABILITY>GROUPS` in Choreo), comma separated because `BAL_CONFIG_VAR_*` can't carry arrays. Holding any one group in the list grants the capability. Defaults reproduce the previous behaviour, with reports widened to PO:

   | Grant | Default groups |
   | --- | --- |
   | `CAN_CAMPAIGN` | `amplify_po`, `amplify_marketing` |
   | `CAN_DASHBOARD`, `CAN_EXPORT` | `amplify_po`, `amplify_marketing`, `amplify_slt`, `amplify_admin` |
   | `CAN_REVIEW_SHARES`, `CAN_POINT_RULES`, `CAN_ADJUST_POINTS`, `CAN_PO_DASHBOARD` | `amplify_po` |
   | `CAN_REPORTS` | `amplify_slt`, `amplify_po` |
   | `CAN_ADMIN` | `amplify_admin` |

3. **Grants are computed once,** when the token is verified, and carried on the `Principal`. The interceptor checks `rule.requires` against them; use cases ask `can(p, auth:CAN_…)`, never for a group name. Viewing campaigns in any status follows `CAN_CAMPAIGN`; seeing the whole company on the Team page and anyone's full history follows `CAN_ADJUST_POINTS`.
4. **`GET /me` returns `grants`** next to `roles` (the caller's configured groups) and `capabilities`. One WSO2 gates New Post, Current Posts and Dashboarding on `grants` and holds no group names.
5. **Fail closed.** A group that no list names is dropped from the token; a blank entry never matches; an empty list means nobody holds the capability. A missing `groups` claim is a plain employee.
6. **`openapi.yaml` names the grant** per operation in `x-access` (was `x-roles`); the contract test checks it against the matrix.

## Consequences

- Giving Marketing point adjustments, narrowing the export to PO and Admin, or adding a second PO group is a Choreo configuration change and a redeploy, no code. The Asgardeo groups must still reach both the id_token and the backend JWT (identity-setup A6).
- A new capability is a code change (enum value, configurable, descriptor entries, matrix rows, One WSO2 gate).
- Audit rows keep recording the caller's groups (`actorRoles`), now only the configured ones.
- The defaults still name the four groups in `config.bal`, so an environment with no access configuration behaves as before.

## Links

- [activity-matrix.md](../solution/Phase%201/activity-matrix.md), [identity-setup.md](../../docs/runbooks/identity-setup.md)
- [ADR-010](ADR-010-team-adjust-remove-po.md), [ADR-011](ADR-011-point-rules-po.md), [ADR-012](ADR-012-po-manages-campaigns.md), [ADR-013](ADR-013-po-dashboard-phase1.md), [ADR-036](ADR-036-dashboards-for-amplify-roles.md)
- Code: `amplify-api/modules/auth/access.bal`, `amplify-api/modules/auth/matrix.bal`, `amplify-api/config.bal`
