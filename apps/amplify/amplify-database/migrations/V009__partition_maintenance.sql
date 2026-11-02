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

-- V009: partition upkeep (ADR-002, B10, B11, B17). Called once a day by amplify-cron → amplify-jobs
-- `POST /maintenance/partitions`, which runs `messaging.run_partition_maintenance()`.
--
-- SECURITY DEFINER functions owned by amplify_migrate (the table owner), so app roles get partition DDL
-- only through these functions, never ALTER/DROP on the tables. search_path is pinned; every identifier
-- is schema-qualified and partition names go through format(%I). Every drop writes an audit row.
--
-- Drops use plain DETACH + DROP: DETACH ... CONCURRENTLY can't run inside a function or transaction. The
-- lock is brief because the partition dropped is old (no live readers).
-- UTC days and months: partition bounds are computed in UTC whatever the session time zone.

SET LOCAL ROLE amplify_migrate;

-- ---- helpers -------------------------------------------------------------------------------------

CREATE FUNCTION audit.write_system_audit(p_action text, p_entity_type text, p_entity_id text, p_after jsonb)
    RETURNS void
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
    INSERT INTO audit.audit_log (actor_id, actor_roles, action, entity_type, entity_id, outcome, after)
    VALUES ('system', ARRAY['amplify_jobs'], p_action, p_entity_type, p_entity_id, 'SUCCESS', p_after);
$fn$;

-- ---- tokens: create ahead, drop by expiry --------------------------------------------------------

-- Creates daily partitions from p_from (default: today, UTC) through p_from + p_days_ahead. Two weeks ahead by default:
-- a token insert into a day with no partition fails, and the only creator is the daily maintenance run, so the runway
-- is how long that run can be down before connects start failing. amplify-jobs also creates them at start-up and
-- reports the days left on /ready (`amplify_token_partition_days_ahead`), so a stopped job is seen well before then.
CREATE FUNCTION connection.create_token_partitions(p_days_ahead int DEFAULT 14, p_from date DEFAULT NULL)
    RETURNS int
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_start   date := COALESCE(p_from, (now() AT TIME ZONE 'UTC')::date);
    v_day     date;
    v_name    text;
    v_created int  := 0;
BEGIN
    IF p_days_ahead < 0 OR p_days_ahead > 60 THEN
        RAISE EXCEPTION 'p_days_ahead must be 0-60, got %', p_days_ahead;
    END IF;
    FOR i IN 0..p_days_ahead LOOP
        v_day := v_start + i;
        v_name := 'provider_token_p' || to_char(v_day, 'YYYYMMDD');
        IF to_regclass(format('connection.%I', v_name)) IS NULL THEN
            EXECUTE format('CREATE TABLE connection.%I PARTITION OF connection.provider_token FOR VALUES FROM (%L) TO (%L)',
                           v_name, v_day, v_day + 1);
            v_created := v_created + 1;
        END IF;
    END LOOP;
    RETURN v_created;
END
$fn$;

-- Drops a past day's partition when it's empty or max(expires_at) + grace < now() (B11: the only token
-- drop rule, so a long-lived refresh token is never dropped early). Today and future days are kept.
CREATE FUNCTION connection.drop_expired_token_partitions(p_grace_days int DEFAULT 5)
    RETURNS int
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_today   date := (now() AT TIME ZONE 'UTC')::date;
    v_part    record;
    v_day     date;
    v_max     timestamptz;
    v_rows    bigint;
    v_dropped int  := 0;
BEGIN
    IF p_grace_days < 0 THEN
        RAISE EXCEPTION 'p_grace_days must be >= 0, got %', p_grace_days;
    END IF;
    FOR v_part IN
        SELECT c.relname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'connection.provider_token'::regclass
          AND c.relname ~ '^provider_token_p[0-9]{8}$'
        ORDER BY c.relname
    LOOP
        v_day := to_date(substr(v_part.relname, 17), 'YYYYMMDD');
        CONTINUE WHEN v_day >= v_today;
        EXECUTE format('SELECT max(expires_at), count(*) FROM connection.%I', v_part.relname) INTO v_max, v_rows;
        IF v_max IS NULL OR v_max + make_interval(days => p_grace_days) < now() THEN
            EXECUTE format('ALTER TABLE connection.provider_token DETACH PARTITION connection.%I', v_part.relname);
            EXECUTE format('DROP TABLE connection.%I', v_part.relname);
            PERFORM audit.write_system_audit('PARTITION_DROPPED', 'connection.provider_token', v_part.relname,
                    jsonb_build_object('day', v_day, 'rows', v_rows, 'max_expires_at', v_max,
                                       'grace_days', p_grace_days));
            v_dropped := v_dropped + 1;
        END IF;
    END LOOP;
    RETURN v_dropped;
END
$fn$;

-- ---- audit: create ahead, drop past retention ----------------------------------------------------

-- Creates monthly partitions from the month of p_from (default: this UTC month) through p_months_ahead.
CREATE FUNCTION audit.create_audit_partitions(p_months_ahead int DEFAULT 3, p_from date DEFAULT NULL)
    RETURNS int
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_start   date := date_trunc('month', COALESCE(p_from, (now() AT TIME ZONE 'UTC')::date))::date;
    v_month   date;
    v_name    text;
    v_created int  := 0;
BEGIN
    IF p_months_ahead < 0 OR p_months_ahead > 24 THEN
        RAISE EXCEPTION 'p_months_ahead must be 0-24, got %', p_months_ahead;
    END IF;
    FOR i IN 0..p_months_ahead LOOP
        v_month := (v_start + make_interval(months => i))::date;
        v_name := 'audit_log_p' || to_char(v_month, 'YYYYMM');
        IF to_regclass(format('audit.%I', v_name)) IS NULL THEN
            EXECUTE format('CREATE TABLE audit.%I PARTITION OF audit.audit_log FOR VALUES FROM (%L) TO (%L)',
                           v_name,
                           (v_month::timestamp AT TIME ZONE 'UTC'),
                           ((v_month + interval '1 month')::timestamp AT TIME ZONE 'UTC'));
            v_created := v_created + 1;
        END IF;
    END LOOP;
    RETURN v_created;
END
$fn$;

-- Drops months that ended more than p_retention_months ago (default 60, `audit.retention_months`).
CREATE FUNCTION audit.drop_old_audit_partitions(p_retention_months int DEFAULT 60)
    RETURNS int
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_cutoff  date := (date_trunc('month', (now() AT TIME ZONE 'UTC')) - make_interval(months => p_retention_months))::date;
    v_part    record;
    v_month   date;
    v_dropped int  := 0;
BEGIN
    IF p_retention_months < 60 THEN
        RAISE EXCEPTION 'Audit retention is at least 60 months (B17), got %', p_retention_months;
    END IF;
    FOR v_part IN
        SELECT c.relname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'audit.audit_log'::regclass
          AND c.relname ~ '^audit_log_p[0-9]{6}$'
        ORDER BY c.relname
    LOOP
        v_month := to_date(substr(v_part.relname, 12) || '01', 'YYYYMMDD');
        CONTINUE WHEN v_month >= v_cutoff;
        EXECUTE format('ALTER TABLE audit.audit_log DETACH PARTITION audit.%I', v_part.relname);
        EXECUTE format('DROP TABLE audit.%I', v_part.relname);
        PERFORM audit.write_system_audit('PARTITION_DROPPED', 'audit.audit_log', v_part.relname,
                jsonb_build_object('month', v_month, 'retention_months', p_retention_months));
        v_dropped := v_dropped + 1;
    END LOOP;
    RETURN v_dropped;
END
$fn$;

-- ---- outbox purge and oauth_state sweep ----------------------------------------------------------

CREATE FUNCTION messaging.purge_done_outbox(p_older_than_days int DEFAULT 30)
    RETURNS bigint
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_deleted bigint;
BEGIN
    IF p_older_than_days < 1 THEN
        RAISE EXCEPTION 'p_older_than_days must be >= 1, got %', p_older_than_days;
    END IF;
    DELETE FROM messaging.outbox
    WHERE status = 'DONE' AND processed_at < now() - make_interval(days => p_older_than_days);
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    IF v_deleted > 0 THEN
        PERFORM audit.write_system_audit('OUTBOX_PURGED', 'messaging.outbox', NULL,
                jsonb_build_object('rows', v_deleted, 'older_than_days', p_older_than_days));
    END IF;
    RETURN v_deleted;
END
$fn$;

CREATE FUNCTION connection.sweep_oauth_state()
    RETURNS bigint
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_deleted bigint;
BEGIN
    DELETE FROM connection.oauth_state WHERE expires_at < now();
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END
$fn$;

-- ---- the daily call ------------------------------------------------------------------------------

-- One call for tokens, audit, outbox and oauth_state (B10). Audit partitions are created first so the
-- drop audit rows always have a partition to land in. Settings come from config.app_setting.
CREATE FUNCTION messaging.run_partition_maintenance()
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    v_result jsonb;
BEGIN
    v_result := jsonb_build_object(
        'audit_partitions_created', audit.create_audit_partitions(3),
        'token_partitions_created', connection.create_token_partitions(14),
        'token_partitions_dropped',
            connection.drop_expired_token_partitions(config.int_setting('connection.token_grace_days', 5)),
        'audit_partitions_dropped',
            audit.drop_old_audit_partitions(config.int_setting('audit.retention_months', 60)),
        'outbox_rows_purged', messaging.purge_done_outbox(30),
        'oauth_states_swept', connection.sweep_oauth_state());
    RETURN v_result;
END
$fn$;

-- Only amplify-jobs runs upkeep. Functions are executable by PUBLIC by default; take that away.
REVOKE ALL ON FUNCTION audit.write_system_audit(text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION connection.create_token_partitions(int, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION connection.drop_expired_token_partitions(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION audit.create_audit_partitions(int, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION audit.drop_old_audit_partitions(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION messaging.purge_done_outbox(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION connection.sweep_oauth_state() FROM PUBLIC;
REVOKE ALL ON FUNCTION messaging.run_partition_maintenance() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION connection.create_token_partitions(int, date), connection.drop_expired_token_partitions(int),
    audit.create_audit_partitions(int, date), audit.drop_old_audit_partitions(int), messaging.purge_done_outbox(int),
    connection.sweep_oauth_state(), messaging.run_partition_maintenance() TO amplify_jobs;

-- Partitions exist from the first deploy: this month + 3, today + 14.
SELECT audit.create_audit_partitions(3);
SELECT connection.create_token_partitions(14);
