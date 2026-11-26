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

-- V026: automatic Coins conversion through the WSO2 Coins transaction service (phase 2, ADR-048). Scoring context.
--   scoring_coin_wallet  the wallet an employee captured on Amplify (from the Coins service's GET /wallets/me)
--   scoring_coin_run     one conversion run per period (2026-12 monthly, 2026-W49 weekly, 2026-12-01 daily)
--   scoring_coin_issue   what one employee got in one run: points and carry in, Coins, carry out, our reference, the
--                        service's transfer reference and the delivery state
-- Ledger rows can now become PAID: V006's phase 1 check goes. A PAID row names the issue that paid it
-- (coin_reference) and is never edited again (the V021 guard is tightened below).
--
-- Erasure (identity_erase_employee) also deletes the captured wallet. The issue rows stay, keyed by the pseudonymous
-- employee id like the ledger: they hold the wallet address a transfer went to (the Coins service keeps the same in
-- its own ledger), needed to reconcile a transfer whose outcome is unknown.

ALTER TABLE scoring_points_ledger DROP CONSTRAINT points_ledger_no_paid_phase1_ck;

-- A PAID row says which conversion paid it.
ALTER TABLE scoring_points_ledger
    ADD CONSTRAINT points_ledger_paid_coin_ck CHECK (status IS DISTINCT FROM 'PAID' OR coin_reference IS NOT NULL);

-- What the next conversion may take, and the rows one issue tagged.
CREATE INDEX points_ledger_convertible_idx ON scoring_points_ledger (employee_id)
    WHERE status = 'HELD' AND coin_reference IS NULL;
CREATE INDEX points_ledger_coin_reference_idx ON scoring_points_ledger (coin_reference)
    WHERE coin_reference IS NOT NULL;

-- V021's guard, plus: a PAID row is final. Its points became Coins, so no settlement column moves again; a correction
-- is a new ADJ-/REV- row, which the next conversion counts.
CREATE OR REPLACE FUNCTION scoring_points_ledger_guard()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path FROM CURRENT
AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'scoring_points_ledger is append-only: a row is never deleted (reference %)', OLD.reference
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF (to_jsonb(NEW) - 'status' - 'status_changed_at' - 'paid_at' - 'coin_reference')
            IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'status_changed_at' - 'paid_at' - 'coin_reference') THEN
        RAISE EXCEPTION 'scoring_points_ledger is append-only: only status, status_changed_at, paid_at and coin_reference may change (reference %)',
            OLD.reference USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF OLD.status = 'PAID' AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
        RAISE EXCEPTION 'scoring_points_ledger: a PAID row is final (reference %)', OLD.reference
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END
$fn$;

CREATE TABLE scoring_coin_wallet (
    -- identity_employee.employee_id (virtual FK, ADR-005)
    employee_id    text        PRIMARY KEY,
    -- The Coins wallet the transfers go to: the employee's default wallet, else their first
    wallet_address text        NOT NULL CHECK (length(wallet_address) BETWEEN 1 AND 128),
    captured_at    timestamptz NOT NULL,
    updated_at     timestamptz NOT NULL
);

CREATE TABLE scoring_coin_run (
    id             uuid        PRIMARY KEY DEFAULT uuidv7(),
    period         text        NOT NULL CHECK (period ~ '^[0-9]{4}-([0-9]{2}|W[0-9]{2}|[0-9]{2}-[0-9]{2})$'),
    -- RUNNING while a run is in it; DONE, PARTIAL (stopped at the time limit) or STOPPED (stop_reason says why)
    status         text        NOT NULL CHECK (status IN ('RUNNING', 'DONE', 'PARTIAL', 'STOPPED')),
    stop_reason    text        CHECK (stop_reason IS NULL OR length(stop_reason) BETWEEN 1 AND 64),
    started_at     timestamptz NOT NULL,
    finished_at    timestamptz,
    -- Totals over the period's issues, refreshed at the end of every run of the period
    issues_sent    int         NOT NULL DEFAULT 0 CHECK (issues_sent >= 0),
    coins_sent     bigint      NOT NULL DEFAULT 0 CHECK (coins_sent >= 0),
    issues_failed  int         NOT NULL DEFAULT 0 CHECK (issues_failed >= 0),
    issues_unknown int         NOT NULL DEFAULT 0 CHECK (issues_unknown >= 0),
    issues_skipped int         NOT NULL DEFAULT 0 CHECK (issues_skipped >= 0),
    CONSTRAINT coin_run_period_uk UNIQUE (period),
    CONSTRAINT coin_run_stop_reason_ck CHECK ((status = 'STOPPED') = (stop_reason IS NOT NULL))
);

CREATE TABLE scoring_coin_issue (
    id                 uuid        PRIMARY KEY DEFAULT uuidv7(),
    run_id             uuid        NOT NULL REFERENCES scoring_coin_run (id),
    -- identity_employee.employee_id (virtual FK, ADR-005)
    employee_id        text        NOT NULL,
    -- HELD ledger rows this issue took (their sum; reversals count negative)
    points_in          int         NOT NULL,
    -- carry_out of the employee's last SENT issue
    carry_in           int         NOT NULL CHECK (carry_in >= 0),
    coins              int         NOT NULL CHECK (coins >= 0),
    carry_out          int         NOT NULL CHECK (carry_out >= 0),
    -- The rate used (coin.block_points, coin.block_coins at the time)
    block_points       int         NOT NULL CHECK (block_points > 0),
    block_coins        int         NOT NULL CHECK (block_coins > 0),
    -- Where the Coins go; NULL only when the employee had no captured wallet
    wallet_address     text        CHECK (wallet_address IS NULL OR length(wallet_address) BETWEEN 1 AND 128),
    -- Ours, set on the ledger rows as coin_reference; the Coins service takes no caller reference (ADR-048)
    reference          text        NOT NULL CHECK (reference ~ '^CNV-' AND length(reference) <= 66),
    -- The Coins service's reference for the transfer, once known
    transfer_reference text        CHECK (transfer_reference IS NULL OR length(transfer_reference) BETWEEN 1 AND 128),
    status             text        NOT NULL CHECK (status IN ('PENDING', 'SENT', 'FAILED', 'UNKNOWN', 'SKIPPED_NO_WALLET')),
    attempts           int         NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_error_code    text        CHECK (last_error_code IS NULL OR length(last_error_code) BETWEEN 1 AND 64),
    -- FAILED: not retried in the same period before this time
    next_attempt_at    timestamptz,
    -- When the last transfer call started (the reconcile searches from here)
    attempted_at       timestamptz,
    sent_at            timestamptz,
    created_at         timestamptz NOT NULL,
    updated_at         timestamptz NOT NULL,
    CONSTRAINT coin_issue_run_employee_uk UNIQUE (run_id, employee_id),
    CONSTRAINT coin_issue_reference_uk UNIQUE (reference),
    CONSTRAINT coin_issue_transfer_reference_uk UNIQUE (transfer_reference),
    -- Whole blocks only, and the points add up: carry in + points in = blocks x block_points + carry out.
    CONSTRAINT coin_issue_blocks_ck CHECK (coins % block_coins = 0
                                           AND carry_in + points_in = (coins / block_coins) * block_points + carry_out),
    CONSTRAINT coin_issue_sent_ck CHECK ((status = 'SENT') = (transfer_reference IS NOT NULL AND sent_at IS NOT NULL)),
    CONSTRAINT coin_issue_wallet_ck CHECK ((status = 'SKIPPED_NO_WALLET') = (wallet_address IS NULL)),
    CONSTRAINT coin_issue_coins_ck CHECK (coins > 0)
);

-- The reconcile pass reads the open issues of every period; the carry-in reads an employee's latest SENT issue.
CREATE INDEX coin_issue_open_idx ON scoring_coin_issue (attempted_at) WHERE status IN ('PENDING', 'UNKNOWN');
CREATE INDEX coin_issue_employee_idx ON scoring_coin_issue (employee_id, created_at DESC);

-- V024's erasure, unchanged except that it also deletes the captured Coins wallet and reports how many it deleted.
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
        'engagements', v_engagements, 'claimNotes', v_notes, 'coinWallets', v_wallets, 'employee', v_employee,
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
