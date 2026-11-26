// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// Which LinkedIn read verifies an engagement before Coins (V027).

import amplify_common.types;

import ballerina/test;

function verifyEngagement(types:EngagementAction action, string? activityUrn,
        string actor = "urn:li:person:aaa") returns Engagement => {
    id: "0192f0e0-0000-7000-8000-00000000e001", provider: types:LINKEDIN, providerApi: types:COMMUNITY_MANAGEMENT,
    origin: types:API_SYNC, targetResourceUrn: "urn:li:share:7001", campaignId: (), actorMemberUrn: actor,
    employeeId: "e1", action, activityUrn, occurredAt: [1790100000, 0], observedAt: [1790100000, 0],
    lastVerifiedAt: (), deletedAt: ()
};

@test:Config
function verifyTargetPerAction() {
    test:assertEquals(verifyTarget(verifyEngagement(types:REACTION, ())),
            {kind: TARGET_REACTION, urn: "urn:li:share:7001", actorUrn: "urn:li:person:aaa"});
    test:assertEquals(verifyTarget(verifyEngagement(types:REACTION, (), "urn:li:person:erased")), MEMBER_ERASED);
    test:assertEquals(verifyTarget(verifyEngagement(types:COMMENT, "urn:li:comment:(urn:li:share:7001,9)")),
            {kind: TARGET_COMMENT, urn: "urn:li:comment:(urn:li:share:7001,9)", actorUrn: ()});
    test:assertEquals(verifyTarget(verifyEngagement(types:COMMENT, ())), NO_ACTIVITY);
    test:assertEquals(verifyTarget(verifyEngagement(types:REPOST, "urn:li:share:8001")),
            {kind: TARGET_MEMBER_POST, urn: "urn:li:share:8001", actorUrn: ()});
    test:assertEquals(verifyTarget(verifyEngagement(types:SHARE_COMMENTARY, "urn:li:share:8002")),
            {kind: TARGET_MEMBER_POST, urn: "urn:li:share:8002", actorUrn: ()});
    test:assertEquals(verifyTarget(verifyEngagement(types:REPOST_COMMENTARY, " ")), NO_ACTIVITY);
}
