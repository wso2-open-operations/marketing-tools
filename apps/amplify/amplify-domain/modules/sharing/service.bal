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

import ballerina/time;

// ---- Derived status -------------------------------------------------------------------------------

# Share status from its facts, as `share_request_v` computes it.
#
# + request - Share request
# + return - `PUBLISHED` if published; `FAILED` if failed; else `QUEUED`
public isolated function shareStatus(ShareRequest request) returns ShareStatus {
    if request.publishedAt !is () {
        return PUBLISHED;
    }
    if request.failedAt !is () {
        return FAILED;
    }
    return QUEUED;
}

// ---- Aggregate rules (pure) -----------------------------------------------------------------------

# Builds a new share request. The campaign must be open and the connection usable.
#
# + campaign - Campaign snapshot
# + connection - Connection snapshot, `()` if the employee never connected
# + command - The request
# + id - New UUIDv7
# + now - Current time
# + return - The request (attempt 1), or a domain error
public isolated function newShareRequest(CampaignSnapshot campaign, ConnectionSnapshot? connection, ShareCommand command,
        string id, time:Utc now) returns ShareRequest|types:DomainError {
    check ensureShareable(campaign, connection);
    string? commentary = check validCommentary(command.kind, command.commentary);
    return {
        id,
        campaignId: campaign.id,
        employeeId: command.employeeId,
        provider: campaign.provider,
        providerApi: types:SHARE_ON_LINKEDIN,
        targetResourceUrn: campaign.resourceUrn,
        kind: command.kind,
        commentary,
        requestedAt: now,
        publishedAt: (),
        failedAt: (),
        failureReason: (),
        attempts: 1,
        lastErrorCode: (),
        engagementId: (),
        version: 1
    };
}

# Retries a failed request on the same row (C2, ADR-015): clears `failedAt` and `failureReason`, takes the
# new kind and commentary, bumps `attempts` and `version`. Only a `FAILED` request can be retried, and only
# with an open campaign and a usable connection.
#
# + request - Failed request
# + campaign - Campaign snapshot
# + connection - Connection snapshot
# + command - The new request
# + return - The re-queued request, or a domain error
public isolated function retryShare(ShareRequest request, CampaignSnapshot campaign, ConnectionSnapshot? connection,
        ShareCommand command) returns ShareRequest|types:DomainError {
    ShareStatus status = shareStatus(request);
    if status == PUBLISHED {
        return types:domainError(types:ERR_SHARE_ALREADY_PUBLISHED, "You already shared this campaign");
    }
    if status == QUEUED {
        return types:domainError(types:ERR_SHARE_ALREADY_QUEUED, "Your share is already on its way");
    }
    check ensureShareable(campaign, connection);
    ShareRequest retried = request.clone();
    retried.kind = command.kind;
    retried.commentary = check validCommentary(command.kind, command.commentary);
    retried.failedAt = ();
    retried.failureReason = ();
    retried.lastErrorCode = ();
    retried.attempts = request.attempts + 1;
    retried.version = request.version + 1;
    return retried;
}

# Guard the job runs right before calling LinkedIn, so a rerun never posts twice.
#
# + request - Share request
# + return - `SHARE_ALREADY_PUBLISHED` or `SHARE_NOT_QUEUED` unless it is `QUEUED`
public isolated function ensurePublishable(ShareRequest request) returns types:DomainError? {
    ShareStatus status = shareStatus(request);
    if status == PUBLISHED {
        return types:domainError(types:ERR_SHARE_ALREADY_PUBLISHED, "Already published");
    }
    if status == FAILED {
        return types:domainError(types:ERR_SHARE_NOT_QUEUED, "The request failed; it must be retried first");
    }
    return ();
}

# Records a successful publish: sets `publishedAt`, clears the commentary (privacy), links the engagement
# and builds the engagement fact plus `EngagementRecorded`.
#
# + request - Queued request
# + activityUrn - `x-restli-id` LinkedIn returned
# + actorMemberUrn - Member who posted
# + engagementId - New UUIDv7 for the engagement
# + now - Current time
# + return - The result, or a domain error if the request isn't queued
public isolated function markPublished(ShareRequest request, types:PostUrn activityUrn, types:MemberUrn actorMemberUrn,
        string engagementId, time:Utc now) returns PublishResult|types:DomainError {
    check ensurePublishable(request);
    ShareRequest published = request.clone();
    published.publishedAt = now;
    published.commentary = ();
    published.engagementId = engagementId;
    published.version = request.version + 1;
    Engagement engagement = {
        id: engagementId,
        provider: request.provider,
        providerApi: request.providerApi,
        origin: types:IN_APP,
        targetResourceUrn: request.targetResourceUrn,
        campaignId: request.campaignId,
        actorMemberUrn,
        employeeId: request.employeeId,
        action: request.kind,
        activityUrn,
        occurredAt: now,
        observedAt: now,
        lastVerifiedAt: (),
        deletedAt: ()
    };
    return {request: published, engagement, outbox: [engagementRecordedEvent(engagement)]};
}

# Settles a publish whose engagement was already recorded (the engagement unique keys fired: an earlier
# round already posted this target for this employee, or the same activity came back twice). The post went
# out, so the request is `PUBLISHED` and points at the engagement that already exists; no new engagement
# and no `EngagementRecorded`, so nothing is scored twice.
#
# + result - From `markPublished`
# + existingEngagementId - Id of the engagement already stored
# + return - The request to store, with no events, or an error
public isolated function asDuplicatePublish(PublishResult result, string existingEngagementId)
        returns ShareRequest|error {
    // `cloneWithType` makes a mutable copy even when `result` is read-only (it is, inside the gate);
    // `clone()` of a read-only value is the same read-only value.
    ShareRequest request = check result.request.cloneWithType();
    request.engagementId = existingEngagementId;
    return request;
}

# Records a failed publish.
#
# + request - Queued request
# + reason - Why
# + errorCode - Provider error code, if any
# + now - Current time
# + return - The failed request, or a domain error if it isn't queued
public isolated function markFailed(ShareRequest request, types:FailureReason reason, string? errorCode, time:Utc now)
        returns ShareRequest|types:DomainError {
    check ensurePublishable(request);
    ShareRequest failed = request.clone();
    failed.failedAt = now;
    failed.failureReason = reason;
    failed.lastErrorCode = errorCode;
    failed.version = request.version + 1;
    return failed;
}

# Reaction to `ConnectionRevoked` / `ConnectionRemoved`: an unpublished, queued request fails with
# `NEEDS_RECONNECT`. Published and already failed requests are left alone.
#
# + request - Share request
# + now - Current time
# + return - The failed request, or `()` when nothing changes
public isolated function failForLostConnection(ShareRequest request, time:Utc now) returns ShareRequest? {
    ShareRequest|types:DomainError failed = markFailed(request, types:NEEDS_RECONNECT, (), now);
    return failed is ShareRequest ? failed : ();
}

// ---- Use cases ------------------------------------------------------------------------------------

# Requests a share (`POST /campaigns/{id}/shares`). One row per campaign per employee: a new request
# inserts it, a request after `FAILED` retries the same row, anything else is refused.
#
# + repo - Share repository
# + campaign - Campaign snapshot
# + connection - Connection snapshot
# + command - The request
# + now - Current time
# + return - The queued request, a domain error, or a repository error
public isolated function requestShare(ShareRepository repo, CampaignSnapshot campaign, ConnectionSnapshot? connection,
        ShareCommand command, time:Utc now) returns ShareRequest|error {
    ShareRequest? existing = check repo.findByCampaignAndEmployee(campaign.id, command.employeeId);
    if existing is ShareRequest {
        ShareRequest retried = check retryShare(existing, campaign, connection, command);
        check repo.update(retried, existing.version, [repostRequestedEvent(retried)]);
        return retried;
    }
    ShareRequest request = check newShareRequest(campaign, connection, command, types:newUuidV7(), now);
    check repo.insert(request, [repostRequestedEvent(request)]);
    return request;
}

// ---- Helpers --------------------------------------------------------------------------------------

isolated function ensureShareable(CampaignSnapshot campaign, ConnectionSnapshot? connection) returns types:DomainError? {
    if !campaign.open {
        return types:domainError(types:ERR_CAMPAIGN_NOT_OPEN, "This campaign isn't open for sharing");
    }
    if connection is () || !connection.usable {
        return types:domainError(types:ERR_CONNECTION_NEEDS_RECONNECT, "Connect your LinkedIn account first");
    }
    return ();
}

isolated function validCommentary(types:ShareKind kind, string? raw) returns string?|types:DomainError {
    string? commentary = types:trimToNil(raw);
    if types:hasCommentary(kind) {
        if commentary is () {
            return types:domainError(types:ERR_COMMENTARY_REQUIRED, "Add your thoughts, or choose a plain repost");
        }
        if commentary.length() > COMMENTARY_MAX_LENGTH {
            return types:domainError(types:ERR_COMMENTARY_TOO_LONG,
                    string `Your thoughts must be at most ${COMMENTARY_MAX_LENGTH} characters`);
        }
        return commentary;
    }
    if commentary !is () {
        return types:domainError(types:ERR_COMMENTARY_NOT_ALLOWED, "A plain repost has no commentary");
    }
    return ();
}
