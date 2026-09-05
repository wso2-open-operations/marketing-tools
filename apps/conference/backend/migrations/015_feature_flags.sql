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

-- Seeds the per-feature switches the attendee microapp reads, and the route
-- mapping the backend enforces them with.
--
-- Prerequisite: app_config (migrations/006). No DDL here -- these are rows in
-- a table that already exists, which is the whole point: switching a feature
-- off, renaming its placeholder copy, or introducing a feature that did not
-- exist when either service was built are all row edits, never a release.
--
-- Three rows per feature:
--
--   is_<feature>_enabled            '1' | '0'
--   <feature>_coming_soon_title     heading on the placeholder screen
--   <feature>_coming_soon_message   body copy under it
--
-- `is_<feature>_enabled` is not new. is_agenda_enabled, is_speakers_enabled,
-- is_networking_enabled, is_ai_chat_enabled and is_attendee_list_enabled were
-- already live before this file; the seed below adopts their spelling and,
-- because every insert is ON CONFLICT DO NOTHING, leaves whatever value
-- production already holds for them completely alone. Re-running this file
-- never resets a switch an operator has set -- it only fills gaps.
--
-- Defaults follow the product decision that the AI screens and networking
-- start closed: agenda_recommendations, attendee_recommendations, ai_chat,
-- o2bar, personalized_profile and networking seed '0'; everything else seeds
-- '1', which is the behaviour the app had before flags existed.
--
-- The same defaults are compiled into internal/features/features.go, so an
-- environment where this file has not run still behaves identically. Adding a
-- feature to one means adding it to the other (and to the microapp's
-- src/services/types/config.ts) in the same change -- nothing enforces it.

-- One row per (feature, key kind): the VALUES table below lists each feature
-- once, and the LATERAL expands it into its three keys. Written this way so
-- that adding a feature is one line rather than three, and so the enabled
-- value and its copy sit next to each other where a reviewer can see them.
INSERT INTO app_config (config_key, value, created_by, updated_by)
SELECT expanded.config_key, expanded.value, 'SYSTEM', 'SYSTEM'
FROM (
  VALUES
    ('agenda', '1',
     'Agenda coming soon',
     'The full conference agenda will appear here as soon as it is published.'),
    ('session_details', '1',
     'Session details coming soon',
     'Full session write-ups are still being finalised. Check back shortly.'),
    ('speakers', '1',
     'Speakers coming soon',
     'The speaker line-up is still being confirmed. Check back shortly.'),
    ('speaker_details', '1',
     'Speaker profiles coming soon',
     'Speaker profiles are still being finalised. Check back shortly.'),
    ('agenda_recommendations', '0',
     'Picked for You is coming soon',
     'Personalised session recommendations will be available closer to the event.'),
    ('networking', '0',
     'Networking is coming soon',
     'Connecting with other attendees will open closer to the event.'),
    ('attendee_list', '1',
     'Attendee directory coming soon',
     'The attendee directory will open closer to the event.'),
    ('attendee_recommendations', '0',
     'Suggested connections are coming soon',
     'We will suggest people worth meeting once the attendee list is final.'),
    ('ai_chat', '0',
     'The conference assistant is coming soon',
     'Ask-me-anything about the conference opens closer to the event.'),
    ('o2bar', '0',
     'O2 Bar is coming soon',
     'Book time with a WSO2 engineer once the O2 Bar opens.'),
    ('personalized_profile', '0',
     'Profile personalisation is coming soon',
     'Richer profiles will be generated closer to the event.'),
    ('activities', '1',
     'Activities coming soon',
     'Side activities and social events will be listed here shortly.'),
    ('feedback', '1',
     'Feedback is coming soon',
     'Session feedback opens once the conference starts.'),
    ('favorites', '1',
     'My schedule is coming soon',
     'Saving sessions to your own schedule opens once the agenda is final.'),
    ('shop', '1',
     'The shop is coming soon',
     'Spend your WSO2 Coins here once the shop opens.'),
    ('wallet', '1',
     'Your wallet is coming soon',
     'Your WSO2 Coin balance will appear here once the event starts.'),
    ('coin', '1',
     'Earning coins is coming soon',
     'Scan QR codes around the venue to earn WSO2 Coins once the event starts.'),
    ('leaderboard', '1',
     'The leaderboard is coming soon',
     'See how you rank once coin collecting opens.'),
    ('notifications', '1',
     'Notifications are coming soon',
     'Announcements will be delivered here during the conference.'),
    ('qr_code', '1',
     'Your badge is coming soon',
     'Your check-in QR code will appear here closer to the event.'),
    ('profile', '1',
     'Your profile is coming soon',
     'Profile settings will be available closer to the event.'),
    ('meet_fde', '1',
     'Meet a Field Engineer is coming soon',
     'Booking time with a WSO2 field engineer opens closer to the event.'),
    ('attendee_registration', '1',
     'Session registration is coming soon',
     'Reserving your seat in a session opens closer to the event.'),
    ('floor_plan', '1',
     'The venue map is coming soon',
     'Floor plans will be published closer to the event.'),
    ('session_notes', '1',
     'Session notes are coming soon',
     'Taking private notes on a session opens once the agenda is final.'),
    ('session_notifications', '1',
     'Session reminders are coming soon',
     'Reminders before your saved sessions open once the agenda is final.')
) AS f(feature, enabled, title, message)
CROSS JOIN LATERAL (
  VALUES
    ('is_' || f.feature || '_enabled',        f.enabled),
    (f.feature || '_coming_soon_title',       f.title),
    (f.feature || '_coming_soon_message',     f.message)
) AS expanded(config_key, value)
ON CONFLICT (config_key) DO NOTHING;

-- Which routes a feature switch actually turns off.
--
-- This is a row and not a Go route table for the same reason the flags are
-- rows: a gate that needs a backend release before it can cover a new
-- endpoint is a gate that will be out of date. internal/middleware/feature.go
-- reads this once per features.DefaultTTL and matches on
-- "<METHOD> <gin route pattern>" -- the pattern as registered, wildcards and
-- all, because that is what gin reports as c.FullPath(). A method of '*'
-- matches any verb. A route absent from this object is never gated.
--
-- The identical JSON is compiled into internal/features/gates.go as
-- DefaultGateMapJSON and is used only until this row exists; once it does, it
-- wins outright. It replaces the built-in map rather than merging with it,
-- so a route can be un-gated from here -- a merge would make that impossible.
-- A value that does not parse is ignored with an error log, and the built-in
-- map stays in force, so a bad edit degrades to "gates what this build was
-- tested against" rather than to "gates nothing".
--
-- Deliberately absent, and think hard before adding them: /events/current,
-- /attendees, /attendees/me, /user-profile and /app-configs. Those are how the
-- microapp learns who is holding the phone, which event is running, and what
-- these very flags say. Gating them turns a hidden screen into a dead app.
INSERT INTO app_config (config_key, value, created_by, updated_by)
VALUES ('feature_gates', '{
  "agenda": ["GET /event-agendas", "GET /events", "GET /events/:eventId/agendas"],
  "session_details": ["GET /sessions/:id", "GET /sessions/current"],
  "speakers": ["GET /speakers"],
  "speaker_details": ["GET /speakers/:id"],
  "agenda_recommendations": ["GET /agenda/recommendations"],
  "networking": [
    "GET /users/me/connections",
    "POST /users/me/connections",
    "POST /users/me/connections/:id/accept",
    "DELETE /users/me/connections/:id"
  ],
  "attendee_list": ["POST /attendees/search"],
  "attendee_recommendations": ["GET /users/me/matches"],
  "ai_chat": ["POST /assistant/chat", "GET /ai-maintenance-status"],
  "o2bar": ["GET /o2bar/recommendations", "POST /o2bar/recommendations"],
  "personalized_profile": ["POST /users/profile"],
  "activities": ["GET /activities"],
  "feedback": ["POST /feedback"],
  "favorites": [
    "GET /users/me/favorites",
    "PUT /users/me/favorites/:sessionId",
    "DELETE /users/me/favorites/:sessionId"
  ],
  "shop": [
    "GET /shops/items",
    "GET /shops/orders/me",
    "POST /shops/checkout",
    "POST /shops/checkout/confirm"
  ],
  "wallet": ["GET /wallets/balances/me"],
  "coin": ["POST /qr/scan", "GET /qr/history", "GET /qr/summary", "GET /qr-codes"],
  "leaderboard": [
    "GET /leaderboard",
    "GET /leaderboard/preferences",
    "PUT /leaderboard/preferences"
  ],
  "notifications": ["POST /users/notifications"]
}', 'SYSTEM', 'SYSTEM')
ON CONFLICT (config_key) DO NOTHING;

-- app_config has never had a grant written for it -- 006 created the table and
-- every environment has been relying on whatever the role happened to inherit.
-- Staging hit exactly this on user_connection on 2026-09-05 (see 014), where a
-- hand-fixed grant would have been lost on the next rebuild. SELECT only: this
-- service has no write path to app_config, and the seeds above are applied by
-- a migrator, not by the app role.
--
-- The role list is per-environment and was verified against both databases on
-- 2026-09-05: staging runs as `eventdashboard_stg_user`, production as
-- `eventdashboard_rw_user`. There is no `eventdashboard_prod_user` in either,
-- which means 014's identical block has never granted anything on production --
-- harmless so far only because the owner (`wso2`) had already granted the role
-- full privileges by hand. Fix 014's array too if you touch that file; the
-- point of writing the grant down is that the next rebuild does not depend on
-- somebody remembering.
--
-- This block only does anything when the file is applied as the table's owner
-- (`wso2`) or by a role holding GRANT OPTION. Applied as an ordinary migrator
-- account it logs `WARNING: no privileges were granted for "app_config"` and
-- moves on, which is what happened on production on 2026-09-05. That warning
-- is not a failure and the seeds above still commit -- but the grant is then
-- still only whatever the owner set by hand, so re-run this file as the owner
-- if you want it recorded.
--
-- Guarded on the role existing so the file still applies on a laptop.
DO $$
DECLARE
  app_role TEXT;
BEGIN
  FOREACH app_role IN ARRAY ARRAY['eventdashboard_stg_user', 'eventdashboard_rw_user', 'eventdashboard_prod_user'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
      EXECUTE format(
        'GRANT SELECT ON %I.app_config TO %I',
        current_schema(), app_role);
    END IF;
  END LOOP;
END $$;
