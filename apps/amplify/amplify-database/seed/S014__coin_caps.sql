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

-- S014: Coins safety caps for the automatic conversion (V026, ADR-048). A person never gets more than
-- `coin.max_coins_per_person` in one run, and one period's run never sends more than `coin.max_coins_per_run` in all;
-- points above a cap stay as carry and convert in a later run. Admins change them (whole numbers from 1).
INSERT INTO config_app_setting (key, value)
VALUES ('coin.max_coins_per_person', '500'),    -- 5,000 points at the S012 rate (100 points = 10 Coins)
       ('coin.max_coins_per_run', '50000')      -- the whole period, every employee together
ON CONFLICT (key) DO NOTHING;
