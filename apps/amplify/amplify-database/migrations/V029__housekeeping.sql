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

-- V029: housekeeping for the phase 2-4 working tables that grow without bound. Each function deletes at most
-- p_limit rows (one short statement, rows picked with FOR UPDATE SKIP LOCKED so a live writer is never waited on)
-- and returns how many it deleted. amplify-jobs calls them from the daily `POST /maintenance/partitions` pass, again
-- while a call deletes a full batch (up to a fixed number of calls), then writes one HousekeepingRun audit row with
-- the counts. The ages come from config_app_setting (S017, validated in amplify-api settings.bal).
--
--   sharing_native_intent  a "Repost on LinkedIn" click: kept p_days after it was detected, or after the click when
--                          the reshare was never seen (the screen says NOT_FOUND after a day, so p_days >= 2)
--   sharing_api_usage      Community Management calls per UTC day: days older than p_days
--   sharing_sync_cursor    REACTIONS / COMMENTS offsets of a post not moved for p_days (its campaign closed long
--                          ago). The page's SHARE_NOTIFICATIONS cursor is never pruned. A pruned cursor of a post
--                          that is still open only means the next sync reads that post from the start again; the
--                          engagement unique keys make the replay harmless.
--
-- Business data is never pruned here: the ledger (V021 guard), engagements, coin runs and issues, external shares
-- and the audit log (whole partitions after audit.retention_months, V009). Same security model as V009: SECURITY
-- DEFINER, search_path pinned, not executable by PUBLIC, lock_timeout 5s like the V012 upkeep functions.

CREATE FUNCTION sharing_prune_native_intent(p_days int, p_limit int)
    RETURNS int
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path FROM CURRENT
AS $fn$
DECLARE
    v_deleted int;
BEGIN
    IF p_days < 2 OR p_days > 365 THEN
        RAISE EXCEPTION 'p_days must be 2-365, got %', p_days;
    END IF;
    IF p_limit < 1 OR p_limit > 50000 THEN
        RAISE EXCEPTION 'p_limit must be 1-50000, got %', p_limit;
    END IF;
    DELETE FROM sharing_native_intent
    WHERE ctid = ANY (ARRAY(
        SELECT ctid FROM sharing_native_intent
        WHERE COALESCE(detected_at, opened_at) < now() - make_interval(days => p_days)
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED));
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END
$fn$;

CREATE FUNCTION sharing_prune_api_usage(p_days int, p_limit int)
    RETURNS int
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path FROM CURRENT
AS $fn$
DECLARE
    v_deleted int;
BEGIN
    IF p_days < 30 OR p_days > 730 THEN
        RAISE EXCEPTION 'p_days must be 30-730, got %', p_days;
    END IF;
    IF p_limit < 1 OR p_limit > 50000 THEN
        RAISE EXCEPTION 'p_limit must be 1-50000, got %', p_limit;
    END IF;
    DELETE FROM sharing_api_usage
    WHERE ctid = ANY (ARRAY(
        SELECT ctid FROM sharing_api_usage
        WHERE day < (now() AT TIME ZONE 'UTC')::date - p_days
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED));
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END
$fn$;

CREATE FUNCTION sharing_prune_sync_cursor(p_days int, p_limit int)
    RETURNS int
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path FROM CURRENT
AS $fn$
DECLARE
    v_deleted int;
BEGIN
    IF p_days < 30 OR p_days > 730 THEN
        RAISE EXCEPTION 'p_days must be 30-730, got %', p_days;
    END IF;
    IF p_limit < 1 OR p_limit > 50000 THEN
        RAISE EXCEPTION 'p_limit must be 1-50000, got %', p_limit;
    END IF;
    DELETE FROM sharing_sync_cursor
    WHERE ctid = ANY (ARRAY(
        SELECT ctid FROM sharing_sync_cursor
        WHERE endpoint IN ('REACTIONS', 'COMMENTS')
          AND last_run_at < now() - make_interval(days => p_days)
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED));
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END
$fn$;

ALTER FUNCTION sharing_prune_native_intent(int, int) SET lock_timeout = '5s';
ALTER FUNCTION sharing_prune_api_usage(int, int) SET lock_timeout = '5s';
ALTER FUNCTION sharing_prune_sync_cursor(int, int) SET lock_timeout = '5s';

REVOKE ALL ON FUNCTION sharing_prune_native_intent(int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION sharing_prune_api_usage(int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION sharing_prune_sync_cursor(int, int) FROM PUBLIC;
