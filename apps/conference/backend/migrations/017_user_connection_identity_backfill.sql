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

-- Canonicalizes user_connection.requester_id / addressee_id onto
-- attendees.idp_uuid.
--
-- 014 documents both columns as "attendees.idp_uuid (the JWT sub)", on the
-- assumption that those are the same string. They are not. The Asgardeo
-- application behind the microapp issues a token whose sub is the attendee's
-- *email*, while targetId -- and every id this API hands out, the attendee
-- directory included -- is an idp_uuid. So each pair was written with an
-- email on the requester side and a uuid on the addressee side.
--
-- Nothing rejected that. Request validates only the addressee
-- (repository/connection.go), so the write succeeded; the read then filtered
-- on "either side is me" and joined the other party against
-- attendees.idp_uuid, and with mixed namespaces it could satisfy neither.
--
-- **This migration is a tidy-up, not a repair the application waits on.**
-- ConnectionRepo matches a party under every form the caller answers to
-- (models.CallerIdentity), so a row still holding an email is read,
-- accepted and deleted correctly whether or not this file has ever run.
-- What canonicalizing buys is that the alias matching stops having anything
-- to do, and that `userId` in a response comes straight from the row.
--
-- It therefore DELETES NOTHING. An earlier draft dropped rows it could not
-- canonicalize -- a pair that collapsed onto another, a side naming nobody
-- on the roster -- and that cost a real pending connection request on
-- production before the reasoning was challenged. A row this file cannot
-- rewrite is not corrupt; it is a row whose identities this database cannot
-- currently resolve, which is a reason to leave it alone and say so. Every
-- such row is reported with RAISE NOTICE and left exactly as it was.
--
-- Idempotent per the repo's hand-applied migration rules: the UPDATE is
-- guarded on the row actually changing, so a re-run touches nothing, not
-- even updated_at.

BEGIN;

-- `canonical` is the whole of the change: for every row, what its two sides
-- become once each one that is an attendee's email is replaced by that
-- attendee's idp_uuid.
--
-- It is a CTE rather than a temp table because the roles that apply
-- migrations here have no TEMP privilege on this database, and it is spelled
-- out twice rather than once because a data-modifying CTE would not see the
-- statement before it. The two copies are identical -- keep them that way.
--
-- A side already holding a uuid falls through COALESCE untouched, and so
-- does one that resolves to nothing, which is what lets the guards below
-- recognise it. The lookup is case-insensitive and skips unclaimed roster
-- entries (idp_uuid IS NULL, migration 003), which are not an identity
-- anything can be keyed on.

-- 1. Rewrite every row that can be rewritten without colliding.
--    pair_low/pair_high are GENERATED, so they follow on their own.
WITH canonical AS (
  SELECT uc.id,
         uc.state,
         uc.created_at,
         COALESCE((SELECT a.idp_uuid FROM attendees a
                   WHERE a.idp_uuid IS NOT NULL
                     AND LOWER(a.email) = LOWER(uc.requester_id)
                   LIMIT 1), uc.requester_id) AS requester_id,
         COALESCE((SELECT a.idp_uuid FROM attendees a
                   WHERE a.idp_uuid IS NOT NULL
                     AND LOWER(a.email) = LOWER(uc.addressee_id)
                   LIMIT 1), uc.addressee_id) AS addressee_id
  FROM user_connection uc
)
UPDATE user_connection uc
SET requester_id = c.requester_id,
    addressee_id = c.addressee_id
FROM canonical c
WHERE c.id = uc.id
  AND (uc.requester_id, uc.addressee_id) IS DISTINCT FROM (c.requester_id, c.addressee_id)

  -- Skip, do not drop, a row that collapses to a self-connection: the same
  -- person under two identity forms. user_connection_no_self would refuse
  -- the write anyway, and the row still names a relationship someone
  -- created.
  AND c.requester_id <> c.addressee_id

  -- Skip a row that would collide with another on (pair_low, pair_high).
  -- Two rows could describe one relationship while their ids differed by
  -- namespace, which the pair unique index could not see. Accepted beats
  -- pending and the older row wins the tie -- the same preference 014 used
  -- for the v1 mirrors -- but here the loser is left in place rather than
  -- deleted, and the alias matching keeps both readable.
  AND NOT EXISTS (
    SELECT 1
    FROM canonical other
    JOIN user_connection oc ON oc.id = other.id
    WHERE other.id <> c.id
      AND LEAST(other.requester_id, other.addressee_id)    = LEAST(c.requester_id, c.addressee_id)
      AND GREATEST(other.requester_id, other.addressee_id) = GREATEST(c.requester_id, c.addressee_id)
      AND (c.state, c.created_at, c.id) > (other.state, other.created_at, other.id)
  );

-- 2. Report, do not touch, whatever is still not canonical. These stay
--    readable through the application's alias matching; the notice is so
--    that someone knows they are there and why.
DO $$
DECLARE
  row_rec RECORD;
  leftover INT := 0;
BEGIN
  FOR row_rec IN
    SELECT uc.id, uc.requester_id, uc.addressee_id,
           (NOT EXISTS (SELECT 1 FROM attendees a WHERE a.idp_uuid = uc.requester_id)) AS req_unresolved,
           (NOT EXISTS (SELECT 1 FROM attendees a WHERE a.idp_uuid = uc.addressee_id)) AS addr_unresolved
    FROM user_connection uc
    WHERE NOT EXISTS (SELECT 1 FROM attendees a WHERE a.idp_uuid = uc.requester_id)
       OR NOT EXISTS (SELECT 1 FROM attendees a WHERE a.idp_uuid = uc.addressee_id)
    ORDER BY uc.created_at
  LOOP
    leftover := leftover + 1;
    RAISE NOTICE '017: left as-is: % (requester resolves: %, addressee resolves: %)',
      row_rec.id, NOT row_rec.req_unresolved, NOT row_rec.addr_unresolved;
  END LOOP;

  IF leftover = 0 THEN
    RAISE NOTICE '017: every connection row is canonical';
  ELSE
    RAISE NOTICE '017: % row(s) left as-is; they remain readable through the application''s alias matching', leftover;
  END IF;
END $$;

COMMIT;
