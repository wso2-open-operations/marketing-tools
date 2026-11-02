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

-- S008: token partition grace is 1 day, not the 5 that S003 seeds (ADR-002). The runner refuses a script
-- changed after it was applied, so S003 stays as it was. On a fresh database S003 inserts 5 after V016 has
-- already run, so this moves it to 1. A value an admin set to anything else is left alone.

SET LOCAL ROLE amplify_migrate;

UPDATE config.app_setting
SET value = '1'::jsonb,
    updated_by = 'system',
    updated_at = now(),
    version = version + 1
WHERE key = 'connection.token_grace_days'
  AND value = '5'::jsonb;
