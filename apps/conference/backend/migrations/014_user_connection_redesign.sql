-- Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
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

-- Rearchitects user_connection from one row per *direction* to one row per
-- *pair* (see .claude/PLAN.connections-redesign.md).
--
-- 004 keyed the table on (initiator_id, recipient_id), so A->B and B->A were
-- two distinct rows for one relationship, a self-row was legal, and the
-- allowed transition was whatever `status` int the caller put in the request
-- body. Four authorization bugs came out of that shape, not out of missing
-- checks. This migration removes the shape:
--
--   * generated pair_low/pair_high + UNIQUE  -> mirror and duplicate rows
--                                               are impossible
--   * CHECK (requester_id <> addressee_id)   -> self-connection is impossible
--   * state TEXT, not a signed int           -> no caller-supplied transition
--
-- Only two states exist, 'pending' and 'accepted'. There is deliberately no
-- 'declined': declining, withdrawing and removing all DELETE the row, so the
-- pair returns to "no relationship" and can connect later. A stored declined
-- state would be invisible (no API surface ever returns it) yet would silently
-- no-op every future request between those two people, because the re-request
-- conflicts on the pair unique index.
--
-- requester_id/addressee_id are attendees.idp_uuid (the JWT sub), not
-- attendees.id -- no FK, same looseness as 004 and the same
-- no-FK-to-read-only-tables precedent as feedback and favorites.
--
-- Idempotent per the repo's hand-applied migration rules: the rename is
-- guarded on the old column still being there, the table is IF NOT EXISTS, and
-- the backfill only runs while the new table is still empty.

BEGIN;

-- 1. Move the old directional table aside. Guarded on initiator_id so a
--    re-run, which finds the new shape in place, does nothing. The old rows
--    are kept rather than dropped: this is the only copy of the pre-migration
--    state, and user_connection_v1 can be dropped by hand once the redesign
--    has been verified against real traffic.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name   = 'user_connection'
      AND column_name  = 'initiator_id'
  ) THEN
    ALTER TABLE user_connection RENAME TO user_connection_v1;
    -- Free up the old constraint names too, or Postgres silently hands the
    -- new table suffixed ones (user_connection_pkey1) while v1 keeps the
    -- unsuffixed originals -- exactly backwards from what a reader expects.
    ALTER TABLE user_connection_v1
      RENAME CONSTRAINT user_connection_pkey TO user_connection_v1_pkey;
  END IF;
END $$;

-- 2. The pair-keyed replacement.
CREATE TABLE IF NOT EXISTS user_connection (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id  TEXT NOT NULL,
  addressee_id  TEXT NOT NULL,
  pair_low      TEXT GENERATED ALWAYS AS (LEAST(requester_id, addressee_id))    STORED,
  pair_high     TEXT GENERATED ALWAYS AS (GREATEST(requester_id, addressee_id)) STORED,
  state         TEXT NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending', 'accepted')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT user_connection_no_self CHECK (requester_id <> addressee_id),
  CONSTRAINT user_connection_pair_unique UNIQUE (pair_low, pair_high)
);

-- GET /users/me/connections filters on "either side is me", which the pair
-- unique index cannot serve on its own -- it is keyed on low/high, not on
-- which of the two the caller is.
CREATE INDEX IF NOT EXISTS user_connection_requester_idx ON user_connection (requester_id);
CREATE INDEX IF NOT EXISTS user_connection_addressee_idx ON user_connection (addressee_id);

-- 3. Carry the old rows over, collapsing each mirrored pair to one row.
--
--    * status  1 -> 'accepted', 0 -> 'pending'
--    * status -1 (rejected) is NOT carried: under the new model a declined
--      relationship is the absence of a row, so importing it would
--      permanently block that pair.
--    * self-rows and empty-id rows are dropped -- both were only ever
--      reachable through the bugs this migration exists to remove.
--    * where A->B and B->A both exist, accepted beats pending, and the older
--      row wins the tie, so the surviving requester_id is the person who
--      actually started the relationship.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = current_schema() AND table_name = 'user_connection_v1'
  ) AND NOT EXISTS (SELECT 1 FROM user_connection) THEN

    INSERT INTO user_connection (requester_id, addressee_id, state, created_at, updated_at)
    SELECT DISTINCT ON (LEAST(initiator_id, recipient_id), GREATEST(initiator_id, recipient_id))
           initiator_id,
           recipient_id,
           CASE status WHEN 1 THEN 'accepted' ELSE 'pending' END,
           created_at,
           created_at
    FROM user_connection_v1
    WHERE status IN (0, 1)
      AND initiator_id <> recipient_id
      AND initiator_id <> ''
      AND recipient_id <> ''
    ORDER BY LEAST(initiator_id, recipient_id),
             GREATEST(initiator_id, recipient_id),
             CASE status WHEN 1 THEN 0 ELSE 1 END,
             created_at
    ON CONFLICT (pair_low, pair_high) DO NOTHING;

  END IF;
END $$;

-- 4. Keep updated_at honest without the application having to remember.
CREATE OR REPLACE FUNCTION touch_user_connection() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS user_connection_touch ON user_connection;
CREATE TRIGGER user_connection_touch
  BEFORE UPDATE ON user_connection
  FOR EACH ROW EXECUTE FUNCTION touch_user_connection();

-- 5. Grant the role the deployed app actually connects as.
--    On staging 2026-09-05 the app could not touch user_connection at all
--    because the role had no privileges on it; that was fixed by hand, which
--    means the next rebuild would have re-broken it. Baked in here instead.
--    Guarded on the role existing so this file still applies on a laptop.
DO $$
DECLARE
  app_role TEXT;
BEGIN
  FOREACH app_role IN ARRAY ARRAY['eventdashboard_stg_user', 'eventdashboard_prod_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
      EXECUTE format(
        'GRANT SELECT, INSERT, UPDATE, DELETE ON %I.user_connection TO %I',
        current_schema(), app_role);
    END IF;
  END LOOP;
END $$;

COMMIT;
