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

-- S004: schedule settings amplify-api pushes to the scheduler (ADR-026). Schedules use the scheduler's
-- format: 5-field cron in UTC, a descriptor (`@daily`) or `@every <duration>`.
-- Existing values are never overwritten: an admin's change survives a re-seed.

SET LOCAL ROLE amplify_migrate;

INSERT INTO config.app_setting (key, value)
VALUES ('run.schedule', '"@every 5m"'),             -- job amplify-run -> amplify-jobs POST /runs
       ('run.enabled', 'true'),                     -- false disables the scheduler job (no Runs)
       ('maintenance.schedule', '"0 2 * * *"')      -- job amplify-maintenance-partitions, daily 02:00 UTC
ON CONFLICT (key) DO NOTHING;
