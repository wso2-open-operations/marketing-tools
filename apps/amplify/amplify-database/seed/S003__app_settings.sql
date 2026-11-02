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

-- S003: app_setting defaults (phase1-data-model › infrastructure, leaderboards.md, po-dashboard.md).
-- Existing values are never overwritten: an admin's change survives a re-seed.

SET LOCAL ROLE amplify_migrate;

INSERT INTO config.app_setting (key, value)
VALUES ('leaderboard.top_n', '3'),                  -- B16
       ('team.visibility', '"TEAM"'),               -- ADR-019: TEAM or COMPANY
       ('campaign.default_window_days', '30'),      -- C7
       ('po.review_sla_hours', '48'),               -- po-dashboard.md
       ('posts.window_days', '14'),
       ('connection.reminder_days', '7'),
       ('connection.token_grace_days', '5'),        -- ADR-002, D7 open
       ('audit.retention_months', '60'),            -- B17
       ('sharing.enabled', 'true'),                 -- kill switch
       ('announcements.enabled', 'true')            -- kill switch
ON CONFLICT (key) DO NOTHING;
