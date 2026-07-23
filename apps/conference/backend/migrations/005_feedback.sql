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

-- session_id/event_id are plain UUID columns with no FK to sessions/
-- conference_config -- matches old behavior (no referential check) and the
-- user_connection no-FK-to-attendees precedent.
CREATE TABLE feedback (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_uuid     TEXT NOT NULL,
  feedback_type TEXT NOT NULL CHECK (feedback_type IN ('SESSION', 'EVENT')),
  session_id    UUID,
  event_id      UUID,
  rating        INT NOT NULL,
  comment       TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Defense in depth alongside the handler's own exclusivity check: a
  -- SESSION row must carry session_id only, an EVENT row event_id only --
  -- never both, never neither.
  CHECK (
    (feedback_type = 'SESSION' AND session_id IS NOT NULL AND event_id IS NULL) OR
    (feedback_type = 'EVENT' AND event_id IS NOT NULL AND session_id IS NULL)
  )
);
