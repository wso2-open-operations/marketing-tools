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

-- Owned overlay for presentation-layer facts that have no home in the shared,
-- read-only marketingops schema. Today it carries only the moderator
-- designation for a (session, speaker) pair: session_speakers.role exists
-- upstream but has no "moderator" value (external/internal/keynote/leader), so
-- this service owns the designation instead of the frontend's moderators.json.
-- The backend LEFT JOINs this at serve time; a missing row means "not a
-- moderator". session_id/speaker_id are plain UUIDs with no FK to the shared
-- sessions/speakers tables -- same no-FK-to-read-only-tables precedent as
-- feedback and user_connection.
--
-- Track colour is deliberately NOT here: tracks.color already exists upstream
-- with real data, so it's a plain join, not an overlay (see PROGRESS Step 0).
-- An upstream request for session_speakers.role='moderator' is filed in
-- parallel; if it lands, this table collapses to a plain join and can be
-- dropped.
CREATE TABLE presentation_overlay (
  session_id   UUID NOT NULL,
  speaker_id   UUID NOT NULL,
  is_moderator BOOLEAN NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (session_id, speaker_id)
);
