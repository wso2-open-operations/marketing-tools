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

-- V019: the local development stack's post link. The mock LinkedIn's browser-facing origin is
-- http://localhost:19091 (compose.yaml, `CAMPAIGNLINKORIGINS`), and a campaign registered there carries
-- `http://localhost:19091/...` as its post link, which V002's `resource_url LIKE 'https://%'` refused as a raw
-- check violation. The local stack is only for development, so the check also accepts that one dev origin.
--
-- Production is unchanged where it matters: the app (`campaign:postLink`) accepts only the origins in
-- `campaignLinkOrigins`, which default to https://www.linkedin.com and https://linkedin.com, so no other
-- plain-http link reaches this table, and the one origin listed here is a loopback address that no deployed
-- user can reach. The check is the backstop, not the policy. `image_url` stays https only.

SET LOCAL ROLE amplify_migrate;

ALTER TABLE campaign.campaign DROP CONSTRAINT campaign_resource_url_check;
ALTER TABLE campaign.campaign ADD CONSTRAINT campaign_resource_url_check
    CHECK (resource_url LIKE 'https://%' OR resource_url LIKE 'http://localhost:19091/%');
