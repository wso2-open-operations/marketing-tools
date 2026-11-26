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
-- S015: pre-coin verification (V027, ADR-048 amendment). The conversion takes an engagement row only when its
-- LinkedIn activity was seen within `coin.verify_max_age_hours` (the verification job runs an hour before it).
-- `coin.verify_member_daily_call_budget` caps the reads made with employees' own tokens per UTC day; the page-token
-- reads share `engagement.daily_call_budget` with the engagement sync. Admins change both; a change survives a re-seed.

INSERT INTO config_app_setting (key, value) VALUES
    ('coin.verify_max_age_hours', '48'),
    ('coin.verify_member_daily_call_budget', '1000')
ON CONFLICT (key) DO NOTHING;
