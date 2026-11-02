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

-- V003: S2 Connection (phase1-data-model › connection, ADR-002).
-- `org_connection` is a future phase (Community Management) and isn't created here.

SET LOCAL ROLE amplify_migrate;

CREATE TABLE connection.member_connection (
    employee_id             text        NOT NULL,
    provider                text        NOT NULL CHECK (provider IN ('linkedin')),
    member_urn              text        NOT NULL CHECK (member_urn LIKE 'urn:li:person:%'),
    provider_api            text        NOT NULL CHECK (provider_api IN ('SHARE_ON_LINKEDIN', 'COMMUNITY_MANAGEMENT')),
    scopes                  text[]      NOT NULL DEFAULT '{}',
    current_token_id        uuid,
    current_token_issued_on date,
    access_expires_at       timestamptz NOT NULL,
    connected_at            timestamptz NOT NULL,
    revoked_at              timestamptz,
    removed_at              timestamptz,
    last_reminded_at        timestamptz,
    version                 int         NOT NULL DEFAULT 1 CHECK (version > 0),
    PRIMARY KEY (employee_id, provider),
    -- One employee per provider member (B13).
    CONSTRAINT member_connection_member_uk UNIQUE (provider, member_urn),
    -- The token pointer is both parts or neither (virtual FK into a partition, so no physical FK).
    CONSTRAINT member_connection_token_ref_ck CHECK ((current_token_id IS NULL) = (current_token_issued_on IS NULL)),
    CONSTRAINT member_connection_removed_no_token_ck CHECK (removed_at IS NULL OR current_token_id IS NULL)
);

-- Encrypted tokens, one RANGE partition per UTC day of issue (ADR-002). PK holds the partition key.
-- No FK points here on purpose: Postgres won't drop a partition a foreign key points into.
CREATE TABLE connection.provider_token (
    token_id   uuid        NOT NULL DEFAULT uuidv7(),
    issued_on  date        NOT NULL DEFAULT (now() AT TIME ZONE 'UTC')::date,
    owner_type text        NOT NULL CHECK (owner_type IN ('MEMBER', 'ORG')),
    owner_id   text        NOT NULL,
    provider   text        NOT NULL CHECK (provider IN ('linkedin')),
    token_kind text        NOT NULL CHECK (token_kind IN ('ACCESS', 'REFRESH')),
    ciphertext bytea       NOT NULL,
    nonce      bytea       NOT NULL CHECK (octet_length(nonce) = 12),
    key_id     text        NOT NULL CHECK (length(key_id) BETWEEN 1 AND 64),
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (token_id, issued_on)
) PARTITION BY RANGE (issued_on);

CREATE INDEX provider_token_owner_idx ON connection.provider_token (owner_id, provider);

CREATE TABLE connection.oauth_state (
    state               text        PRIMARY KEY CHECK (length(state) BETWEEN 32 AND 128),
    employee_id         text        NOT NULL,
    provider            text        NOT NULL CHECK (provider IN ('linkedin')),
    provider_api        text        NOT NULL CHECK (provider_api IN ('SHARE_ON_LINKEDIN', 'COMMUNITY_MANAGEMENT')),
    nonce               text        NOT NULL,
    return_to           text,
    pending_campaign_id uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    expires_at          timestamptz NOT NULL,
    CHECK (expires_at > created_at)
);

CREATE INDEX oauth_state_expires_idx ON connection.oauth_state (expires_at);

-- Integer setting with a default. PL/pgSQL so the body isn't bound at create time: `config.app_setting`
-- arrives in V008, and the view below needs `connection.reminder_days`.
CREATE FUNCTION config.int_setting(p_key text, p_default int)
    RETURNS int
    LANGUAGE plpgsql
    STABLE
AS $fn$
DECLARE
    v_value int;
BEGIN
    SELECT (s.value #>> '{}')::int INTO v_value FROM config.app_setting s WHERE s.key = p_key;
    RETURN COALESCE(v_value, p_default);
END
$fn$;

REVOKE ALL ON FUNCTION config.int_setting(text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.int_setting(text, int) TO amplify_api, amplify_jobs;

-- Derived status (B14). NEEDS_RECONNECT also when the token row is gone (partition dropped, or deleted).
CREATE VIEW connection.member_connection_v WITH (security_invoker = true) AS
SELECT mc.*,
       CASE WHEN mc.removed_at IS NOT NULL THEN 'REMOVED'
            WHEN mc.revoked_at IS NOT NULL AND mc.revoked_at > mc.connected_at THEN 'NEEDS_RECONNECT'
            WHEN mc.access_expires_at <= now() THEN 'NEEDS_RECONNECT'
            WHEN mc.current_token_id IS NULL THEN 'NEEDS_RECONNECT'
            WHEN NOT EXISTS (SELECT 1
                             FROM connection.provider_token t
                             WHERE t.token_id = mc.current_token_id
                               AND t.issued_on = mc.current_token_issued_on) THEN 'NEEDS_RECONNECT'
            WHEN mc.access_expires_at - make_interval(days => config.int_setting('connection.reminder_days', 7))
                    <= now() THEN 'EXPIRING'
            ELSE 'ACTIVE' END AS status
FROM connection.member_connection mc;

-- amplify_readonly gets nothing in this schema (tokens and member URNs stay private).
GRANT SELECT, INSERT, UPDATE, DELETE ON connection.member_connection, connection.provider_token,
    connection.oauth_state TO amplify_api, amplify_jobs;
GRANT SELECT ON connection.member_connection_v TO amplify_api, amplify_jobs;
