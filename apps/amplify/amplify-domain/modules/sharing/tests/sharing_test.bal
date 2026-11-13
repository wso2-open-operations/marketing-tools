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

final CampaignSnapshot INTEGRATOR = {
    id: "c1",
    provider: types:LINKEDIN,
    resourceUrn: "urn:li:share:6999",
    open: true,
    title: "WSO2 Integrator 5.1 is here",
    summary: "Faster builds, new AI connectors and a fresh low-code designer."
};

function thoughtsOn(CampaignSnapshot campaign, string text, int minOwnWords = 5) returns string =>
    code(newShareRequest(campaign, ACTIVE_CONNECTION, withThoughts(text), "s1", T0, minOwnWords));

@test:Config
function thoughtsCopiedFromThePostAreRefused() {
    // The title pasted back (what the console script sent), with case and punctuation changed.
    test:assertEquals(thoughtsOn(INTEGRATOR, "WSO2 Integrator 5.1 is here"), types:ERR_COMMENTARY_NOT_OWN_WORDS);
    test:assertEquals(thoughtsOn(INTEGRATOR, "wso2 INTEGRATOR 5.1 is here!!!"), types:ERR_COMMENTARY_NOT_OWN_WORDS);
    // Title and summary words, hashtags of them and a link add nothing of their own.
    test:assertEquals(thoughtsOn(INTEGRATOR, "#WSO2 #Integrator: new AI connectors, faster builds https://wso2.com/x"),
            types:ERR_COMMENTARY_NOT_OWN_WORDS);
    // Repeats and one-character words don't count: "great" is the only word of their own.
    test:assertEquals(thoughtsOn(INTEGRATOR, "great great great a b c d e WSO2 Integrator"),
            types:ERR_COMMENTARY_NOT_OWN_WORDS);
    // A row of hashtags or mentions isn't thoughts, even when their words aren't in the post.
    test:assertEquals(thoughtsOn(INTEGRATOR, "#excellent #proud #teamwork #shipping #congratulations"),
            types:ERR_COMMENTARY_NOT_OWN_WORDS);
    test:assertEquals(thoughtsOn(INTEGRATOR, "@alice @bob @carol @dave @erin WSO2 Integrator"),
            types:ERR_COMMENTARY_NOT_OWN_WORDS);
    // Case outside ASCII doesn't matter either: a French title pasted back in capitals.
    CampaignSnapshot french = {id: "c2", provider: types:LINKEDIN, resourceUrn: "urn:li:share:7001", open: true,
        title: "équipe école été élève énergie"};
    test:assertEquals(thoughtsOn(french, "ÉQUIPE ÉCOLE ÉTÉ ÉLÈVE ÉNERGIE"), types:ERR_COMMENTARY_NOT_OWN_WORDS);
}

@test:Config
function thoughtsNeedTheMinimumOfTheirOwnWords() {
    // Four of their own (proud, of, our, team): one short of five.
    test:assertEquals(thoughtsOn(INTEGRATOR, "Proud of our team. WSO2 Integrator 5.1 is here"),
            types:ERR_COMMENTARY_NOT_OWN_WORDS);
    // Six of their own.
    test:assertEquals(thoughtsOn(INTEGRATOR, "Proud of our team, worth trying the new WSO2 Integrator"), "OK");
    // The threshold is the caller's: four is enough at four, and 0 turns the check off.
    test:assertEquals(thoughtsOn(INTEGRATOR, "Proud of our team. WSO2 Integrator 5.1 is here", 4), "OK");
    test:assertEquals(thoughtsOn(INTEGRATOR, "WSO2 Integrator 5.1 is here", 0), "OK");
    test:assertEquals(code(newShareRequest(INTEGRATOR, ACTIVE_CONNECTION, withThoughts("WSO2 Integrator"), "s1", T0)),
            "OK", "off unless the caller asks for it");
    // Letters outside ASCII are words too.
    test:assertEquals(thoughtsOn(INTEGRATOR, "Très fier de notre équipe à Colombo"), "OK");
}

@test:Config
function ownWordsCountDistinctWordsOutsideThePost() {
    test:assertEquals(ownWordCount("WSO2 Integrator 5.1 is here", INTEGRATOR), 0);
    test:assertEquals(ownWordCount("Proud of our team, proud of our team!", INTEGRATOR), 4);
    CampaignSnapshot noSummary = {id: "c1", provider: types:LINKEDIN, resourceUrn: "urn:li:share:6999", open: true};
    test:assertEquals(ownWordCount("Great news everyone", noSummary), 3);
    // Hashtags and mentions add nothing, but the words around them still count.
    test:assertEquals(ownWordCount("Proud of our team #proud @alice", INTEGRATOR), 4);
    test:assertEquals(ownWordCount("Ελληνικά ΚΑΛΆ ΝΈΑ καλά νέα", noSummary), 3);
}

@test:Config
function retryChecksTheNewThoughts() returns error? {
    ShareRequest first = check newShareRequest(INTEGRATOR, ACTIVE_CONNECTION, repost(), "s1", T0, 5);
    ShareRequest failed = check markFailed(first, types:PROVIDER_REJECTED, "422", T0);
    test:assertEquals(code(retryShare(failed, INTEGRATOR, ACTIVE_CONNECTION, withThoughts("WSO2 Integrator 5.1"), 5)),
            types:ERR_COMMENTARY_NOT_OWN_WORDS);
    InMemoryShares repo = new;
    test:assertEquals(code(requestShare(repo, INTEGRATOR, ACTIVE_CONNECTION, withThoughts("WSO2 Integrator"), T0, 5)),
            types:ERR_COMMENTARY_NOT_OWN_WORDS);
    test:assertEquals(repo.count(), 0, "a refused share stores nothing");
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
