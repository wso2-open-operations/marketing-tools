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

-- S012: Coins settings (phase 2). Points convert automatically, with no approval step: every `coin.block_points`
-- not yet paid become `coin.block_coins` Coins on the `coin.schedule` (only whole blocks; the rest carries over).
-- `coin.wallets_enabled` stays false until the WSO2 Coins API exists, and points keep counting meanwhile.
-- The PO team decides the rate and schedule (100 = 10, monthly, until then). An admin's change survives a re-seed.

INSERT INTO config_app_setting (key, value) VALUES
    ('coin.block_points', '100'),
    ('coin.block_coins', '10'),
    ('coin.schedule', '"MONTHLY"'),
    ('coin.wallets_enabled', 'false')
ON CONFLICT (key) DO NOTHING;
