-- Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
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

-- Add show_full_name column to attendees table
ALTER TABLE attendees 
    ADD COLUMN show_full_name BOOLEAN NOT NULL DEFAULT FALSE;
-- Add unique index for idempotency key
CREATE UNIQUE INDEX IF NOT EXISTS shop_order_idempotency_idx ON shop_order (user_uuid, idempotency_key) WHERE idempotency_key IS NOT NULL;

-- Add event_id to coin_allocation
ALTER TABLE coin_allocation ADD COLUMN event_id TEXT;
