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

-- V008: S5 Announcements and the infrastructure schemas: messaging (outbox, idempotency), audit
-- (monthly partitions, 5-year retention, B17) and config (app_setting).

SET LOCAL ROLE amplify_migrate;

-- ---- announcement --------------------------------------------------------------------------------

-- PK = campaign_id: a campaign is announced exactly once.
CREATE TABLE announcement.announcement (
    campaign_id       uuid        PRIMARY KEY,
    outbox_id         bigint,
    space             text        NOT NULL CHECK (length(space) BETWEEN 1 AND 100),
    thread_key        text        NOT NULL,
    chat_message_name text,
    queued_at         timestamptz NOT NULL DEFAULT now(),
    sent_at           timestamptz,
    failed_at         timestamptz,
    last_error        text        CHECK (length(last_error) <= 1000),
    CONSTRAINT announcement_sent_xor_failed_ck CHECK (sent_at IS NULL OR failed_at IS NULL)
);

CREATE INDEX announcement_failed_idx ON announcement.announcement (failed_at) WHERE failed_at IS NOT NULL;

CREATE VIEW announcement.announcement_v WITH (security_invoker = true) AS
SELECT a.*,
       CASE WHEN a.sent_at IS NOT NULL THEN 'SENT'
            WHEN a.failed_at IS NOT NULL THEN 'FAILED'
            ELSE 'QUEUED' END AS status
FROM announcement.announcement a;

GRANT SELECT ON announcement.announcement, announcement.announcement_v TO amplify_api, amplify_readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON announcement.announcement TO amplify_jobs;
GRANT SELECT ON announcement.announcement_v TO amplify_jobs;

-- ---- messaging -----------------------------------------------------------------------------------

-- Written in the producer's transaction; claimed by amplify-jobs with FOR UPDATE SKIP LOCKED.
-- bigint identity: strict queue order matters more than global uniqueness.
CREATE TABLE messaging.outbox (
    id              bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aggregate_type  text        NOT NULL,
    aggregate_id    text        NOT NULL,
    event_type      text        NOT NULL,
    payload         jsonb       NOT NULL,
    idempotency_key text        NOT NULL,
    status          text        NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'IN_PROGRESS', 'DONE', 'FAILED')),
    attempts        int         NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    locked_by       text,
    locked_until    timestamptz,
    last_error      text        CHECK (length(last_error) <= 1000),
    correlation_id  text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    processed_at    timestamptz,
    CONSTRAINT outbox_idempotency_uk UNIQUE (idempotency_key),
    CONSTRAINT outbox_done_processed_ck CHECK (status <> 'DONE' OR processed_at IS NOT NULL)
);

CREATE INDEX outbox_pending_idx ON messaging.outbox (next_attempt_at) WHERE status = 'PENDING';
CREATE INDEX outbox_done_idx ON messaging.outbox (processed_at) WHERE status = 'DONE';

CREATE TABLE messaging.idempotency_key (
    employee_id     text        NOT NULL,
    key             text        NOT NULL CHECK (length(key) BETWEEN 1 AND 255),
    request_hash    text        NOT NULL,
    response_status int,
    response_body   jsonb,
    created_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz NOT NULL,
    PRIMARY KEY (employee_id, key)
);

CREATE INDEX idempotency_key_expires_idx ON messaging.idempotency_key (expires_at);

GRANT SELECT, INSERT, UPDATE, DELETE ON messaging.outbox, messaging.idempotency_key TO amplify_api, amplify_jobs;

-- ---- audit ---------------------------------------------------------------------------------------

-- Append-only, monthly RANGE partitions on `at` (UTC month), retained 60 months (B17).
CREATE TABLE audit.audit_log (
    id             uuid        NOT NULL DEFAULT uuidv7(),
    at             timestamptz NOT NULL DEFAULT now(),
    actor_id       text        NOT NULL,
    actor_roles    text[]      NOT NULL DEFAULT '{}',
    action         text        NOT NULL,
    entity_type    text        NOT NULL,
    entity_id      text,
    outcome        text        NOT NULL CHECK (outcome IN ('SUCCESS', 'DENIED', 'FAILED')),
    before         jsonb,
    after          jsonb,
    reason         text,
    correlation_id text,
    PRIMARY KEY (id, at)
) PARTITION BY RANGE (at);

CREATE INDEX audit_log_entity_idx ON audit.audit_log (entity_type, entity_id, at DESC);
CREATE INDEX audit_log_actor_idx ON audit.audit_log (actor_id, at DESC);

GRANT SELECT, INSERT ON audit.audit_log TO amplify_api, amplify_jobs;

-- ---- config --------------------------------------------------------------------------------------

CREATE TABLE config.app_setting (
    key        text        PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
    value      jsonb       NOT NULL,
    updated_by text        NOT NULL DEFAULT 'system',
    updated_at timestamptz NOT NULL DEFAULT now(),
    version    int         NOT NULL DEFAULT 1 CHECK (version > 0)
);

GRANT SELECT, INSERT, UPDATE ON config.app_setting TO amplify_api;
GRANT SELECT ON config.app_setting TO amplify_jobs;
