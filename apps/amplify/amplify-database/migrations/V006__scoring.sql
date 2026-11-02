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

-- V006: C2 Scoring and the points ledger (phase1-data-model › scoring, C1, C4).

SET LOCAL ROLE amplify_migrate;

CREATE TABLE scoring.point_rule (
    id             uuid        PRIMARY KEY DEFAULT uuidv7(),
    action         text        NOT NULL CHECK (action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY',
                                                         'OWN_POST', 'OWN_POST_AMPLIFIED')),
    points         int         NOT NULL CHECK (points >= 0),
    effective_from timestamptz NOT NULL,
    created_by     text        NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT point_rule_version_uk UNIQUE (action, effective_from)
);

-- Append-only facts. Only the settlement columns are updatable (column grants below).
CREATE TABLE scoring.points_ledger (
    reference          varchar(66) PRIMARY KEY CHECK (reference ~ '^(AMP|ADJ|REV)-'),
    employee_id        text        NOT NULL,
    campaign_id        uuid,
    source_type        text        NOT NULL CHECK (source_type IN ('ENGAGEMENT', 'EXTERNAL_SHARE', 'ADJUSTMENT', 'REVERSAL')),
    source_id          uuid,
    action             text        CHECK (action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY',
                                                     'OWN_POST', 'OWN_POST_AMPLIFIED')),
    points             int         NOT NULL,
    rule_id            uuid        REFERENCES scoring.point_rule (id),
    reverses_reference varchar(66) REFERENCES scoring.points_ledger (reference),
    reason             text,
    actor_id           text        NOT NULL,
    correlation_id     text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    status             text        DEFAULT 'HELD' CHECK (status IN ('HELD', 'PAID')),
    status_changed_at  timestamptz,
    paid_at            timestamptz,
    coin_reference     text,
    -- A row is reversed at most once.
    CONSTRAINT points_ledger_reverses_uk UNIQUE (reverses_reference),
    -- ADJ/REV carry a reason (ADR-010).
    CONSTRAINT points_ledger_reason_ck CHECK (source_type IN ('ENGAGEMENT', 'EXTERNAL_SHARE') OR reason IS NOT NULL),
    -- Awards are priced by a rule and point at their source; corrections are not.
    CONSTRAINT points_ledger_award_ck CHECK (source_type NOT IN ('ENGAGEMENT', 'EXTERNAL_SHARE')
                                             OR (rule_id IS NOT NULL AND source_id IS NOT NULL AND action IS NOT NULL)),
    CONSTRAINT points_ledger_reversal_ck CHECK ((source_type = 'REVERSAL') = (reverses_reference IS NOT NULL)),
    CONSTRAINT points_ledger_paid_at_ck CHECK (status IS DISTINCT FROM 'PAID' OR paid_at IS NOT NULL),
    -- Phase 1: no Coin payout. Dropped by the phase 2 migration.
    CONSTRAINT points_ledger_no_paid_phase1_ck CHECK (status IS DISTINCT FROM 'PAID')
);

CREATE INDEX points_ledger_employee_idx ON scoring.points_ledger (employee_id, created_at);
CREATE INDEX points_ledger_campaign_idx ON scoring.points_ledger (campaign_id);
-- PO "action required" list.
CREATE INDEX points_ledger_action_required_idx ON scoring.points_ledger (created_at) WHERE status IS NULL;

-- A reversal carries the action of the row it reverses. `recognition.action_delta` (V010) turns the action into the
-- change in `actions_count` and `reposters`, and returns 0 for a NULL action, so a reversal whose action differs from its
-- original would take the points off but leave the counts wrong. A CHECK can't compare two rows, and "action is not null"
-- would be wrong: a PO adjustment has no action, and neither does its reversal.
CREATE FUNCTION scoring.check_reversal_action()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_action text;
    v_found  boolean := false;
BEGIN
    SELECT true, l.action INTO v_found, v_action FROM scoring.points_ledger l WHERE l.reference = NEW.reverses_reference;
    -- No original is `points_ledger_reversal_ck`'s business (a reversal names the row it reverses).
    IF v_found AND NEW.action IS DISTINCT FROM v_action THEN
        RAISE EXCEPTION 'a reversal must carry the action of the row it reverses (% reverses %)', NEW.reference, NEW.reverses_reference
            USING ERRCODE = 'check_violation', CONSTRAINT = 'points_ledger_reversal_action_ck';
    END IF;
    RETURN NEW;
END
$fn$;

CREATE TRIGGER points_ledger_reversal_action
    BEFORE INSERT ON scoring.points_ledger
    FOR EACH ROW WHEN (NEW.source_type = 'REVERSAL')
    EXECUTE FUNCTION scoring.check_reversal_action();

GRANT SELECT, INSERT ON scoring.point_rule TO amplify_api;
GRANT SELECT ON scoring.point_rule TO amplify_jobs, amplify_readonly;

-- Facts are physically immutable to app roles: insert/select plus the settlement columns only.
GRANT SELECT, INSERT ON scoring.points_ledger TO amplify_api, amplify_jobs;
GRANT UPDATE (status, status_changed_at, paid_at, coin_reference) ON scoring.points_ledger TO amplify_api, amplify_jobs;
GRANT SELECT ON scoring.points_ledger TO amplify_readonly;
