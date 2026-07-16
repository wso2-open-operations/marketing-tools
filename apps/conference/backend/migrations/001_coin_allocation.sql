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

CREATE TABLE coin_allocation (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  qr_id               UUID NOT NULL,
  event_type          TEXT NOT NULL CHECK (event_type IN ('SESSION', 'O2BAR', 'GENERAL')),
  user_uuid           UUID NOT NULL,
  wallet_address      TEXT NOT NULL,
  coins_allocated     NUMERIC NOT NULL,
  transaction_status  TEXT NOT NULL DEFAULT 'PENDING'
                        CHECK (transaction_status IN ('PENDING', 'PROCESSING', 'TRANSFERRED', 'FAILED')),
  event_data          JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (qr_id, user_uuid)
);

CREATE INDEX coin_allocation_user_uuid_idx ON coin_allocation (user_uuid);
CREATE INDEX coin_allocation_event_type_idx ON coin_allocation (event_type);
