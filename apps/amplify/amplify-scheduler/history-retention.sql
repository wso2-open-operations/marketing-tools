-- Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
--
-- WSO2 LLC. licenses this file to you under the Apache License,
-- Version 2.0 (the "License"); you may not use this file except
-- in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.

-- Job-history retention for the scheduler's OWN database (ADR-026 gap, deep review 2026-10-17).
--
-- akorn/scheduler 1.7.8 never trims `job_history` (~105k rows a year at `@every 5m`), and its only purge,
-- `DELETE /jobs/{id}/history?before=`, needs a caller with a clock (no scheduler template has one). So the
-- table trims itself: after every insert the scheduler makes, rows older than the retention are deleted.
-- No new caller, no new connection, no Amplify code: it works whoever triggers the job.
--
-- Run as the scheduler's DB user, against the scheduler's database only (never Amplify's), AFTER the
-- scheduler has started once (it creates `job_history` itself). Idempotent: rerun after every scheduler
-- version bump (scripts/it-scheduler-history.sh checks the pinned image).
--   Compose: the `scheduler-retention` one-shot applies it.
--   Choreo:  docs/runbooks/operations.md §7 (once, from the scheduler DB console).
-- Retention: 30 days (the trigger argument below). Unqualified names on purpose: they resolve exactly as
-- the scheduler's own statements do.

CREATE INDEX IF NOT EXISTS amplify_job_history_started_idx ON job_history (started);

CREATE OR REPLACE FUNCTION amplify_trim_job_history()
    RETURNS trigger
    LANGUAGE plpgsql
AS $fn$
BEGIN
    DELETE FROM job_history WHERE started < now() - make_interval(days => TG_ARGV[0]::int);
    RETURN NULL;
END
$fn$;

DROP TRIGGER IF EXISTS amplify_trim_job_history ON job_history;
CREATE TRIGGER amplify_trim_job_history
    AFTER INSERT ON job_history
    FOR EACH STATEMENT
    EXECUTE FUNCTION amplify_trim_job_history('30');
