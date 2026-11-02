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

-- S005: pilot point values from the business, 2026-10-19 (docs/requirements/point-values.md, plan D6).
-- New versions of every rule, effective 2026-10-19 00:00 UTC; S001's values stay for awards made before
-- then (append-only: points already earned are never recalculated).
-- Which action earns what, by phase:
--   SHARE ............... phase 1: Amplify posts the WSO2 post on the employee's LinkedIn ("repost with no
--                         added text") = 2
--   REPOST .............. phase 4: a native LinkedIn repost, tracked from LinkedIn = 2
--   REPOST_COMMENTARY ... phase 4: a native repost with the employee's own thoughts ("share with your own
--                         commentary") = 5
--   SHARE_COMMENTARY .... no new version: no phase uses it (LinkedIn's API can't post the employee's own
--                         commentary for them), so it isn't priced for the pilot
--   Original WSO2 post .................... OWN_POST = 10
--   Featured by WSO2 channels or an SLT member: +15 bonus. OWN_POST_AMPLIFIED is the total (10 + 15 = 25);
--   the ledger top-up is OWN_POST_AMPLIFIED - OWN_POST = 15 (C4).
-- Not here: likes/comments (1 point) aren't tracked until phase 4; Amplify Challenge entry (10) and winner
-- (25) have no action of their own yet, so the PO awards them as points adjustments with a reason.

SET LOCAL ROLE amplify_migrate;

INSERT INTO scoring.point_rule (action, points, effective_from, created_by)
VALUES ('REPOST', 2, '2026-10-19T00:00:00Z', 'system'),
       ('SHARE', 2, '2026-10-19T00:00:00Z', 'system'),
       ('REPOST_COMMENTARY', 5, '2026-10-19T00:00:00Z', 'system'),
       ('OWN_POST', 10, '2026-10-19T00:00:00Z', 'system'),
       ('OWN_POST_AMPLIFIED', 25, '2026-10-19T00:00:00Z', 'system')
ON CONFLICT (action, effective_from) DO NOTHING;
