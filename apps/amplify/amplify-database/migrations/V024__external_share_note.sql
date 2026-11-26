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

-- V024: an optional note for the reviewer on an own-post claim (phase 3, "Submit your own post"). The employee
-- writes it; the PO team reads it in the review queue. It is the person's own words, so erasure removes it.

ALTER TABLE external_sharing_external_share
    ADD COLUMN note text CHECK (note IS NULL OR length(note) BETWEEN 1 AND 500);

-- V005 created the view with `es.*`, which PostgreSQL expands once, at creation: recreate it so it carries the
-- new column. Nothing else depends on the view.
DROP VIEW external_sharing_external_share_v;
CREATE VIEW external_sharing_external_share_v WITH (security_invoker = true) AS
SELECT es.*,
       CASE WHEN es.decision IS NULL THEN 'PENDING'
            WHEN es.amplified_at IS NOT NULL THEN 'AMPLIFIED'
            ELSE es.decision END AS status
FROM external_sharing_external_share es;

-- V018's erasure, unchanged except that it also clears the claim notes and reports how many it cleared.
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

    DELETE FROM connection_provider_token WHERE owner_type = 'MEMBER' AND owner_id = p_employee_id;
    GET DIAGNOSTICS v_tokens = ROW_COUNT;
    DELETE FROM connection_member_connection WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_connections = ROW_COUNT;
    DELETE FROM connection_oauth_state WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_states = ROW_COUNT;
    DELETE FROM connection_linkedin_consent WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_consents = ROW_COUNT;
    DELETE FROM messaging_idempotency_key WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_idempotency = ROW_COUNT;

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
        'engagements', v_engagements, 'claimNotes', v_notes, 'employee', v_employee, 'standings', v_standings);

    INSERT INTO audit_log (actor_id, actor_roles, action, entity_type, entity_id, outcome, after, reason)
    VALUES (p_actor, ARRAY[session_user::text], 'EMPLOYEE_DATA_ERASED', 'employee', p_employee_id, 'SUCCESS',
            v_result || jsonb_build_object('calledBy', session_user), p_reason);
    RETURN v_result;
END
$fn$;

COMMENT ON FUNCTION identity_erase_employee(text, text, text) IS
    'Erases an employee''s personal data and keeps the pseudonymous ledger. Called by the leaver sweep and the manual runbook.';

REVOKE ALL ON FUNCTION identity_erase_employee(text, text, text) FROM PUBLIC;
