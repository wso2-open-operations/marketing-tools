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

-- V010: recognition upkeep (phase1-data-model › recognition, leaderboards.md, B12, B16).
--
-- `recognition.apply_ledger_entry` runs in the same transaction as each ledger insert (jobs score pass,
-- or amplify-api for PO decisions and corrections): upsert totals, re-rank the period with one
-- window-function UPDATE, bump standing_version. `recognition.rebuild` recomputes everything from the
-- ledger (`POST /maintenance/rebuild-recognition`). Ranking matches `recognition:rankStandings` in code:
-- dense rank by points; points_to_top_n = lowest points inside the top N − own points + 1, or 0 when in.
--
-- SECURITY INVOKER: callers (amplify_api, amplify_jobs) already hold rw on recognition and select on
-- scoring and identity. Only period `ALL` is maintained in phase 1 (plan D6 open).

SET LOCAL ROLE amplify_migrate;

-- How many "actions" a ledger row adds: +1 for an award (the top-up isn't a new action), −1 for the
-- reversal of one, 0 for adjustments.
CREATE FUNCTION recognition.action_delta(p_source_type text, p_action text)
    RETURNS int
    LANGUAGE sql
    IMMUTABLE
AS $fn$
    SELECT CASE
               WHEN p_action IS NULL OR p_action = 'OWN_POST_AMPLIFIED' THEN 0
               WHEN p_source_type IN ('ENGAGEMENT', 'EXTERNAL_SHARE') THEN 1
               WHEN p_source_type = 'REVERSAL' THEN -1
               ELSE 0 END;
$fn$;

-- Re-ranks one period in a single UPDATE and bumps its version (the ETag source).
CREATE FUNCTION recognition.rerank(p_period_key text, p_top_n int DEFAULT 3)
    RETURNS bigint
    LANGUAGE plpgsql
AS $fn$
DECLARE
    v_version bigint;
BEGIN
    IF p_top_n < 1 THEN
        RAISE EXCEPTION 'p_top_n must be >= 1, got %', p_top_n;
    END IF;
    WITH ranked AS (
        SELECT s.employee_id, s.total_points,
               dense_rank() OVER (ORDER BY s.total_points DESC)::int AS new_rank
        FROM recognition.standing s
        WHERE s.period_key = p_period_key
    ), levels AS (
        SELECT DISTINCT new_rank, total_points FROM ranked
    ), stepped AS (
        SELECT new_rank, total_points,
               lag(total_points) OVER (ORDER BY new_rank) AS next_better_points
        FROM levels
    ), floor_n AS (
        SELECT total_points AS top_n_floor
        FROM levels
        WHERE new_rank = LEAST(p_top_n, (SELECT max(new_rank) FROM levels))
    )
    UPDATE recognition.standing s
    SET rank                = r.new_rank,
        previous_rank       = CASE WHEN s.rank IS DISTINCT FROM r.new_rank THEN s.rank ELSE s.previous_rank END,
        points_to_next_rank = COALESCE(st.next_better_points - r.total_points, 0),
        points_to_top_n     = CASE WHEN r.new_rank <= p_top_n THEN 0
                                   ELSE (SELECT top_n_floor FROM floor_n) - r.total_points + 1 END,
        updated_at          = now()
    FROM ranked r
    JOIN stepped st ON st.new_rank = r.new_rank
    WHERE s.period_key = p_period_key
      AND s.employee_id = r.employee_id
      AND (s.rank IS DISTINCT FROM r.new_rank
           OR s.points_to_next_rank IS DISTINCT FROM COALESCE(st.next_better_points - r.total_points, 0)
           OR s.points_to_top_n IS DISTINCT FROM CASE WHEN r.new_rank <= p_top_n THEN 0
                                                      ELSE (SELECT top_n_floor FROM floor_n) - r.total_points + 1 END);

    INSERT INTO recognition.standing_version AS v (period_key, version, refreshed_at)
    VALUES (p_period_key, 1, now())
    ON CONFLICT (period_key) DO UPDATE SET version = v.version + 1, refreshed_at = now()
    RETURNING v.version INTO v_version;
    RETURN v_version;
END
$fn$;

-- Applies one ledger row to every read model, then re-ranks. Call it right after the ledger insert, in
-- the same transaction. Returns the new standing_version for `ALL`.
CREATE FUNCTION recognition.apply_ledger_entry(p_reference varchar, p_top_n int DEFAULT 3)
    RETURNS bigint
    LANGUAGE plpgsql
AS $fn$
DECLARE
    r        scoring.points_ledger%ROWTYPE;
    v_name   text;
    v_email  citext;
    v_delta  int;
BEGIN
    SELECT * INTO r FROM scoring.points_ledger WHERE reference = p_reference;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ledger entry % not found', p_reference;
    END IF;
    SELECT e.display_name, e.email INTO v_name, v_email FROM identity.employee e WHERE e.employee_id = r.employee_id;
    v_delta := recognition.action_delta(r.source_type, r.action);

    INSERT INTO recognition.standing AS s (period_key, employee_id, display_name, email, total_points, actions_count,
                                           last_activity_at, updated_at)
    VALUES ('ALL', r.employee_id, COALESCE(v_name, r.employee_id), v_email, r.points, v_delta, r.created_at, now())
    ON CONFLICT (period_key, employee_id) DO UPDATE
        SET total_points     = s.total_points + EXCLUDED.total_points,
            actions_count    = s.actions_count + EXCLUDED.actions_count,
            display_name     = COALESCE(v_name, s.display_name),
            email            = COALESCE(v_email, s.email),
            last_activity_at = GREATEST(s.last_activity_at, EXCLUDED.last_activity_at),
            updated_at       = now();

    INSERT INTO recognition.employee_points_monthly AS m (employee_id, month, points, actions_count)
    VALUES (r.employee_id, date_trunc('month', r.created_at AT TIME ZONE 'UTC')::date, r.points, v_delta)
    ON CONFLICT (employee_id, month) DO UPDATE
        SET points = m.points + EXCLUDED.points, actions_count = m.actions_count + EXCLUDED.actions_count;

    IF r.campaign_id IS NOT NULL THEN
        INSERT INTO recognition.campaign_participation AS c (campaign_id, reposters, external_shares_approved, points,
                                                             updated_at)
        VALUES (r.campaign_id,
                CASE WHEN r.action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY') THEN v_delta ELSE 0 END,
                CASE WHEN r.action = 'OWN_POST' THEN v_delta ELSE 0 END,
                r.points, now())
        ON CONFLICT (campaign_id) DO UPDATE
            SET reposters                = c.reposters + EXCLUDED.reposters,
                external_shares_approved = c.external_shares_approved + EXCLUDED.external_shares_approved,
                points                   = c.points + EXCLUDED.points,
                updated_at               = now();
    END IF;

    RETURN recognition.rerank('ALL', p_top_n);
END
$fn$;

-- Full rebuild from the ledger. Upserts rather than truncating so previous_rank survives where it can;
-- rows with no ledger left are removed. Returns the new standing_version for `ALL`.
CREATE FUNCTION recognition.rebuild(p_top_n int DEFAULT 3)
    RETURNS bigint
    LANGUAGE plpgsql
AS $fn$
BEGIN
    WITH totals AS (
        SELECT l.employee_id,
               sum(l.points)::int AS total_points,
               sum(recognition.action_delta(l.source_type, l.action))::int AS actions_count,
               max(l.created_at) AS last_activity_at
        FROM scoring.points_ledger l
        GROUP BY l.employee_id
    )
    INSERT INTO recognition.standing AS s (period_key, employee_id, display_name, email, total_points, actions_count,
                                           last_activity_at, updated_at)
    SELECT 'ALL', t.employee_id, COALESCE(e.display_name, t.employee_id), e.email, t.total_points, t.actions_count,
           t.last_activity_at, now()
    FROM totals t
    LEFT JOIN identity.employee e ON e.employee_id = t.employee_id
    ON CONFLICT (period_key, employee_id) DO UPDATE
        SET total_points     = EXCLUDED.total_points,
            actions_count    = EXCLUDED.actions_count,
            display_name     = EXCLUDED.display_name,
            email            = COALESCE(EXCLUDED.email, s.email),
            last_activity_at = EXCLUDED.last_activity_at,
            updated_at       = now();

    DELETE FROM recognition.standing s
    WHERE s.period_key = 'ALL'
      AND NOT EXISTS (SELECT 1 FROM scoring.points_ledger l WHERE l.employee_id = s.employee_id);

    DELETE FROM recognition.employee_points_monthly;
    INSERT INTO recognition.employee_points_monthly (employee_id, month, points, actions_count)
    SELECT l.employee_id, date_trunc('month', l.created_at AT TIME ZONE 'UTC')::date,
           sum(l.points)::int, sum(recognition.action_delta(l.source_type, l.action))::int
    FROM scoring.points_ledger l
    GROUP BY 1, 2;

    DELETE FROM recognition.campaign_participation;
    INSERT INTO recognition.campaign_participation (campaign_id, reposters, external_shares_approved, points, updated_at)
    SELECT l.campaign_id,
           sum(CASE WHEN l.action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY')
                    THEN recognition.action_delta(l.source_type, l.action) ELSE 0 END)::int,
           sum(CASE WHEN l.action = 'OWN_POST' THEN recognition.action_delta(l.source_type, l.action) ELSE 0 END)::int,
           sum(l.points)::int,
           now()
    FROM scoring.points_ledger l
    WHERE l.campaign_id IS NOT NULL
    GROUP BY l.campaign_id;

    RETURN recognition.rerank('ALL', p_top_n);
END
$fn$;

REVOKE ALL ON FUNCTION recognition.rerank(text, int), recognition.apply_ledger_entry(varchar, int),
    recognition.rebuild(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION recognition.rerank(text, int), recognition.apply_ledger_entry(varchar, int)
    TO amplify_api, amplify_jobs;
GRANT EXECUTE ON FUNCTION recognition.rebuild(int) TO amplify_jobs;
