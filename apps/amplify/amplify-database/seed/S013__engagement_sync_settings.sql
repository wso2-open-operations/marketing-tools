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

-- S013: the Community Management engagement sync (V025). Off until an admin connects the page and turns it on.
INSERT INTO config_app_setting (key, value)
VALUES ('engagement.sync_enabled', 'false'),           -- job amplify-engagement-sync fires only when true
       ('engagement.schedule', '"0 */2 * * *"'),        -- every two hours, UTC
       ('engagement.daily_call_budget', '450')          -- Community Management calls per UTC day, all runs together
ON CONFLICT (key) DO NOTHING;
