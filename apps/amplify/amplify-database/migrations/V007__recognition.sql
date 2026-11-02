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

-- V007: S4 Recognition read models (phase1-data-model › recognition, leaderboards.md, B12, B15, B16).
-- Plain tables kept current in the ledger insert's transaction; rebuildable from the ledger (V010).

SET LOCAL ROLE amplify_migrate;

CREATE TABLE recognition.standing_version (
    period_key   text        PRIMARY KEY,
    version      bigint      NOT NULL DEFAULT 1,
    refreshed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE recognition.standing (
    period_key          text        NOT NULL,
    employee_id         text        NOT NULL,
    display_name        text        NOT NULL,
    email               citext,
    total_points        int         NOT NULL DEFAULT 0,
    actions_count       int         NOT NULL DEFAULT 0,
    rank                int,
    previous_rank       int,
    points_to_next_rank int         NOT NULL DEFAULT 0,
    -- Gap to rank `leaderboard.top_n` (renamed from points_to_podium, B16).
    points_to_top_n     int         NOT NULL DEFAULT 0,
    last_activity_at    timestamptz,
    updated_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (period_key, employee_id)
);

-- Company top N and the Team page; My Team by roster emails; Team search.
CREATE INDEX standing_rank_idx ON recognition.standing (period_key, rank);
CREATE INDEX standing_email_idx ON recognition.standing (period_key, email);
CREATE INDEX standing_display_name_trgm_idx ON recognition.standing USING gin (display_name public.gin_trgm_ops);

CREATE TABLE recognition.employee_points_monthly (
    employee_id   text NOT NULL,
    month         date NOT NULL CHECK (month = date_trunc('month', month)::date),
    points        int  NOT NULL DEFAULT 0,
    actions_count int  NOT NULL DEFAULT 0,
    PRIMARY KEY (employee_id, month)
);

CREATE TABLE recognition.campaign_participation (
    campaign_id              uuid        PRIMARY KEY,
    reposters                int         NOT NULL DEFAULT 0,
    external_shares_approved int         NOT NULL DEFAULT 0,
    points                   int         NOT NULL DEFAULT 0,
    updated_at               timestamptz NOT NULL DEFAULT now()
);

-- amplify_api writes here too, so PO adjust/reverse/approve updates standings in its transaction (B12).
GRANT SELECT, INSERT, UPDATE, DELETE ON recognition.standing, recognition.standing_version,
    recognition.employee_points_monthly, recognition.campaign_participation TO amplify_api, amplify_jobs;
GRANT SELECT ON recognition.standing, recognition.standing_version, recognition.employee_points_monthly,
    recognition.campaign_participation TO amplify_readonly;
