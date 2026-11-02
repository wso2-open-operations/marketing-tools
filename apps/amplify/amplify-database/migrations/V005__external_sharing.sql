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

-- V005: S3 External Sharing, "My Campaign" (phase1-data-model › external_sharing, C4, C5, ADR-017).

SET LOCAL ROLE amplify_migrate;

CREATE TABLE external_sharing.external_share (
    id                     uuid        PRIMARY KEY DEFAULT uuidv7(),
    employee_id            text        NOT NULL,
    campaign_id            uuid,
    action                 text        NOT NULL CHECK (action IN ('OWN_POST')),
    -- Normalized by the domain before insert (EvidenceUrl, C5); never fetched server-side.
    evidence_url           text        NOT NULL CHECK (evidence_url LIKE 'https://%' AND length(evidence_url) <= 2048),
    evidence_url_submitted text        NOT NULL CHECK (length(evidence_url_submitted) <= 2048),
    evidence_host          text        NOT NULL,
    provider               text        NOT NULL,
    resource_urn           text,
    certified_at           timestamptz NOT NULL,
    decision               text        CHECK (decision IN ('APPROVED', 'REJECTED')),
    decided_by             text,
    decided_at             timestamptz,
    decision_reason        text,
    amplified_at           timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    version                int         NOT NULL DEFAULT 1 CHECK (version > 0),
    -- One claim per URL per action, across all employees (C5).
    CONSTRAINT external_share_evidence_uk UNIQUE (evidence_url, action),
    -- Amplified only after approval (C4). IS NOT DISTINCT FROM, because `decision = 'APPROVED'` is NULL
    -- (so the CHECK would pass) while the claim is still pending.
    CONSTRAINT external_share_amplified_ck CHECK (amplified_at IS NULL OR decision IS NOT DISTINCT FROM 'APPROVED'),
    CONSTRAINT external_share_decision_ck
        CHECK ((decision IS NULL) = (decided_at IS NULL) AND (decision IS NULL) = (decided_by IS NULL)),
    CONSTRAINT external_share_reject_reason_ck CHECK (decision IS DISTINCT FROM 'REJECTED' OR decision_reason IS NOT NULL),
    CONSTRAINT external_share_self_review_ck CHECK (decided_by IS NULL OR decided_by <> employee_id)
);

-- PO queue, and My Campaign.
CREATE INDEX external_share_pending_idx ON external_sharing.external_share (created_at) WHERE decision IS NULL;
CREATE INDEX external_share_employee_idx ON external_sharing.external_share (employee_id, created_at DESC);

CREATE VIEW external_sharing.external_share_v WITH (security_invoker = true) AS
SELECT es.*,
       CASE WHEN es.decision IS NULL THEN 'PENDING'
            WHEN es.amplified_at IS NOT NULL THEN 'AMPLIFIED'
            ELSE es.decision END AS status
FROM external_sharing.external_share es;

GRANT SELECT, INSERT, UPDATE ON external_sharing.external_share TO amplify_api;
GRANT SELECT ON external_sharing.external_share TO amplify_jobs, amplify_readonly;
GRANT SELECT ON external_sharing.external_share_v TO amplify_api, amplify_jobs, amplify_readonly;
