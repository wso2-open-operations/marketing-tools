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

import amplify_common.types;

import ballerina/test;

@test:Config
function idempotencyKeysFollowTheCatalogue() {
    test:assertEquals(newCampaignRegistered({campaignId: "c1", provider: types:LINKEDIN, resourceUrn: "urn:li:share:1",
        title: "T", isPriority: false, shareNow: true, opensAt: "2026-10-20T00:00:00Z"}).idempotencyKey,
            "CampaignRegistered:c1");
    test:assertEquals(newCampaignAnnounced({campaignId: "c1", outboxId: 42, chatMessageName: "spaces/a/messages/b",
        sentAt: "2026-10-20T00:00:00Z"}).idempotencyKey, "CampaignAnnounced:42");
    test:assertEquals(newConnectionReady({employeeId: "e1", provider: types:LINKEDIN, memberUrn: "urn:li:person:x",
        connectedAt: "2026-10-20T00:00:00Z", accessExpiresAt: "2026-12-19T00:00:00Z"}).idempotencyKey,
            "ConnectionReady:urn:li:person:x:2026-10-20T00:00:00Z");
    test:assertEquals(newConnectionRevoked({employeeId: "e1", provider: types:LINKEDIN, memberUrn: "urn:li:person:x",
        revokedAt: "t"}).idempotencyKey, "ConnectionRevoked:urn:li:person:x:t");
    test:assertEquals(newConnectionRemoved({employeeId: "e1", provider: types:LINKEDIN, memberUrn: "urn:li:person:x",
        removedAt: "t"}).idempotencyKey, "ConnectionRemoved:urn:li:person:x:t");
    test:assertEquals(newEngagementRecorded({engagementId: "g1", provider: types:LINKEDIN,
        targetResourceUrn: "urn:li:share:1", campaignId: "c1", employeeId: "e1", action: types:REPOST,
        occurredAt: "t"}).idempotencyKey, "EngagementRecorded:g1");
    test:assertEquals(newExternalShareAmplified({externalShareId: "x1", employeeId: "e1", markedBy: "po",
        amplifiedAt: "t"}).idempotencyKey, "ExternalShareAmplified:x1:AMPLIFIED");
}

@test:Config
function eventsOfOneAggregateNeverShareAKey() {
    OutboxEvent requested = newRepostRequested({shareRequestId: "s1", campaignId: "c1", employeeId: "e1",
        kind: types:REPOST, targetResourceUrn: "urn:li:share:1", attempts: 1});
    OutboxEvent failed = newRepostFailed({shareRequestId: "s1", campaignId: "c1", employeeId: "e1", attempts: 1,
        failureReason: types:NEEDS_RECONNECT, errorCode: ()});
    OutboxEvent retried = newRepostRequested({shareRequestId: "s1", campaignId: "c1", employeeId: "e1",
        kind: types:REPOST, targetResourceUrn: "urn:li:share:1", attempts: 2});
    test:assertEquals(requested.idempotencyKey, "RepostRequested:s1:1");
    test:assertNotEquals(requested.idempotencyKey, failed.idempotencyKey);
    test:assertNotEquals(requested.idempotencyKey, retried.idempotencyKey, "a retry is a new outbox row (ADR-015)");

    string[] keys = [
        newExternalShareSubmitted({externalShareId: "x1", employeeId: "e1", action: types:OWN_POST,
            evidenceHost: "a.com", provider: "other", campaignId: ()}).idempotencyKey,
        newExternalShareApproved({externalShareId: "x1", employeeId: "e1", decidedBy: "po", decidedAt: "t",
            campaignId: ()}).idempotencyKey,
        newExternalShareRejected({externalShareId: "x1", employeeId: "e1", decidedBy: "po", decidedAt: "t"})
            .idempotencyKey
    ];
    test:assertEquals(keys, ["ExternalShareSubmitted:x1", "ExternalShareApproved:x1", "ExternalShareRejected:x1"]);
}

@test:Config
function pointsEventTypeFollowsSourceType() {
    types:LedgerEntry entry = {
        reference: "AMP-x", employeeId: "e1", campaignId: (), sourceType: types:ENGAGEMENT, sourceId: "g1",
        action: types:REPOST, points: 10, ruleId: "r1", reversesReference: (), reason: (), actorId: types:SYSTEM_ACTOR,
        correlationId: (), createdAt: [1790000000, 0], status: types:HELD, statusChangedAt: (), paidAt: (),
        coinReference: ()
    };
    OutboxEvent awarded = newPointsChanged(entry);
    test:assertEquals(awarded.eventType, POINTS_AWARDED);
    test:assertEquals(awarded.idempotencyKey, "PointsAwarded:AMP-x");
    types:LedgerEntry adjustment = entry.clone();
    adjustment.sourceType = types:ADJUSTMENT;
    test:assertEquals(newPointsChanged(adjustment).eventType, POINTS_ADJUSTED);
    types:LedgerEntry reversal = entry.clone();
    reversal.sourceType = types:REVERSAL;
    test:assertEquals(newPointsChanged(reversal).eventType, POINTS_REVERSED);
}

@test:Config
function payloadsAreJsonSafe() returns error? {
    OutboxEvent event = newRepostRequested({shareRequestId: "s1", campaignId: "c1", employeeId: "e1",
        kind: types:REPOST_COMMENTARY, targetResourceUrn: "urn:li:share:1", attempts: 1});
    json payload = event.payload.toJson();
    test:assertEquals(payload, {shareRequestId: "s1", campaignId: "c1", employeeId: "e1", kind: "REPOST_COMMENTARY",
        targetResourceUrn: "urn:li:share:1", attempts: 1}, "no commentary in the outbox payload");
}
