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

-- S016: the post reach refresh (V028) and the reports' smallest group. Reach is off until the Community Management
-- app has r_member_postAnalytics and employees have connected Reach.
INSERT INTO config_app_setting (key, value)
VALUES ('reach.enabled', 'false'),                 -- job amplify-reach-refresh fires only when true
       ('reach.schedule', '"30 3 * * *"'),          -- daily at 03:30 UTC
       ('reach.window_days', '30'),                 -- in-app shares of the last N days are measured
       ('dashboards.min_group_size', '5')           -- a location group smaller than this is merged into "Other"
ON CONFLICT (key) DO NOTHING;
