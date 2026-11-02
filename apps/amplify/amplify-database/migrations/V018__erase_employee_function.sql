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

-- V018: one audited way to erase an employee's personal data (security review). It replaces the hand-written
-- template in the interim deletion runbook, which tried to set identity.employee.email to NULL (the column is
-- NOT NULL UNIQUE) and never removed the LinkedIn member URN. The worker's leaver sweep and the manual runbook both
-- call it, so both erase exactly the same things.
--
-- Removed or replaced:
--   * the LinkedIn connection row (the member URN lives there), its tokens, any OAuth state in flight;
--   * the consent record, with the profile URL the person typed;
--   * idempotency keys, repost commentary, the member URN stored on each engagement;
--   * name and email on identity.employee (a unique placeholder: the columns are NOT NULL) and on recognition.standing.
-- Kept, keyed only by the pseudonymous employee id: the points ledger, engagements, external shares, audit rows and
-- the monthly totals, so the leaderboard arithmetic and the audit trail stay intact. Backups keep the old data
-- until their retention ends.
--
-- Not removed, and why:
--   * The LinkedIn member URN also sits in audit.audit_log (before/after of connection events; the log is append-only
--     and kept 60 months) and in messaging.outbox (payload and idempotency key) until the purge of DONE rows. Erasing
--     those would break the audit trail or the idempotency guard, so the URN is kept there until retention removes it.
--     Legal / Privacy should confirm that is acceptable.
--   * The tokens are deleted here but not revoked at LinkedIn: they stay valid there until they expire. When the person
--     is still reachable, Remove Connection (Me > Settings) revokes first.
--   * external_sharing.external_share keeps the post URLs the person submitted, keyed by the pseudonymous id.
--
-- The audit row records who called it (session_user) next to the actor the caller names, so a caller cannot pass
-- itself off as someone else. Safe to run twice: a second call changes nothing and reports zeros.

SET LOCAL ROLE amplify_migrate;

CREATE FUNCTION identity.erase_employee(p_employee_id text, p_actor text, p_reason text)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_tokens       int;
    v_connections  int;
    v_states       int;
    v_consents     int;
    v_idempotency  int;
    v_commentary   int;
    v_engagements  int;
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

    DELETE FROM connection.provider_token WHERE owner_type = 'MEMBER' AND owner_id = p_employee_id;
    GET DIAGNOSTICS v_tokens = ROW_COUNT;
    DELETE FROM connection.member_connection WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_connections = ROW_COUNT;
    DELETE FROM connection.oauth_state WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_states = ROW_COUNT;
    DELETE FROM connection.linkedin_consent WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_consents = ROW_COUNT;
    DELETE FROM messaging.idempotency_key WHERE employee_id = p_employee_id;
    GET DIAGNOSTICS v_idempotency = ROW_COUNT;

    UPDATE sharing.share_request SET commentary = NULL WHERE employee_id = p_employee_id AND commentary IS NOT NULL;
    GET DIAGNOSTICS v_commentary = ROW_COUNT;
    UPDATE sharing.engagement SET actor_member_urn = 'urn:li:person:erased'
        WHERE employee_id = p_employee_id AND actor_member_urn <> 'urn:li:person:erased';
    GET DIAGNOSTICS v_engagements = ROW_COUNT;

    -- identity.employee.email is NOT NULL and UNIQUE: a placeholder that cannot collide and cannot be mistaken for
    -- an address (.invalid is reserved, RFC 6761). The person signing in again would overwrite it.
    UPDATE identity.employee
       SET email = 'erased-' || substr(md5(employee_id), 1, 16) || '@amplify.invalid',
           display_name = 'Former participant'
     WHERE employee_id = p_employee_id
       AND (display_name <> 'Former participant' OR email NOT LIKE 'erased-%@amplify.invalid');
    GET DIAGNOSTICS v_employee = ROW_COUNT;
    UPDATE recognition.standing SET email = NULL, display_name = 'Former participant'
     WHERE employee_id = p_employee_id AND (email IS NOT NULL OR display_name <> 'Former participant');
    GET DIAGNOSTICS v_standings = ROW_COUNT;

    v_result := jsonb_build_object('tokens', v_tokens, 'connections', v_connections, 'oauthStates', v_states,
        'consents', v_consents, 'idempotencyKeys', v_idempotency, 'commentary', v_commentary,
        'engagements', v_engagements, 'employee', v_employee, 'standings', v_standings);

    INSERT INTO audit.audit_log (actor_id, actor_roles, action, entity_type, entity_id, outcome, after, reason)
    VALUES (p_actor, ARRAY[session_user::text], 'EMPLOYEE_DATA_ERASED', 'employee', p_employee_id, 'SUCCESS',
            v_result || jsonb_build_object('calledBy', session_user), p_reason);
    RETURN v_result;
END
$fn$;

COMMENT ON FUNCTION identity.erase_employee(text, text, text) IS
    'Erases an employee''s personal data and keeps the pseudonymous ledger. Called by the leaver sweep and the manual runbook.';

REVOKE ALL ON FUNCTION identity.erase_employee(text, text, text) FROM PUBLIC;
-- The worker sweeps leavers. The API never erases: a person asking to be removed goes through the runbook.
GRANT EXECUTE ON FUNCTION identity.erase_employee(text, text, text) TO amplify_jobs;
