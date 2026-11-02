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

-- V015: LinkedIn consent decision (Link Me pop-up). A sibling of member_connection because a person who
-- declines has no member URN or token, so no connection row. CONSENTED rows are written when the OAuth link
-- completes; DECLINED rows carry the LinkedIn profile URL the person typed so sharing can still be tracked; it is
-- optional, so NULL when they left it blank.

SET LOCAL ROLE amplify_migrate;

CREATE TABLE connection.linkedin_consent (
    employee_id  text        NOT NULL PRIMARY KEY,
    decision     text        NOT NULL CHECK (decision IN ('CONSENTED', 'DECLINED')),
    profile_url  text        CHECK (profile_url IS NULL OR length(profile_url) <= 255),
    decided_at   timestamptz NOT NULL DEFAULT now(),
    version      int         NOT NULL DEFAULT 1 CHECK (version > 0)
);

-- Personal data: the profile URL stays private like the member URN (nothing for amplify_readonly).
GRANT SELECT, INSERT, UPDATE ON connection.linkedin_consent TO amplify_api;
