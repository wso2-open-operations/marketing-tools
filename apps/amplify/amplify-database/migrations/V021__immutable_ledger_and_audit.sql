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


-- V021: the points ledger and the audit log can't be rewritten (ADR-043, compensating control).
--
-- Until ADR-043 the database enforced this with column grants and insert-only grants per role. With one login
-- that owns everything there are no grants to lean on, so the two tables guard themselves with row triggers.
-- They protect against every code path and every mistake, the owner included. They do not stop someone who
-- deliberately drops the trigger (the owner can), and they leave TRUNCATE alone; both need a person with the
-- login's password, not a bug.
--
-- scoring_points_ledger: rows are never deleted, and only the settlement columns (status, status_changed_at,
-- paid_at, coin_reference) may change. Corrections are new ADJ-/REV- rows (ADR-010).
-- audit_log: rows are never changed or deleted. Retention drops whole partitions (DETACH + DROP), which fire
-- no row trigger, so audit_drop_old_audit_partitions and the daily upkeep are unaffected.
--
-- A deliberate bypass for a local fixture (scripts/load/seed-load.sql) is `SET session_replication_role =
-- replica`, which needs superuser. The application login has no such right.

CREATE FUNCTION scoring_points_ledger_guard()
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
    RETURN NEW;
END
$fn$;

CREATE TRIGGER scoring_points_ledger_guard
    BEFORE UPDATE OR DELETE ON scoring_points_ledger
    FOR EACH ROW EXECUTE FUNCTION scoring_points_ledger_guard();

CREATE FUNCTION audit_log_guard()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path FROM CURRENT
AS $fn$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only: a row is never % (id %)', lower(TG_OP), OLD.id
        USING ERRCODE = 'integrity_constraint_violation';
END
$fn$;

-- On the partitioned parent, so every partition has it, including the ones created later.
CREATE TRIGGER audit_log_guard
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION audit_log_guard();
