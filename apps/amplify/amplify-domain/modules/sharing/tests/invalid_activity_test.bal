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

import amplify_common.events;
import amplify_common.types;

import ballerina/test;
import ballerina/time;

isolated class InMemoryInvalidActivity {
    *InvalidActivityRepository;
    private map<[types:RemovalReason, time:Utc]> flagged = {};
    private final string[] known;

    isolated function init(string[] known) {
        self.known = known.clone();
    }

    public isolated function markInvalid(string engagementId, types:RemovalReason reason, types:LedgerReference reference,
            time:Utc at) returns boolean|error {
        lock {
            if self.known.indexOf(engagementId) is () {
                return types:domainError(types:ERR_NOT_FOUND, "Engagement not found");
            }
            if self.flagged.hasKey(engagementId) {
                return false;
            }
            self.flagged[engagementId] = [reason, at];
            return true;
        }
    }

    isolated function reasonOf(string engagementId) returns types:RemovalReason? {
        lock {
            [types:RemovalReason, time:Utc]? row = self.flagged[engagementId];
            return row is () ? () : row[0];
        }
    }
}

const string ENGAGEMENT_ID = "01900000-0000-7000-8000-0000000000e1";

isolated function removed(string engagementId, types:RemovalReason reason) returns events:ActivityRemoved => {
    reference: "REV-01900000-0000-7000-8000-0000000000aa", reversesReference: "AMP-x", engagementId,
    employeeId: "emp-1", removalReason: reason, removedAt: "2026-11-26T10:00:00Z"
};

@test:Config
function anEngagementIsFlaggedInvalidOnce() returns error? {
    InMemoryInvalidActivity repo = new ([ENGAGEMENT_ID]);
    test:assertTrue(check markEngagementInvalid(repo, removed(ENGAGEMENT_ID.toUpperAscii(), types:REMOVAL_DUPLICATE)),
            "flagged by the API right after the reversal");
    test:assertFalse(check markEngagementInvalid(repo, removed(ENGAGEMENT_ID, types:REMOVAL_SPAM)),
            "the jobs backstop changes nothing");
    test:assertEquals(repo.reasonOf(ENGAGEMENT_ID), types:REMOVAL_DUPLICATE, "the first reason stays");
}

@test:Config
function aBadOrUnknownEngagementIsRefused() {
    InMemoryInvalidActivity repo = new ([ENGAGEMENT_ID]);
    boolean|error bad = markEngagementInvalid(repo, removed("not-a-uuid", types:REMOVAL_SPAM));
    test:assertTrue(bad is types:DomainError && bad.detail().code == types:ERR_INVALID_UUID);
    boolean|error unknown = markEngagementInvalid(repo, removed("01900000-0000-7000-8000-0000000000e2",
            types:REMOVAL_SPAM));
    test:assertTrue(unknown is types:DomainError && unknown.detail().code == types:ERR_NOT_FOUND);
    events:ActivityRemoved badTime = removed(ENGAGEMENT_ID, types:REMOVAL_SPAM);
    badTime.removedAt = "yesterday";
    test:assertTrue(markEngagementInvalid(repo, badTime) is error);
}
