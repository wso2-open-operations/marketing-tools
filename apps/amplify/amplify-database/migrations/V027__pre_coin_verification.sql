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
-- V027: pre-coin verification (Task #1767, ADR-048 amendment). Before Coins are paid, the LinkedIn activity behind
-- every HELD engagement row is checked again. Scoring context, plus one sharing check widened.
--   scoring_points_ledger  verification, verified_at, verification_reason: the last outcome of that check.
--                          VERIFIED      the activity was still there at verified_at; the conversion takes the row
--                                        only while verified_at is within coin.verify_max_age_hours
--                          REMOVED       it was gone; the row is reversed ("No longer on LinkedIn") in the same
--                                        transaction, and the pair nets to zero
--                          UNVERIFIABLE  it could not be checked (no usable token, the token may not read it, no URN);
--                                        the row is set action required (status NULL) for the PO team
--                          PO_CLEARED    a PO set the row HELD again by hand; it converts without another check
--   sharing_api_usage      also counts the member-token reads (SHARE_ON_LINKEDIN) against their own daily budget
--                          (coin.verify_member_daily_call_budget); the page-token reads stay on COMMUNITY_MANAGEMENT
--                          and engagement.daily_call_budget.
-- The outcome of each check that got an answer is also kept on the sharing side, in the V004 tables
-- (sharing_engagement_verification, sharing_engagement.last_verified_at / deleted_at); scoring never reads them
-- (ADR-005): amplify-jobs joins the two contexts through their repositories.
--
-- Erasure (identity_erase_employee) is unchanged: the new columns hold an outcome, a time and a reason code only.

ALTER TABLE scoring_points_ledger
    ADD COLUMN verification        text        CHECK (verification IN ('VERIFIED', 'REMOVED', 'UNVERIFIABLE', 'PO_CLEARED')),
    ADD COLUMN verified_at         timestamptz,
    ADD COLUMN verification_reason text        CHECK (verification_reason IS NULL
                                                      OR length(verification_reason) BETWEEN 1 AND 64);

ALTER TABLE scoring_points_ledger
    ADD CONSTRAINT points_ledger_verified_at_ck CHECK ((verification IS NULL) = (verified_at IS NULL)),
    ADD CONSTRAINT points_ledger_verification_reason_ck
        CHECK (verification_reason IS NULL OR verification = 'UNVERIFIABLE');

-- What the next verification run reads: engagement rows the conversion could still take, never checked first.
CREATE INDEX points_ledger_verify_idx ON scoring_points_ledger (verified_at NULLS FIRST, created_at)
    WHERE source_type = 'ENGAGEMENT' AND status = 'HELD' AND coin_reference IS NULL;

-- V026's guard, plus the three verification columns among those that may change. A PAID row stays final.
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
    IF (to_jsonb(NEW) - 'status' - 'status_changed_at' - 'paid_at' - 'coin_reference'
                      - 'verification' - 'verified_at' - 'verification_reason')
            IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'status_changed_at' - 'paid_at' - 'coin_reference'
                      - 'verification' - 'verified_at' - 'verification_reason') THEN
        RAISE EXCEPTION 'scoring_points_ledger is append-only: only the settlement and verification columns may change (reference %)',
            OLD.reference USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF OLD.status = 'PAID' AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
        RAISE EXCEPTION 'scoring_points_ledger: a PAID row is final (reference %)', OLD.reference
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END
$fn$;

ALTER TABLE sharing_api_usage DROP CONSTRAINT sharing_api_usage_provider_api_check;
ALTER TABLE sharing_api_usage ADD CONSTRAINT sharing_api_usage_provider_api_check
    CHECK (provider_api IN ('COMMUNITY_MANAGEMENT', 'SHARE_ON_LINKEDIN'));
