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


-- V014: every action the points table prices, so later phases need no schema change (docs/requirements/point-values.md).
-- Adds REACTION (like), COMMENT, CHALLENGE_ENTRY and CHALLENGE_WINNER to the actions a point rule can price and a
-- ledger row can record. Nothing awards them yet: likes and comments need Community Management (phase 4) and the
-- Amplify Challenge awards are PO adjustments until it has its own flow. `sharing.engagement.action` is unchanged
-- (it grows when comments and reactions are synced).

SET LOCAL ROLE amplify_migrate;

ALTER TABLE scoring.point_rule DROP CONSTRAINT point_rule_action_check;
ALTER TABLE scoring.point_rule ADD CONSTRAINT point_rule_action_check
    CHECK (action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY', 'OWN_POST', 'OWN_POST_AMPLIFIED',
                      'REACTION', 'COMMENT', 'CHALLENGE_ENTRY', 'CHALLENGE_WINNER'));

ALTER TABLE scoring.points_ledger DROP CONSTRAINT points_ledger_action_check;
ALTER TABLE scoring.points_ledger ADD CONSTRAINT points_ledger_action_check
    CHECK (action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY', 'OWN_POST', 'OWN_POST_AMPLIFIED',
                      'REACTION', 'COMMENT', 'CHALLENGE_ENTRY', 'CHALLENGE_WINNER'));
