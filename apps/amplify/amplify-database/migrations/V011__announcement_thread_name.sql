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

-- V011: store the thread name Chat returns with each Club card (plan M6a), next to chat_message_name.
-- The view was created with `a.*`, which PostgreSQL expands at creation time, so it is recreated to
-- pick up the new column (CREATE OR REPLACE can't insert a column before `status`).

SET LOCAL ROLE amplify_migrate;

ALTER TABLE announcement.announcement ADD COLUMN chat_thread_name text;

DROP VIEW announcement.announcement_v;

CREATE VIEW announcement.announcement_v WITH (security_invoker = true) AS
SELECT a.*,
       CASE WHEN a.sent_at IS NOT NULL THEN 'SENT'
            WHEN a.failed_at IS NOT NULL THEN 'FAILED'
            ELSE 'QUEUED' END AS status
FROM announcement.announcement a;

GRANT SELECT ON announcement.announcement_v TO amplify_api, amplify_readonly, amplify_jobs;
