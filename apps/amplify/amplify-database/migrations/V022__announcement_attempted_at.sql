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

-- V022: the attempt marker for Novera announcements (owner decision 2026-11-03: Novera does not dedupe on
-- Idempotency-Key, so Amplify announces a campaign at most once on its own).
--
-- amplify-jobs writes attempted_at, in its own transaction, before it calls Novera, and clears it again only when
-- the call definitely sent nothing. A queued row that still carries the marker on a later run may already have
-- reached Novera (a crash, a lost answer or a failed save after Novera accepted), so the worker marks it
-- "Delivery unknown" for a person to check instead of sending a second card. The admin retry clears it.
--
-- The view was created with a.*, which PostgreSQL expands at creation time, so it is recreated to pick up the
-- new column (CREATE OR REPLACE can't insert a column before status). One login owns every object (ADR-043):
-- there are no grants to restore.

ALTER TABLE announcement ADD COLUMN attempted_at timestamptz;

DROP VIEW announcement_v;

CREATE VIEW announcement_v WITH (security_invoker = true) AS
SELECT a.*,
       CASE WHEN a.sent_at IS NOT NULL THEN 'SENT'
            WHEN a.failed_at IS NOT NULL THEN 'FAILED'
            ELSE 'QUEUED' END AS status
FROM announcement a;
