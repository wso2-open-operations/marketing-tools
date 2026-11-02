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

// Events C1 publishes. Payloads never carry the commentary.

import amplify_common.events;
import amplify_common.types;

import ballerina/time;

# `RepostRequested` for a new share or a retry (key `share_request.id` + `attempts`).
#
# + request - Queued request
# + return - Outbox row
public isolated function repostRequestedEvent(ShareRequest request) returns events:OutboxEvent =>
    events:newRepostRequested({
        shareRequestId: request.id,
        campaignId: request.campaignId,
        employeeId: request.employeeId,
        kind: request.kind,
        targetResourceUrn: request.targetResourceUrn,
        attempts: request.attempts
    });

# `EngagementRecorded` for a published share.
#
# + engagement - New engagement
# + return - Outbox row
public isolated function engagementRecordedEvent(Engagement engagement) returns events:OutboxEvent =>
    events:newEngagementRecorded({
        engagementId: engagement.id,
        provider: engagement.provider,
        targetResourceUrn: engagement.targetResourceUrn,
        campaignId: engagement.campaignId,
        employeeId: engagement.employeeId,
        action: engagement.action,
        occurredAt: time:utcToString(engagement.occurredAt)
    });

# `RepostFailed` for a failed share.
#
# + request - Failed request
# + return - Outbox row
public isolated function repostFailedEvent(ShareRequest request) returns events:OutboxEvent =>
    events:newRepostFailed({
        shareRequestId: request.id,
        campaignId: request.campaignId,
        employeeId: request.employeeId,
        attempts: request.attempts,
        failureReason: request.failureReason ?: types:RETRIES_EXHAUSTED,
        errorCode: request.lastErrorCode
    });
