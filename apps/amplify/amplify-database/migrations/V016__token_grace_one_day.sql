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

-- V016: drop a token day's partition 1 day after its last token expires, not 5 (ADR-002). Seeds never overwrite an
-- existing value, so this moves a database that still holds the old default of 5. A value an admin set to
-- anything else is left alone. A fresh database gets 1 from S003.

SET LOCAL ROLE amplify_migrate;

UPDATE config.app_setting
SET value = '1'::jsonb,
    updated_by = 'system',
    updated_at = now(),
    version = version + 1
WHERE key = 'connection.token_grace_days'
  AND value = '5'::jsonb;
