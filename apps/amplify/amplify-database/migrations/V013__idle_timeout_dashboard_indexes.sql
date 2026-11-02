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


-- V013: round 2 of the 2026-10-17 deep review (docs/migrations/2026-10-17-v013-idle-timeout-dashboard-indexes.md).
--
-- 1. Idle-in-transaction limit for the app roles (domain review H-3b). A connection left idle inside an
--    open transaction (the Ballerina runtime race R-13, or any client bug) holds its row locks until
--    PostgreSQL ends the session. 30 s (the R-13 write-up's recommendation,
--    docs/reviews/2026-10-17-r13-transaction-race.md) is far above any healthy gap between two statements
--    of one transaction; the recognition lock holders keep their tighter transaction-local 5 s.
--    ALTER ROLE needs the bootstrap admin (the role's creator, V001), so it runs before SET LOCAL ROLE.
-- 2. Dashboard indexes (domain review H-4), only the ones the planner used in EXPLAIN on a seeded copy
--    (see the doc): `points_ledger (created_at)` for tile 4 and `share_request (failed_at)` for the
--    tile 7 breakdown by reason. Tiles 2 and the tile 7 totals aggregate the whole table with FILTER, so
--    an index on `decided_at` / `published_at` wasn't used and isn't added.
-- 3. Lock order documented on the SQL side (round 2 item 11): COMMENT ON the three V012 functions that
--    take the SQL-level recognition lock, naming the app-level lock that comes first.

-- ---- 1. idle_in_transaction_session_timeout (bootstrap admin) -----------------------------------------

ALTER ROLE amplify_api SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE amplify_jobs SET idle_in_transaction_session_timeout = '30s';

SET LOCAL ROLE amplify_migrate;

-- ---- 2. dashboard indexes ---------------------------------------------------------------------------

-- Tile 4: points by action for the current month (scoring.pointsByAction).
CREATE INDEX points_ledger_created_at_idx ON scoring.points_ledger (created_at);
-- Tile 7: failures by reason in the last 7 days (sharing.shareHealth).
CREATE INDEX share_request_failed_at_idx ON sharing.share_request (failed_at) WHERE failed_at IS NOT NULL;

-- ---- 3. lock order on the SQL side -------------------------------------------------------------------

COMMENT ON FUNCTION recognition.apply_ledger_entry(varchar, int) IS
    'Takes the SQL-level recognition lock pg_advisory_xact_lock(1634561133) (V012). Lock order: callers take the app-level lock 4242101 (amplify_domain store:lockRecognition) first, in the same transaction, never after.';
COMMENT ON FUNCTION recognition.rerank(text, int) IS
    'Takes the SQL-level recognition lock pg_advisory_xact_lock(1634561133) (V012). Lock order: callers take the app-level lock 4242101 (amplify_domain store:lockRecognition) first, in the same transaction, never after.';
COMMENT ON FUNCTION recognition.rebuild(int) IS
    'Takes the SQL-level recognition lock pg_advisory_xact_lock(1634561133) (V012). Lock order: callers take the app-level lock 4242101 (amplify_domain store:lockRecognition) first, in the same transaction, never after.';
