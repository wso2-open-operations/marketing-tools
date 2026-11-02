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

-- V002: identity (shared kernel) and S1 Campaign (phase1-data-model › identity, campaign).
-- Enums are text + CHECK so a later phase can widen them with a plain constraint swap.

SET LOCAL ROLE amplify_migrate;

-- ---- identity ------------------------------------------------------------------------------------

CREATE TABLE identity.employee (
    employee_id   text        PRIMARY KEY CHECK (length(employee_id) BETWEEN 1 AND 255),
    email         citext      NOT NULL UNIQUE CHECK (length(email) BETWEEN 3 AND 320),
    display_name  text        NOT NULL CHECK (length(display_name) BETWEEN 1 AND 255),
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    CHECK (last_seen_at >= first_seen_at)
);

GRANT SELECT, INSERT, UPDATE ON identity.employee TO amplify_api;
GRANT SELECT ON identity.employee TO amplify_jobs, amplify_readonly;

-- ---- campaign ------------------------------------------------------------------------------------

CREATE TABLE campaign.category (
    code       text    PRIMARY KEY CHECK (code ~ '^[A-Z][A-Z0-9_]{0,49}$'),
    label      text    NOT NULL CHECK (length(label) BETWEEN 1 AND 100),
    active     boolean NOT NULL DEFAULT true,
    sort_order int     NOT NULL DEFAULT 0
);

CREATE TABLE campaign.campaign (
    id            uuid        PRIMARY KEY DEFAULT uuidv7(),
    provider      text        NOT NULL CHECK (provider IN ('linkedin')),
    resource_urn  text        NOT NULL CHECK (resource_urn LIKE 'urn:%' AND length(resource_urn) <= 255),
    resource_type text        NOT NULL
        CHECK (resource_type IN ('SHARE', 'UGC_POST', 'ARTICLE', 'VIDEO', 'DOCUMENT', 'EVENT', 'OTHER')),
    owner_urn     text        NOT NULL CHECK (owner_urn LIKE 'urn:li:organization:%'),
    resource_url  text        CHECK (resource_url LIKE 'https://%'),
    title         text        NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    summary       text        CHECK (length(summary) <= 2000),
    image_url     text        CHECK (image_url LIKE 'https://%'),
    category_code text        NOT NULL REFERENCES campaign.category (code),
    is_priority   boolean     NOT NULL DEFAULT false,
    opens_at      timestamptz NOT NULL,
    closes_at     timestamptz NOT NULL,
    archived_at   timestamptz,
    created_by    text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    version       int         NOT NULL DEFAULT 1 CHECK (version > 0),
    CONSTRAINT campaign_provider_resource_uk UNIQUE (provider, resource_urn),
    CONSTRAINT campaign_window_ck CHECK (closes_at > opens_at)
);

-- Posts page: last two weeks of live campaigns, and the priority strip.
CREATE INDEX campaign_opens_at_idx ON campaign.campaign (opens_at DESC) WHERE archived_at IS NULL;
CREATE INDEX campaign_priority_idx ON campaign.campaign (is_priority, opens_at DESC) WHERE archived_at IS NULL;

CREATE TABLE campaign.campaign_tag (
    campaign_id uuid NOT NULL REFERENCES campaign.campaign (id),
    tag         text NOT NULL CHECK (tag = lower(tag) AND length(tag) BETWEEN 1 AND 50),
    PRIMARY KEY (campaign_id, tag)
);

CREATE INDEX campaign_tag_tag_idx ON campaign.campaign_tag (tag);

-- Derived status: nothing to update when the clock moves (How status works).
CREATE VIEW campaign.campaign_v WITH (security_invoker = true) AS
SELECT c.*,
       CASE WHEN c.archived_at IS NOT NULL THEN 'ARCHIVED'
            WHEN now() < c.opens_at THEN 'SCHEDULED'
            WHEN now() < c.closes_at THEN 'OPEN'
            ELSE 'CLOSED' END AS status
FROM campaign.campaign c;

-- "Delete" archives: no DELETE on campaign. Tags are replaced on edit, so they can be deleted.
GRANT SELECT, INSERT, UPDATE ON campaign.campaign, campaign.category TO amplify_api;
GRANT SELECT, INSERT, DELETE ON campaign.campaign_tag TO amplify_api;
GRANT SELECT ON campaign.campaign_v TO amplify_api;
GRANT SELECT ON campaign.campaign, campaign.category, campaign.campaign_tag, campaign.campaign_v
    TO amplify_jobs, amplify_readonly;
