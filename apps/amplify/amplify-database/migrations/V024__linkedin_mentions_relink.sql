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

-- V024: LinkedIn mentions and re-linking after a removed connection.
--
-- 1. The member URN stayed unique across every connection row, removed ones included, so a member whose
--    connection was removed could not be linked again from another employee row (an alias, a re-created account):
--    the insert hit the unique key and the API answered MEMBER_ALREADY_LINKED. One live holder per member is the
--    rule (B13); a removed row gave the member up. The key becomes a unique index over rows that are not removed,
--    under the same name, so the repository's unique-violation mapping still finds it.
-- 2. member_name keeps the member's name from LinkedIn userinfo at the last connect. A mention links on LinkedIn
--    only when its text matches the member's name, so the jobs worker writes this name, not the directory one.
--    The erase function already deletes the whole connection row.
-- 3. Commentary now carries mention tokens, `@[label](amplify:person:<employee id>)`, which are longer than the
--    text LinkedIn shows. The API checks the shown length (at most 3000); the column limit grows to fit at most
--    20 tokens on top of that.
--
-- V023 is left for the Novera seen-stats branch.

ALTER TABLE connection_member_connection DROP CONSTRAINT member_connection_member_uk;
CREATE UNIQUE INDEX member_connection_member_uk ON connection_member_connection (provider, member_urn)
    WHERE removed_at IS NULL;

ALTER TABLE connection_member_connection
    ADD COLUMN member_name text CHECK (member_name IS NULL OR length(member_name) BETWEEN 1 AND 255);

ALTER TABLE sharing_share_request DROP CONSTRAINT sharing_share_request_commentary_check;
ALTER TABLE sharing_share_request
    ADD CONSTRAINT share_request_commentary_length_ck CHECK (length(commentary) <= 8000);
