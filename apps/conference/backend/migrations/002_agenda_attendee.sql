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

-- SUPERSEDED -- DO NOT APPLY.
--
-- This migration was never applied to any deployed database, and must not be.
-- It creates an event-level registration marker that nothing writes to, so
-- applying it would leave IsRegistered() answering false for everybody and coin
-- earning silently dead rather than loudly broken.
--
-- The live registration list is marketingops.attendee_registration, owned and
-- written by the agenda-organizer app: one row per (attendee, session), with
-- attendee_id holding the attendee's email encrypted with PII_ENCRYPTION_KEY.
-- internal/repository/attendee.go reads that table instead. Kept here only so
-- the migration numbering stays contiguous.

CREATE TABLE agenda_attendee (
  attendee_id  TEXT PRIMARY KEY,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
