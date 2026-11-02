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

-- V004: C1 Sharing (phase1-data-model › sharing). `share_request` is the command, `engagement` the fact.
-- `engagement_metric` and `sync_cursor` are a future phase and aren't created here.

SET LOCAL ROLE amplify_migrate;

CREATE TABLE sharing.engagement (
    id                  uuid        PRIMARY KEY DEFAULT uuidv7(),
    provider            text        NOT NULL CHECK (provider IN ('linkedin')),
    provider_api        text        NOT NULL CHECK (provider_api IN ('SHARE_ON_LINKEDIN', 'COMMUNITY_MANAGEMENT', 'WEBHOOK')),
    origin              text        NOT NULL CHECK (origin IN ('IN_APP', 'API_SYNC', 'WEBHOOK')),
    target_resource_urn text        NOT NULL,
    campaign_id         uuid,
    actor_member_urn    text        NOT NULL,
    employee_id         text        NOT NULL,
    action              text        NOT NULL CHECK (action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY')),
    activity_urn        text,
    occurred_at         timestamptz NOT NULL,
    observed_at         timestamptz NOT NULL DEFAULT now(),
    last_verified_at    timestamptz,
    deleted_at          timestamptz,
    -- The three-way filter: once per action per resource per person, from any API.
    CONSTRAINT engagement_once_uk UNIQUE (provider, target_resource_urn, employee_id, action),
    -- Never post twice.
    CONSTRAINT engagement_activity_uk UNIQUE (provider, activity_urn)
);

CREATE INDEX engagement_employee_idx ON sharing.engagement (employee_id, occurred_at DESC);
CREATE INDEX engagement_campaign_idx ON sharing.engagement (campaign_id);

CREATE TABLE sharing.engagement_verification (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),
    engagement_id uuid        NOT NULL REFERENCES sharing.engagement (id),
    provider_api  text        NOT NULL CHECK (provider_api IN ('SHARE_ON_LINKEDIN', 'COMMUNITY_MANAGEMENT', 'WEBHOOK')),
    checked_at    timestamptz NOT NULL DEFAULT now(),
    still_exists  boolean     NOT NULL,
    http_status   int
);

CREATE INDEX engagement_verification_engagement_idx ON sharing.engagement_verification (engagement_id, checked_at DESC);

CREATE TABLE sharing.share_request (
    id                  uuid        PRIMARY KEY DEFAULT uuidv7(),
    campaign_id         uuid        NOT NULL,
    employee_id         text        NOT NULL,
    provider            text        NOT NULL CHECK (provider IN ('linkedin')),
    provider_api        text        NOT NULL CHECK (provider_api IN ('SHARE_ON_LINKEDIN')),
    target_resource_urn text        NOT NULL,
    kind                text        NOT NULL CHECK (kind IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY')),
    commentary          text        CHECK (length(commentary) <= 3000),
    requested_at        timestamptz NOT NULL DEFAULT now(),
    published_at        timestamptz,
    failed_at           timestamptz,
    failure_reason      text        CHECK (failure_reason IN ('NEEDS_RECONNECT', 'PROVIDER_REJECTED', 'RETRIES_EXHAUSTED')),
    attempts            int         NOT NULL DEFAULT 1 CHECK (attempts >= 1),
    last_error_code     text,
    engagement_id       uuid        REFERENCES sharing.engagement (id),
    version             int         NOT NULL DEFAULT 1 CHECK (version > 0),
    -- Phase 1: one share per campaign per employee (B3); a retry reuses the row (ADR-015).
    CONSTRAINT share_request_campaign_employee_uk UNIQUE (campaign_id, employee_id),
    CONSTRAINT share_request_published_xor_failed_ck CHECK (published_at IS NULL OR failed_at IS NULL),
    -- Commentary is kept only until published (privacy).
    CONSTRAINT share_request_commentary_cleared_ck CHECK (published_at IS NULL OR commentary IS NULL),
    CONSTRAINT share_request_failure_reason_ck CHECK ((failed_at IS NULL) = (failure_reason IS NULL)),
    CONSTRAINT share_request_engagement_ck CHECK (published_at IS NULL OR engagement_id IS NOT NULL)
);

CREATE INDEX share_request_employee_idx ON sharing.share_request (employee_id, requested_at DESC);

-- Derived status (B14): there is no PENDING share state. Commentary is left out so readers that may
-- not see it (amplify_readonly) can use the view.
CREATE VIEW sharing.share_request_v WITH (security_invoker = true) AS
SELECT sr.id, sr.campaign_id, sr.employee_id, sr.provider, sr.provider_api, sr.target_resource_urn, sr.kind,
       sr.requested_at, sr.published_at, sr.failed_at, sr.failure_reason, sr.attempts, sr.last_error_code,
       sr.engagement_id, sr.version,
       CASE WHEN sr.published_at IS NOT NULL THEN 'PUBLISHED'
            WHEN sr.failed_at IS NOT NULL THEN 'FAILED'
            ELSE 'QUEUED' END AS status
FROM sharing.share_request sr;

CREATE VIEW sharing.engagement_v WITH (security_invoker = true) AS
SELECT e.*,
       CASE WHEN e.deleted_at IS NOT NULL THEN 'DELETED' ELSE 'ACTIVE' END AS status
FROM sharing.engagement e;

GRANT SELECT, INSERT, UPDATE, DELETE ON sharing.share_request, sharing.engagement, sharing.engagement_verification
    TO amplify_api, amplify_jobs;
GRANT SELECT ON sharing.share_request_v, sharing.engagement_v TO amplify_api, amplify_jobs, amplify_readonly;
GRANT SELECT ON sharing.engagement, sharing.engagement_verification TO amplify_readonly;
-- amplify_readonly: every share_request column except commentary.
GRANT SELECT (id, campaign_id, employee_id, provider, provider_api, target_resource_urn, kind, requested_at,
              published_at, failed_at, failure_reason, attempts, last_error_code, engagement_id, version)
    ON sharing.share_request TO amplify_readonly;
