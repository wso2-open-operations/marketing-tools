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

-- V028: post reach from the LinkedIn member post analytics API (#1781) and the SLT reports (#1780).
--   connection_member_analytics  an employee's "Reach" connection: their consent, through the Community Management
--                                app, to Amplify reading the analytics of their own posts (scope
--                                r_member_postAnalytics only). Token pointers into connection_provider_token with
--                                the new owner type MEMBER_ANALYTICS (owner_id = employee id). Disconnect deletes the
--                                row and its tokens, so there is no revoked state
--   sharing_engagement_metric    the reach of an in-app share: impressions and members reached of the employee's
--                                own post, the latest value per post per UTC day (phase1-data-model's future
--                                engagement_metric, without reactions/comments/reposts: those are synced engagements)
-- connection_oauth_state gets a purpose: CONNECT (the member's Share on LinkedIn connection), PAGE (an admin
-- connecting the company page) or REACH (the member's Reach connection). Each flow refuses the others' states.
--
-- Erasure (identity_erase_employee) also deletes the Reach connection and its tokens. The metrics stay: post URNs
-- the share request already holds, counters and the pseudonymous engagement id, like the ledger.

ALTER TABLE connection_oauth_state
    ADD COLUMN purpose text NOT NULL DEFAULT 'CONNECT' CHECK (purpose IN ('CONNECT', 'PAGE', 'REACH'));
-- A page state issued before this migration (10 minutes at most) carries COMMUNITY_MANAGEMENT.
UPDATE connection_oauth_state SET purpose = 'PAGE' WHERE provider_api = 'COMMUNITY_MANAGEMENT';

ALTER TABLE connection_provider_token DROP CONSTRAINT connection_provider_token_owner_type_check;
ALTER TABLE connection_provider_token ADD CONSTRAINT connection_provider_token_owner_type_check
    CHECK (owner_type IN ('MEMBER', 'ORG', 'MEMBER_ANALYTICS'));

CREATE TABLE connection_member_analytics (
    -- identity_employee.employee_id (virtual FK, ADR-005)
    employee_id             text        PRIMARY KEY,
    provider                text        NOT NULL CHECK (provider IN ('linkedin')),
    provider_api            text        NOT NULL CHECK (provider_api IN ('COMMUNITY_MANAGEMENT')),
    scopes                  text[]      NOT NULL DEFAULT '{}',
    access_token_id         uuid        NOT NULL,
    access_token_issued_on  date        NOT NULL,
    refresh_token_id        uuid,
    refresh_token_issued_on date,
    access_expires_at       timestamptz NOT NULL,
    refresh_expires_at      timestamptz,
    connected_at            timestamptz NOT NULL,
    version                 int         NOT NULL DEFAULT 1 CHECK (version > 0),
    CONSTRAINT member_analytics_refresh_ref_ck CHECK ((refresh_token_id IS NULL) = (refresh_token_issued_on IS NULL)),
    CONSTRAINT member_analytics_refresh_expiry_ck CHECK (refresh_token_id IS NULL OR refresh_expires_at IS NOT NULL)
);

CREATE TABLE sharing_engagement_metric (
    -- The in-app share whose post was measured (same context, a real FK)
    engagement_id   uuid        NOT NULL REFERENCES sharing_engagement (id),
    -- UTC day of the reading; a later reading the same day replaces it
    captured_on     date        NOT NULL,
    provider_api    text        NOT NULL CHECK (provider_api IN ('COMMUNITY_MANAGEMENT')),
    -- The employee's post (sharing_engagement.activity_urn at the time)
    post_urn        text        NOT NULL CHECK (post_urn LIKE 'urn:li:%' AND length(post_urn) <= 255),
    impressions     int         NOT NULL CHECK (impressions >= 0),
    members_reached int         NOT NULL CHECK (members_reached >= 0),
    fetched_at      timestamptz NOT NULL,
    PRIMARY KEY (engagement_id, captured_on)
);

-- V026's erasure, unchanged except that it also deletes the Reach connection and its tokens (owner MEMBER_ANALYTICS)
-- and reports how many it deleted (reachConnections; the tokens count in tokens).
CREATE OR REPLACE FUNCTION identity_erase_employee(p_employee_id text, p_actor text, p_reason text)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path FROM CURRENT
AS $fn$
DECLARE
    v_tokens       int;
    v_connections  int;
    v_states       int;
    v_consents     int;
    v_idempotency  int;
    v_commentary   int;
    v_engagements  int;
    v_notes        int;
    v_wallets      int;
    v_reach        int;
    v_employee     int;
    v_standings    int;
    v_result       jsonb;
BEGIN
    IF p_employee_id IS NULL OR length(p_employee_id) = 0 THEN
        RAISE EXCEPTION 'employee id is required';
    END IF;
    IF p_actor IS NULL OR length(p_actor) = 0 THEN
        RAISE EXCEPTION 'actor is required';
    END IF;

    DELETE FROM connection_provider_token
     WHERE owner_type IN ('MEMBER', 'MEMBER_ANALYTICS') AND owner_id = p_employee_id;
    GET DIAGNOSTICS v_tokens = ROW_COUNT;
    DELETE FROM connection_member_connection WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_connections = ROW_COUNT;
    DELETE FROM connection_member_analytics WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_reach = ROW_COUNT;
    DELETE FROM connection_oauth_state WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_states = ROW_COUNT;
    DELETE FROM connection_linkedin_consent WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_consents = ROW_COUNT;
    DELETE FROM messaging_idempotency_key WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_idempotency = ROW_COUNT;
    DELETE FROM scoring_coin_wallet WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_wallets = ROW_COUNT;

    UPDATE sharing_share_request SET commentary = NULL WHERE employee_id = p_employee_id AND commentary IS NOT NULL;
    GET DIAGNOSTICS v_commentary = ROW_COUNT;
    UPDATE sharing_engagement SET actor_member_urn = 'urn:li:person:erased'
        WHERE employee_id = p_employee_id AND actor_member_urn <> 'urn:li:person:erased';
    GET DIAGNOSTICS v_engagements = ROW_COUNT;
    UPDATE external_sharing_external_share SET note = NULL WHERE employee_id = p_employee_id AND note IS NOT NULL;
    GET DIAGNOSTICS v_notes = ROW_COUNT;

    -- identity_employee.email is NOT NULL and UNIQUE: a placeholder that cannot collide and cannot be mistaken for
    -- an address (.invalid is reserved, RFC 6761). The person signing in again would overwrite it.
    UPDATE identity_employee
       SET email = 'erased-' || substr(md5(employee_id), 1, 16) || '@amplify.invalid',
           display_name = 'Former participant'
     WHERE employee_id = p_employee_id
       AND (display_name <> 'Former participant' OR email NOT LIKE 'erased-%@amplify.invalid');
    GET DIAGNOSTICS v_employee = ROW_COUNT;
    UPDATE recognition_standing SET email = NULL, display_name = 'Former participant'
     WHERE employee_id = p_employee_id AND (email IS NOT NULL OR display_name <> 'Former participant');
    GET DIAGNOSTICS v_standings = ROW_COUNT;

    v_result := jsonb_build_object('tokens', v_tokens, 'connections', v_connections, 'oauthStates', v_states,
        'consents', v_consents, 'idempotencyKeys', v_idempotency, 'commentary', v_commentary,
        'engagements', v_engagements, 'claimNotes', v_notes, 'coinWallets', v_wallets, 'reachConnections', v_reach, 'employee', v_employee,
        'standings', v_standings);

    INSERT INTO audit_log (actor_id, actor_roles, action, entity_type, entity_id, outcome, after, reason)
    VALUES (p_actor, ARRAY[session_user::text], 'EMPLOYEE_DATA_ERASED', 'employee', p_employee_id, 'SUCCESS',
            v_result || jsonb_build_object('calledBy', session_user), p_reason);
    RETURN v_result;
END
$fn$;

COMMENT ON FUNCTION identity_erase_employee(text, text, text) IS
    'Erases an employee''s personal data and keeps the pseudonymous ledger. Called by the leaver sweep and the manual runbook.';

REVOKE ALL ON FUNCTION identity_erase_employee(text, text, text) FROM PUBLIC;
