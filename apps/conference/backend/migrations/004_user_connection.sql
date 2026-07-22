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

-- initiator_id/recipient_id are attendees.idp_uuid (the JWT sub), not
-- attendees.id -- no FK, same looseness as the old schema.
CREATE TABLE user_connection (
  initiator_id  TEXT NOT NULL,
  recipient_id  TEXT NOT NULL,
  status        SMALLINT NOT NULL DEFAULT 0 CHECK (status IN (-1, 0, 1)),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (initiator_id, recipient_id)
);
