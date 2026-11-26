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

-- V025: the LinkedIn page connection and the Community Management engagement sync (phases 2-4, slice 4).
--   connection_org_connection  the company page's token pointers (phase1-data-model, connection.org_connection). The
--                              tokens themselves go in connection_provider_token with owner_type ORG
--   sharing_sync_cursor        where the sync stopped, per post and endpoint (and per page for the share notifications)
--   sharing_api_usage          Community Management calls per UTC day, against engagement.daily_call_budget
--   sharing_native_intent      an employee opened a post to reshare it on LinkedIn itself; the sync marks it detected
-- and widens sharing_engagement.action to the reactions and comments the sync records.
--
-- Erasure (identity_erase_employee) is unchanged: the new tables hold pseudonymous ids (employee_id, connected_by),
-- post and page URNs and counters, no names, emails, member URNs or text. A synced engagement's member URN is in
-- sharing_engagement.actor_member_urn, which the function already erases; a reaction stores no activity URN (its id
-- embeds the member URN) and a comment stores its comment URN only, never the text.

CREATE TABLE connection_org_connection (
    provider                text        NOT NULL CHECK (provider IN ('linkedin')),
    org_urn                 text        NOT NULL CHECK (org_urn LIKE 'urn:li:organization:%' AND length(org_urn) <= 255),
    provider_api            text        NOT NULL CHECK (provider_api IN ('COMMUNITY_MANAGEMENT')),
    scopes                  text[]      NOT NULL DEFAULT '{}',
    -- The admin who connected the page (identity_employee.employee_id, virtual FK).
    connected_by            text        NOT NULL,
    access_token_id         uuid,
    access_token_issued_on  date,
    refresh_token_id        uuid,
    refresh_token_issued_on date,
    access_expires_at       timestamptz NOT NULL,
    refresh_expires_at      timestamptz,
    connected_at            timestamptz NOT NULL,
    revoked_at              timestamptz,
    version                 int         NOT NULL DEFAULT 1 CHECK (version > 0),
    PRIMARY KEY (provider, org_urn),
    -- Each token pointer is both parts or neither (virtual FK into a partition, so no physical FK).
    CONSTRAINT org_connection_access_ref_ck CHECK ((access_token_id IS NULL) = (access_token_issued_on IS NULL)),
    CONSTRAINT org_connection_refresh_ref_ck CHECK ((refresh_token_id IS NULL) = (refresh_token_issued_on IS NULL)),
    CONSTRAINT org_connection_refresh_expiry_ck CHECK (refresh_token_id IS NULL OR refresh_expires_at IS NOT NULL),
    -- A revoked page keeps no token.
    CONSTRAINT org_connection_revoked_no_token_ck
        CHECK (revoked_at IS NULL OR (access_token_id IS NULL AND refresh_token_id IS NULL))
);

CREATE TABLE sharing_sync_cursor (
    provider     text        NOT NULL CHECK (provider IN ('linkedin')),
    provider_api text        NOT NULL CHECK (provider_api IN ('COMMUNITY_MANAGEMENT')),
    -- The post (reactions, comments) or the page (share notifications).
    resource_urn text        NOT NULL CHECK (resource_urn LIKE 'urn:%' AND length(resource_urn) <= 255),
    endpoint     text        NOT NULL CHECK (endpoint IN ('REACTIONS', 'COMMENTS', 'SHARE_NOTIFICATIONS')),
    -- REACTIONS / COMMENTS: elements already read (an offset); SHARE_NOTIFICATIONS: end of the last window, epoch ms.
    cursor       text        NOT NULL CHECK (length(cursor) BETWEEN 1 AND 64),
    last_run_at  timestamptz NOT NULL,
    PRIMARY KEY (provider, provider_api, resource_urn, endpoint)
);

CREATE TABLE sharing_api_usage (
    provider_api text NOT NULL CHECK (provider_api IN ('COMMUNITY_MANAGEMENT')),
    -- UTC day.
    day          date NOT NULL,
    calls        int  NOT NULL DEFAULT 0 CHECK (calls >= 0),
    PRIMARY KEY (provider_api, day)
);

CREATE TABLE sharing_native_intent (
    employee_id text        NOT NULL,
    campaign_id uuid        NOT NULL,
    -- The latest click on "Repost on LinkedIn" before the reshare was seen.
    opened_at   timestamptz NOT NULL,
    -- The sync saw the employee's reshare of the campaign post.
    detected_at timestamptz,
    PRIMARY KEY (employee_id, campaign_id)
);

-- The sync records reactions and comments; a reshare it detects is a REPOST or REPOST_COMMENTARY like an in-app one.
ALTER TABLE sharing_engagement DROP CONSTRAINT sharing_engagement_action_check;
ALTER TABLE sharing_engagement ADD CONSTRAINT sharing_engagement_action_check
    CHECK (action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY', 'REACTION', 'COMMENT'));
