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

-- S017: housekeeping ages and batch size (V029), read by amplify-jobs' daily maintenance pass. Admins change them
-- (amplify-api settings.bal: native intents 2-365 days, API usage and sync cursors 30-730 days, batch 100-50000).
INSERT INTO config_app_setting (key, value)
VALUES ('housekeeping.native_intent_days', '7'),      -- detected (or never-found) native repost clicks
       ('housekeeping.api_usage_days', '90'),         -- Community Management calls per UTC day
       ('housekeeping.sync_cursor_days', '180'),      -- post cursors not moved for this long
       ('housekeeping.batch_rows', '5000')            -- most rows one delete statement removes
ON CONFLICT (key) DO NOTHING;
