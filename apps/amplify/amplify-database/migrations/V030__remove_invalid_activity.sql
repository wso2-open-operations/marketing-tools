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

-- V030: "Remove invalid activity" (PO, ADR-010 amendment 2026-11-26). Two contexts, new columns, no cross-context
-- write: scoring appends the reversal with its reason code and an ActivityRemoved outbox row; sharing flags the
-- engagement from that event (amplify-api right away, amplify-jobs as the backstop).
--   scoring_points_ledger.removal_reason  why a REV- row removed an invalid activity; NULL on every other row. Set on
--                                         insert only (the V021/V026 guard keeps it fixed)
--   sharing_engagement.invalidated_at     when a PO removed the engagement as invalid; with invalid_reason
--   sharing_engagement.invalid_reason     the same reason code
-- sharing_engagement_v is recreated (it expanded e.* at creation) and derives status INVALID first, so every dashboard
-- query that counts status = 'ACTIVE' leaves a removed engagement out. Nothing personal is added: erasure is unchanged.

ALTER TABLE scoring_points_ledger
    ADD COLUMN removal_reason text
        CONSTRAINT points_ledger_removal_reason_ck
        CHECK (removal_reason IS NULL
               OR (source_type = 'REVERSAL' AND removal_reason IN ('DUPLICATE', 'NOT_A_REAL_REPOST', 'SPAM', 'OTHER')));

ALTER TABLE sharing_engagement
    ADD COLUMN invalidated_at timestamptz,
    ADD COLUMN invalid_reason text
        CONSTRAINT engagement_invalid_reason_ck
        CHECK (invalid_reason IS NULL OR invalid_reason IN ('DUPLICATE', 'NOT_A_REAL_REPOST', 'SPAM', 'OTHER')),
    ADD CONSTRAINT engagement_invalidated_ck CHECK ((invalidated_at IS NULL) = (invalid_reason IS NULL));

DROP VIEW sharing_engagement_v;
CREATE VIEW sharing_engagement_v WITH (security_invoker = true) AS
SELECT e.*,
       CASE WHEN e.invalidated_at IS NOT NULL THEN 'INVALID'
            WHEN e.deleted_at IS NOT NULL THEN 'DELETED'
            ELSE 'ACTIVE' END AS status
FROM sharing_engagement e;
