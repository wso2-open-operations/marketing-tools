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

-- V025: the company rank runs 1, 2, 3... with no ties.
--
-- `recognition_standing.rank` was a dense rank over points, so people on equal points shared a number (1, 2, 2, 4)
-- on the Team page's "Company rank" column, while the team boards and the top three already ordered ties by who
-- reached the points first. The rank is now `row_number()` over the same order: points, then the earliest
-- `last_activity_at` (no timestamp last), then name, then employee id.
--
-- What follows from it:
--   * `points_to_next_rank` = the points of the person one place ahead, minus your own, plus 1 (0 in first place).
--     The plus 1 is because equal points no longer share a place: a tie goes to whoever got there first, and the
--     later scorer is the one who just earned points.
--   * `points_to_top_n` = the points of the person at place N, minus your own, plus 1 (0 when you are in the top N).
--     V012 dropped the plus 1 because tying was enough under a dense rank; it is needed again.
--   * `previous_rank` still moves whenever a re-rank changes a person's place, so a person pushed down by someone
--     overtaking them now moves too, not only when a score level changes.
--
-- Same signature, owner and locking as V012 (`CREATE OR REPLACE` keeps them; the V013 comment stays). Existing
-- rows are re-ranked once, at the end, in this transaction: one UPDATE over about a thousand rows, holding only
-- the SQL-level recognition lock for milliseconds, no app-level lock (the order rule is about taking 4242101
-- first, and this script never takes it). A row whose place changes in this one-off re-rank gets no movement
-- arrow, so the release doesn't show a wave of moves nobody made.

CREATE OR REPLACE FUNCTION recognition_rerank(p_period_key text, p_top_n int DEFAULT 3)
    RETURNS bigint
    LANGUAGE plpgsql
AS $fn$
DECLARE
    v_version bigint;
BEGIN
    IF p_top_n < 1 THEN
        RAISE EXCEPTION 'p_top_n must be >= 1, got %', p_top_n;
    END IF;
    -- One writer per period at a time (V012): see that header.
    PERFORM pg_advisory_xact_lock(1634561133);
    WITH ranked AS (
        SELECT s.employee_id, s.total_points,
               row_number() OVER by_rank AS new_rank,
               lag(s.total_points) OVER by_rank AS ahead_points
        FROM recognition_standing s
        WHERE s.period_key = p_period_key
        WINDOW by_rank AS (ORDER BY s.total_points DESC, s.last_activity_at ASC NULLS LAST, s.display_name,
                                    s.employee_id)
    ), floor_n AS (
        SELECT total_points AS top_n_floor FROM ranked WHERE new_rank = p_top_n
    )
    UPDATE recognition_standing s
    SET rank                = r.new_rank,
        previous_rank       = CASE WHEN s.rank IS DISTINCT FROM r.new_rank THEN s.rank ELSE s.previous_rank END,
        points_to_next_rank = COALESCE(r.ahead_points - r.total_points + 1, 0),
        points_to_top_n     = CASE WHEN r.new_rank <= p_top_n THEN 0
                                   ELSE (SELECT top_n_floor FROM floor_n) - r.total_points + 1 END,
        updated_at          = now()
    FROM ranked r
    WHERE s.period_key = p_period_key
      AND s.employee_id = r.employee_id
      AND (s.rank IS DISTINCT FROM r.new_rank
           OR s.points_to_next_rank IS DISTINCT FROM COALESCE(r.ahead_points - r.total_points + 1, 0)
           OR s.points_to_top_n IS DISTINCT FROM CASE WHEN r.new_rank <= p_top_n THEN 0
                                                      ELSE (SELECT top_n_floor FROM floor_n) - r.total_points + 1 END);

    INSERT INTO recognition_standing_version AS v (period_key, version, refreshed_at)
    VALUES (p_period_key, 1, now())
    ON CONFLICT (period_key) DO UPDATE SET version = v.version + 1, refreshed_at = now()
    RETURNING v.version INTO v_version;
    RETURN v_version;
END
$fn$;

-- One-off: re-rank the rows already stored. Skipped on an empty table so a fresh database keeps version 0.
DO $once$
DECLARE
    v_top_n int;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM recognition_standing) THEN
        RETURN;
    END IF;
    SELECT COALESCE((SELECT (a.value #>> '{}')::int FROM config_app_setting a WHERE a.key = 'leaderboard.top_n'), 3)
    INTO v_top_n;
    CREATE TEMP TABLE v023_before ON COMMIT DROP AS
        SELECT s.period_key, s.employee_id, s.rank, s.previous_rank FROM recognition_standing s;
    PERFORM recognition_rerank(p.period_key, v_top_n) FROM (SELECT DISTINCT period_key FROM recognition_standing) p;
    -- A place that changed in this one-off re-rank is not a move: no arrow for it.
    UPDATE recognition_standing s
    SET previous_rank = s.rank
    FROM v023_before b
    WHERE s.period_key = b.period_key AND s.employee_id = b.employee_id
      AND s.rank IS DISTINCT FROM b.rank
      AND s.previous_rank IS NOT DISTINCT FROM b.rank;
END
$once$;
