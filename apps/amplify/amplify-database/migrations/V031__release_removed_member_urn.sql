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

-- V031: a removed LinkedIn connection releases its member URN. B13 is "one employee per LinkedIn member", and V003
-- enforced it over every row, removed ones included: after Remove Connection (removed_at set, token deleted, status
-- REMOVED) nobody else could ever link that LinkedIn account (MEMBER_ALREADY_LINKED). The rule now holds over live
-- connections only. The removed row stays as it was (its member URN, removed_at and the ConnectionRemoved audit row),
-- and if its employee reconnects while someone else holds the member, the unique index refuses it as before.
-- The index keeps the constraint's name, so the API still maps a violation to MEMBER_ALREADY_LINKED.

ALTER TABLE connection_member_connection DROP CONSTRAINT member_connection_member_uk;
CREATE UNIQUE INDEX member_connection_member_uk ON connection_member_connection (provider, member_urn)
    WHERE removed_at IS NULL;
