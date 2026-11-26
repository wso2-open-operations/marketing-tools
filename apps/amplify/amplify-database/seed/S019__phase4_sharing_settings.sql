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

-- S019: phase 4 sharing settings, admin-editable. The native repost default reaches every employee in GET /me; the
-- posting limits are read by amplify-jobs at the start of each run (its configurables stay the hard ceilings).
INSERT INTO config_app_setting (key, value)
VALUES ('sharing.native_repost_default', 'false'),  -- the share dialog starts on the in-app repost
       ('sharing.max_posts_per_day', '450'),        -- LinkedIn posts per UTC day, all runs together
       ('sharing.max_posts_per_hour', '60'),        -- LinkedIn posts in any rolling hour; 0 = off
       ('sharing.spread_minutes', '120'),           -- a campaign's shares spread over this window after it opens; 0 = off
       ('sharing.publish_gap_minutes', '10')        -- least time between two posts of one employee; 0 = off
ON CONFLICT (key) DO NOTHING;
