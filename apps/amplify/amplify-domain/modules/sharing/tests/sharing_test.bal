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

final time:Utc T0 = [1790000000, 0];
final CampaignSnapshot OPEN_CAMPAIGN = {id: "c1", provider: types:LINKEDIN, resourceUrn: "urn:li:share:6999", open: true};
final ConnectionSnapshot ACTIVE_CONNECTION = {memberUrn: "urn:li:person:abc", usable: true};

isolated class InMemoryShares {
    *ShareRepository;
    private map<ShareRequest> rows = {};
    private events:OutboxEvent[] outbox = [];

    public isolated function findByCampaignAndEmployee(string campaignId, types:EmployeeId employeeId) returns ShareRequest|error? {
        lock {
            return self.rows[campaignId + "|" + employeeId].clone();
        }
    }

    public isolated function insert(ShareRequest request, events:OutboxEvent[] outbox) returns error? {
        lock {
            string key = request.campaignId + "|" + request.employeeId;
            if self.rows.hasKey(key) {
                return error("unique (campaign_id, employee_id)");
            }
            self.rows[key] = request.clone();
            self.outbox.push(...outbox.clone());
        }
    }

    public isolated function update(ShareRequest request, int expectedVersion, events:OutboxEvent[] outbox) returns error? {
        lock {
            string key = request.campaignId + "|" + request.employeeId;
            ShareRequest? stored = self.rows[key];
            if stored is () || stored.version != expectedVersion || stored.id != request.id {
                return types:domainError(types:ERR_VERSION_CONFLICT, "stale");
            }
            self.rows[key] = request.clone();
            self.outbox.push(...outbox.clone());
        }
    }

    public isolated function count() returns int {
        lock {
            return self.rows.length();
        }
    }

    public isolated function events() returns events:OutboxEvent[] {
        lock {
            return self.outbox.clone();
        }
    }
}

isolated function code(any|error result) returns string {
    if result is types:DomainError {
        return result.detail().code;
    }
    return result is error ? "ERROR" : "OK";
}

function repost() returns ShareCommand => {employeeId: "emp-1", kind: types:REPOST};

function withThoughts(string text = "Great news") returns ShareCommand =>
    {employeeId: "emp-1", kind: types:REPOST_COMMENTARY, commentary: text};

@test:Config
function newRequestIsQueued() returns error? {
    ShareRequest r = check newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, withThoughts(" Great news "), "s1", T0);
    test:assertEquals(shareStatus(r), QUEUED);
    test:assertEquals(r.attempts, 1);
    test:assertEquals(r.commentary, "Great news");
    test:assertEquals(r.targetResourceUrn, "urn:li:share:6999");
}

@test:Config
function shareNeedsOpenCampaignAndActiveConnection() {
    CampaignSnapshot closed = {id: "c1", provider: types:LINKEDIN, resourceUrn: "urn:li:share:6999", open: false};
    test:assertEquals(code(newShareRequest(closed, ACTIVE_CONNECTION, repost(), "s1", T0)), types:ERR_CAMPAIGN_NOT_OPEN);
    test:assertEquals(code(newShareRequest(OPEN_CAMPAIGN, (), repost(), "s1", T0)), types:ERR_CONNECTION_NEEDS_RECONNECT);
    ConnectionSnapshot expired = {memberUrn: "urn:li:person:abc", usable: false};
    test:assertEquals(code(newShareRequest(OPEN_CAMPAIGN, expired, repost(), "s1", T0)), types:ERR_CONNECTION_NEEDS_RECONNECT);
}

@test:Config
function commentaryRulesFollowTheKind() {
    test:assertEquals(code(newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, withThoughts("  "), "s1", T0)),
            types:ERR_COMMENTARY_REQUIRED);
    string long = "";
    foreach int i in 0 ... COMMENTARY_MAX_LENGTH {
        long += "x";
    }
    test:assertEquals(code(newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, withThoughts(long), "s1", T0)),
            types:ERR_COMMENTARY_TOO_LONG);
    ShareCommand plainWithText = {employeeId: "emp-1", kind: types:REPOST, commentary: "hi"};
    test:assertEquals(code(newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, plainWithText, "s1", T0)),
            types:ERR_COMMENTARY_NOT_ALLOWED);
}

@test:Config
function publishClearsCommentaryAndRecordsEngagement() returns error? {
    ShareRequest r = check newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, withThoughts(), "s1", T0);
    PublishResult result = check markPublished(r, "urn:li:share:7001", "urn:li:person:abc", "g1", T0);
    test:assertEquals(shareStatus(result.request), PUBLISHED);
    test:assertEquals(result.request.commentary, (), "commentary kept only until published");
    test:assertEquals(result.request.engagementId, "g1");
    test:assertEquals(result.engagement.action, types:REPOST_COMMENTARY);
    test:assertEquals(result.engagement.origin, types:IN_APP);
    test:assertEquals(result.engagement.activityUrn, "urn:li:share:7001");
    test:assertEquals(result.outbox[0].eventType, events:ENGAGEMENT_RECORDED);
    test:assertEquals(result.outbox[0].idempotencyKey, "EngagementRecorded:g1");
}

@test:Config
function neverPostTwice() returns error? {
    ShareRequest r = check newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, repost(), "s1", T0);
    ShareRequest published = (check markPublished(r, "urn:li:share:7001", "urn:li:person:abc", "g1", T0)).request;
    test:assertEquals(code(ensurePublishable(published)), types:ERR_SHARE_ALREADY_PUBLISHED);
    test:assertEquals(code(markPublished(published, "urn:li:share:7002", "urn:li:person:abc", "g2", T0)),
            types:ERR_SHARE_ALREADY_PUBLISHED);
    test:assertEquals(code(markFailed(published, types:PROVIDER_REJECTED, (), T0)), types:ERR_SHARE_ALREADY_PUBLISHED,
            "published and failed are exclusive");
}

@test:Config
function failedRequestCantPublishUntilRetried() returns error? {
    ShareRequest r = check newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, repost(), "s1", T0);
    ShareRequest failed = check markFailed(r, types:PROVIDER_REJECTED, "422", T0);
    test:assertEquals(shareStatus(failed), FAILED);
    test:assertEquals(failed.failureReason, types:PROVIDER_REJECTED);
    test:assertEquals(code(markPublished(failed, "urn:li:share:1", "urn:li:person:abc", "g1", T0)), types:ERR_SHARE_NOT_QUEUED);
}

@test:Config
function retryReusesTheRow() returns error? {
    InMemoryShares repo = new;
    ShareRequest first = check requestShare(repo, OPEN_CAMPAIGN, ACTIVE_CONNECTION, repost(), T0);
    test:assertEquals(code(requestShare(repo, OPEN_CAMPAIGN, ACTIVE_CONNECTION, repost(), T0)), types:ERR_SHARE_ALREADY_QUEUED);

    ShareRequest failed = check markFailed(first, types:NEEDS_RECONNECT, (), T0);
    check repo.update(failed, first.version, [repostFailedEvent(failed)]);

    ShareRequest retried = check requestShare(repo, OPEN_CAMPAIGN, ACTIVE_CONNECTION, withThoughts(), types:addDays(T0, 1));
    test:assertEquals(retried.id, first.id, "C2: same row");
    test:assertEquals(repo.count(), 1, "one row per campaign per employee");
    test:assertEquals(retried.attempts, 2);
    test:assertEquals(retried.failedAt, ());
    test:assertEquals(retried.failureReason, ());
    test:assertEquals(retried.kind, types:REPOST_COMMENTARY, "new kind taken");
    test:assertEquals(shareStatus(retried), QUEUED);
    test:assertEquals(repo.events().map(e => e.idempotencyKey),
            ["RepostRequested:" + first.id + ":1", "RepostFailed:" + first.id + ":1", "RepostRequested:" + first.id + ":2"]);
}

@test:Config
function retryStillNeedsActiveConnection() returns error? {
    ShareRequest r = check newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, repost(), "s1", T0);
    ShareRequest failed = check markFailed(r, types:NEEDS_RECONNECT, (), T0);
    test:assertEquals(code(retryShare(failed, OPEN_CAMPAIGN, {memberUrn: "urn:li:person:abc", usable: false}, repost())),
            types:ERR_CONNECTION_NEEDS_RECONNECT);
}

@test:Config
function publishedShareCantBeRequestedAgain() returns error? {
    InMemoryShares repo = new;
    ShareRequest first = check requestShare(repo, OPEN_CAMPAIGN, ACTIVE_CONNECTION, repost(), T0);
    PublishResult published = check markPublished(first, "urn:li:share:7001", "urn:li:person:abc", "g1", T0);
    check repo.update(published.request, first.version, published.outbox);
    test:assertEquals(code(requestShare(repo, OPEN_CAMPAIGN, ACTIVE_CONNECTION, repost(), T0)), types:ERR_SHARE_ALREADY_PUBLISHED);
}

@test:Config
function lostConnectionFailsOnlyQueuedRequests() returns error? {
    ShareRequest queued = check newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, repost(), "s1", T0);
    ShareRequest? failed = failForLostConnection(queued, T0);
    test:assertTrue(failed is ShareRequest);
    if failed is ShareRequest {
        test:assertEquals(failed.failureReason, types:NEEDS_RECONNECT);
        test:assertEquals(failForLostConnection(failed, T0), (), "already failed: unchanged");
    }
    ShareRequest published = (check markPublished(queued, "urn:li:share:1", "urn:li:person:abc", "g1", T0)).request;
    test:assertEquals(failForLostConnection(published, T0), (), "published: unchanged");
}

// Domain review H-5: a publish that hit the engagement unique keys settles as PUBLISHED on the existing
// engagement, with no second engagement event (no double points).
@test:Config
function duplicatePublishSettlesOnTheExistingEngagement() returns error? {
    ShareRequest r = check newShareRequest(OPEN_CAMPAIGN, ACTIVE_CONNECTION, withThoughts(), "s1", T0);
    PublishResult result = check markPublished(r, "urn:li:share:7001", "urn:li:person:abc", "g-new", T0);
    ShareRequest settled = check asDuplicatePublish(result.cloneReadOnly(), "g-existing");
    test:assertEquals(shareStatus(settled), PUBLISHED);
    test:assertEquals(settled.engagementId, "g-existing");
    test:assertEquals(settled.version, r.version + 1);
    test:assertEquals(settled.commentary, ());
}
