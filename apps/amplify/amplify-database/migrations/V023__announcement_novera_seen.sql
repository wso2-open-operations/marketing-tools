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

-- V023: who has seen a post's Novera announcement.
--
-- Novera now answers an announcement with its broadcast id and counts, per broadcast, the DMs whose chat has been
-- read past the card (Google Chat read state). amplify-jobs keeps the id when the card is accepted and copies the
-- count every few hours while the broadcast is recent; the dashboards show it next to the delivery status.
--
-- All four columns stay NULL for rows from before this change, for a Novera that returns no id, and until the first
-- count. The id is checked to the shape both sides accept, because it goes into Novera's URL path.
--
-- The view was created with a.*, which PostgreSQL expands at creation time, so it is recreated to pick up the
-- new columns (as in V022). One login owns every object (ADR-043): there are no grants to restore.

ALTER TABLE announcement
    ADD COLUMN novera_notification_id text,
    ADD COLUMN novera_recipients      int,
    ADD COLUMN novera_seen            int,
    ADD COLUMN novera_checked_at      timestamptz,
    ADD CONSTRAINT announcement_novera_notification_id_ck
        CHECK (novera_notification_id ~ '^[A-Za-z0-9._:-]{1,100}$'),
    ADD CONSTRAINT announcement_novera_counts_ck
        CHECK (novera_recipients >= 0 AND novera_seen >= 0 AND novera_seen <= novera_recipients);

DROP VIEW announcement_v;

CREATE VIEW announcement_v WITH (security_invoker = true) AS
SELECT a.*,
       CASE WHEN a.sent_at IS NOT NULL THEN 'SENT'
            WHEN a.failed_at IS NOT NULL THEN 'FAILED'
            ELSE 'QUEUED' END AS status
FROM announcement a;
