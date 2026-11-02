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


-- S006: the rest of the pilot points table (business, 2026-10-19; docs/requirements/point-values.md), so no value is
-- overlooked when its phase arrives. Same effective date as S005; S005 stays as applied (forward-only).
--   Like on an Amplify post on LinkedIn ............ REACTION = 1     (phase 4: Community Management)
--   Comment on an Amplify post on LinkedIn ......... COMMENT = 1      (phase 4)
--   Share with your own commentary ................. SHARE_COMMENTARY = 5 (same as REPOST_COMMENTARY; without this row
--                                                    S001's old 12 would still be in force for the D5 fallback kind)
--   Amplify Challenge entry ........................ CHALLENGE_ENTRY = 10  (PO adjustment until it has a flow)
--   Amplify Challenge winner ....................... CHALLENGE_WINNER = 25 (PO adjustment until it has a flow)
-- Already seeded by S005: repost 2, repost/share with commentary 5, original post 10, featured +15 bonus
-- (OWN_POST_AMPLIFIED = 25 in total, the top-up is 15).

SET LOCAL ROLE amplify_migrate;

INSERT INTO scoring.point_rule (action, points, effective_from, created_by)
VALUES ('SHARE_COMMENTARY', 5, '2026-10-19T00:00:00Z', 'system'),
       ('REACTION', 1, '2026-10-19T00:00:00Z', 'system'),
       ('COMMENT', 1, '2026-10-19T00:00:00Z', 'system'),
       ('CHALLENGE_ENTRY', 10, '2026-10-19T00:00:00Z', 'system'),
       ('CHALLENGE_WINNER', 25, '2026-10-19T00:00:00Z', 'system')
ON CONFLICT (action, effective_from) DO NOTHING;
