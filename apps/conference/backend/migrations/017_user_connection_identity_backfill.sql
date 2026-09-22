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
-- (repository/connection.go), so the write succeeded; the read then filters
-- on "either side is me" and joins the other party against
-- attendees.idp_uuid, and with mixed namespaces it could satisfy neither.
-- Every connection request on production was therefore visible to the person
-- who sent it and to nobody else, and no request could ever be accepted --
-- while GET /users/me/connections answered 200 with three empty arrays. On
-- 2026-09-22 all 8 production rows were in this state.
--
-- The application-side fix is AttendeeProfileRepo.ResolveUUID, called from
-- ConnectionHandler.callerUUID, which resolves a caller onto their idp_uuid
-- before any connection statement sees it. This file repairs the rows the
-- unresolved subs already wrote.
--
-- Idempotent per the repo's hand-applied migration rules: every statement is
-- driven by a lookup that matches nothing once the rows are canonical, so a
-- re-run is a no-op.

BEGIN;

-- `canonical` is the whole of the repair, and both statements below are
-- driven by it: for every row, what its two sides become once each one that
-- is an attendee's email is replaced by that attendee's idp_uuid.
--
-- It is a CTE rather than a temp table because the roles that apply
-- migrations here have no TEMP privilege on this database, and it is spelled
-- out twice rather than once because a data-modifying CTE would not see the
-- statement before it. The two copies are identical -- keep them that way.
--
-- A side already holding a uuid falls through COALESCE untouched, and so
-- does one that resolves to nothing, which is what lets the DELETE below
-- recognise it. The lookup is case-insensitive and skips unclaimed roster
-- entries (idp_uuid IS NULL, migration 003), which are not an identity
-- anything can be keyed on.

-- 1. Remove the rows that cannot survive canonicalization, for three
--    distinct reasons.
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
DELETE FROM user_connection uc
USING canonical c
WHERE c.id = uc.id
  AND (
    -- (a) It collapses to a self-connection: A requesting A, where the two
    --     sides were the same person under different identity forms.
    --     user_connection_no_self would refuse the UPDATE below anyway.
    c.requester_id = c.addressee_id

    -- (b) A side resolves to nobody -- neither a live attendee's idp_uuid
    --     nor a live attendee's email. These are requests to people who
    --     have since left the roster (attendees has been reseeded wholesale
    --     more than once). No join can render such a row and no transition
    --     can act on it; the repository now logs one rather than silently
    --     omitting it, and there is no reason to emit that line forever.
    OR NOT EXISTS (SELECT 1 FROM attendees a WHERE a.idp_uuid = c.requester_id)
    OR NOT EXISTS (SELECT 1 FROM attendees a WHERE a.idp_uuid = c.addressee_id)

    -- (c) It collapses onto a pair another row already occupies. Two rows
    --     could describe one relationship while their ids differed by
    --     namespace, which the pair unique index could not see. Accepted
    --     beats pending and the older row wins the tie -- the same rule 014
    --     used to collapse the v1 mirrors.
    OR EXISTS (
      SELECT 1 FROM canonical other
      WHERE other.id <> c.id
        AND LEAST(other.requester_id, other.addressee_id)    = LEAST(c.requester_id, c.addressee_id)
        AND GREATEST(other.requester_id, other.addressee_id) = GREATEST(c.requester_id, c.addressee_id)
        AND (c.state, c.created_at, c.id) > (other.state, other.created_at, other.id)
    )
  );

-- 2. Rewrite what is left. pair_low/pair_high are GENERATED, so they follow
--    on their own.
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
  AND (uc.requester_id, uc.addressee_id) IS DISTINCT FROM (c.requester_id, c.addressee_id);

-- 3. Assert the invariant this migration exists to establish, so a re-run on
--    a tier that drifted fails loudly instead of reporting success.
DO $$
DECLARE
  bad INT;
BEGIN
  SELECT count(*) INTO bad
  FROM user_connection uc
  WHERE NOT EXISTS (SELECT 1 FROM attendees a WHERE a.idp_uuid = uc.requester_id)
     OR NOT EXISTS (SELECT 1 FROM attendees a WHERE a.idp_uuid = uc.addressee_id);
  IF bad > 0 THEN
    RAISE EXCEPTION '017: % connection row(s) still reference a non-attendee identity', bad;
  END IF;
END $$;

COMMIT;
