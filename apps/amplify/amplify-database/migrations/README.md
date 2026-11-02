# Migrations

Forward-only, versioned: `V001__schema_and_extensions.sql` … `V021__immutable_ledger_and_audit.sql`. Lowercase snake_case
after `__`. Never edit an applied script (the runner compares checksums and stops); add a new version. One exception, once: V001-V020 and S001-S010 were rewritten for ADR-043 on 2026-11-02 and the dev database reinstalled.

| Script | What |
| --- | --- |
| V001 | Checks the schema exists and installs `citext` + `pg_trgm`. Creates no roles and no schema (ADR-043) |
| V002 | `identity_employee`; `campaign_category`, `campaign`, `campaign_tag`, `campaign_v` |
| V003 | `member_connection`, `provider_token` (daily partitions), `oauth_state`, `member_connection_v`, `config_int_setting` |
| V004 | `share_request`, `engagement`, `engagement_verification`, `share_request_v`, `engagement_v` |
| V005 | `external_share` (C4, C5) + `external_share_v` |
| V006 | `point_rule`, `points_ledger` (column-level settlement grant, no PAID in phase 1) |
| V007 | `standing`, `standing_version`, `employee_points_monthly`, `campaign_participation` |
| V008 | `announcement` + view, `outbox`, `idempotency_key`, `audit_log` (monthly partitions), `app_setting` |
| V009 | Partition upkeep (`SECURITY DEFINER`): create ahead, token drop rule, audit retention, outbox purge, `run_partition_maintenance()` |
| V010 | Recognition upkeep: `apply_ledger_entry`, one-UPDATE `rerank`, `rebuild` |
| V011 | `announcement.chat_thread_name` (thread Chat returned, M6a); `announcement_v` recreated |
| V012 | Recognition writers serialized (advisory lock in `apply_ledger_entry`/`rerank`/`rebuild`); upkeep functions `lock_timeout = 5s` + one upkeep at a time ([doc](../../docs/migrations/2026-10-17-v012-recognition-lock-maintenance-timeout.md)) |
| V013 | dashboard indexes (the 30 s `idle_in_transaction_session_timeout` is sent as a startup option, ADR-043); dashboard indexes `points_ledger (created_at)`, `share_request (failed_at)`; lock-order comments on the V012 recognition functions ([doc](../../docs/migrations/2026-10-17-v013-idle-timeout-dashboard-indexes.md)) |
| V014 | the `scoring_point_rule` and `scoring_points_ledger` action checks accept every action the platform prices: adds `REACTION`, `COMMENT`, `CHALLENGE_ENTRY`, `CHALLENGE_WINNER` (nothing awards them yet; later phases need no schema change) |
| V015 | `connection_linkedin_consent`: the Link Me decision, `CONSENTED` or `DECLINED`, with the optional LinkedIn profile URL a person who declined typed. Private like the member URN: nothing for `amplify_readonly` |
| V016 | drops a token day's partition 1 day after its last token expires, not 5: moves `connection.token_grace_days` from 5 to 1 (ADR-002), for a database that still holds the old default |
| V017 | *(removed: it only held role grants, ADR-043; the number is left unused)* |
| V018 | `identity_erase_employee(p_employee_id, p_actor, p_reason)`: the one audited way to erase an employee's personal data; the leaver sweep and the manual runbook both call it (ADR-040) |
| V019 | `campaign.resource_url` check also accepts the local stack's one http dev origin, `http://localhost:19091/...` (the app's `campaignLinkOrigins` stays the production policy; `image_url` stays https only) |
| V020 | `identity_employee_alias`: a re-created Asgardeo account (new `sub`, same email) maps to the person's first employee id, so history keeps one key (ADR-041) |
| V021 | `scoring_points_ledger_guard` and `audit_log_guard` triggers: the ledger changes only its settlement columns and is never deleted; the audit log is never changed or deleted (ADR-043 compensating control) |

Rules: every script runs as the login user; no script creates, grants to or switches to a role. No script names a schema: the runner puts it first on the `search_path`, and `SECURITY DEFINER` functions use `SET search_path FROM CURRENT`. Table names are `<context>_<name>`, and a name that repeats its context isn't doubled (`audit_log`).
Enums are `text` + `CHECK`. No `?` anywhere in a script (the JDBC driver treats it as a bind marker).
The runner stops on a `.sql` file whose name doesn't match `V###__snake_name.sql` and on two scripts with
the same number, so a misnamed script can't be skipped without a word.

Dry run (`dryRun=true`): connects, reads `public.schema_version` when it exists (it creates nothing; without it every script is pending),
logs each script as `PENDING`, `APPLIED` or `CHANGED`, applies nothing, and fails when an applied script was changed.
