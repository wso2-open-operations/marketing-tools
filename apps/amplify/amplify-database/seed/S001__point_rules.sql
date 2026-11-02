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

-- S001: point rules (plan D6, docs/requirements/point-values.md; awaiting PO sign-off). Effective from the
-- epoch so any award time finds a rule. A change is a new row with a later effective_from (append-only).
-- SHARE / SHARE_COMMENTARY are the D5 fallback kinds (B4) and price like their REPOST twins.
-- OWN_POST_AMPLIFIED is the total; the ledger top-up is OWN_POST_AMPLIFIED − OWN_POST (C4).

SET LOCAL ROLE amplify_migrate;

INSERT INTO scoring.point_rule (action, points, effective_from, created_by)
VALUES ('REPOST', 5, '1970-01-01T00:00:00Z', 'system'),
       ('REPOST_COMMENTARY', 12, '1970-01-01T00:00:00Z', 'system'),
       ('SHARE', 5, '1970-01-01T00:00:00Z', 'system'),
       ('SHARE_COMMENTARY', 12, '1970-01-01T00:00:00Z', 'system'),
       ('OWN_POST', 20, '1970-01-01T00:00:00Z', 'system'),
       ('OWN_POST_AMPLIFIED', 40, '1970-01-01T00:00:00Z', 'system')
ON CONFLICT (action, effective_from) DO NOTHING;
