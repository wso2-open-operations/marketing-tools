# Migrations

Forward-only, versioned: `V001__schemas_roles.sql` … `V020__employee_alias.sql`. Lowercase snake_case
after `__`. Never edit an applied script (the runner compares checksums and stops); add a new version.

| Script | What |
| --- | --- |
| V001 | Roles (NOLOGIN, no passwords), schemas owned by `amplify_migrate`, `citext` + `pg_trgm`, password setter |
| V002 | `identity.employee`; `campaign.category`, `campaign`, `campaign_tag`, `campaign_v` |
| V003 | `member_connection`, `provider_token` (daily partitions), `oauth_state`, `member_connection_v`, `config.int_setting` |
| V004 | `share_request`, `engagement`, `engagement_verification`, `share_request_v`, `engagement_v` |
| V005 | `external_share` (C4, C5) + `external_share_v` |
| V006 | `point_rule`, `points_ledger` (column-level settlement grant, no PAID in phase 1) |
| V007 | `standing`, `standing_version`, `employee_points_monthly`, `campaign_participation` |
| V008 | `announcement` + view, `outbox`, `idempotency_key`, `audit_log` (monthly partitions), `app_setting` |
| V009 | Partition upkeep (`SECURITY DEFINER`): create ahead, token drop rule, audit retention, outbox purge, `run_partition_maintenance()` |
| V010 | Recognition upkeep: `apply_ledger_entry`, one-UPDATE `rerank`, `rebuild` |
| V011 | `announcement.chat_thread_name` (thread Chat returned, M6a); `announcement_v` recreated |
| V012 | Recognition writers serialized (advisory lock in `apply_ledger_entry`/`rerank`/`rebuild`); upkeep functions `lock_timeout = 5s` + one upkeep at a time ([doc](../../docs/migrations/2026-10-17-v012-recognition-lock-maintenance-timeout.md)) |
| V013 | `idle_in_transaction_session_timeout = 30s` on `amplify_api`/`amplify_jobs` (ALTER ROLE as the bootstrap admin, before `SET LOCAL ROLE`); dashboard indexes `points_ledger (created_at)`, `share_request (failed_at)`; lock-order comments on the V012 recognition functions ([doc](../../docs/migrations/2026-10-17-v013-idle-timeout-dashboard-indexes.md)) |
| V014 | the `scoring.point_rule` and `scoring.points_ledger` action checks accept every action the platform prices: adds `REACTION`, `COMMENT`, `CHALLENGE_ENTRY`, `CHALLENGE_WINNER` (nothing awards them yet; later phases need no schema change) |
| V015 | `connection.linkedin_consent`: the Link Me decision, `CONSENTED` or `DECLINED`, with the optional LinkedIn profile URL a person who declined typed. Private like the member URN: nothing for `amplify_readonly` |
| V016 | drops a token day's partition 1 day after its last token expires, not 5: moves `connection.token_grace_days` from 5 to 1 (ADR-002), for a database that still holds the old default |
| V017 | least privilege on `connection.provider_token`: `amplify_api` keeps INSERT, SELECT, DELETE (no UPDATE), `amplify_jobs` keeps SELECT, UPDATE, DELETE (no INSERT) |
| V018 | `identity.erase_employee(p_employee_id, p_actor, p_reason)`: the one audited way to erase an employee's personal data; the leaver sweep and the manual runbook both call it (ADR-040) |
| V019 | `campaign.campaign.resource_url` check also accepts the local stack's one http dev origin, `http://localhost:19091/...` (the app's `campaignLinkOrigins` stays the production policy; `image_url` stays https only) |
| V020 | `identity.employee_alias`: a re-created Asgardeo account (new `sub`, same email) maps to the person's first employee id, so history keeps one key (ADR-041) |

Rules: V001 runs as the bootstrap admin; every other script runs `SET LOCAL ROLE amplify_migrate` before its DDL (V013 first alters the app roles' settings as the bootstrap admin, which `amplify_migrate` can't).
Enums are `text` + `CHECK`. No `?` anywhere in a script (the JDBC driver treats it as a bind marker).
The runner stops on a `.sql` file whose name doesn't match `V###__snake_name.sql` and on two scripts with
the same number, so a misnamed script can't be skipped without a word.

Dry run (`dryRun=true`): connects, reads `public.schema_version` when it exists (it creates nothing; without it every script is pending),
logs each script as `PENDING`, `APPLIED` or `CHANGED`, applies nothing, and fails when an applied script was changed.
