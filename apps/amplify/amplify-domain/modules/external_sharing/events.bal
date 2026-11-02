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

// Events S3 publishes.

import amplify_common.events;
import amplify_common.types;

import ballerina/time;

# `ExternalShareSubmitted`.
#
# + claim - New claim
# + return - Outbox row
public isolated function externalShareSubmittedEvent(ExternalShare claim) returns events:OutboxEvent =>
    events:newExternalShareSubmitted({
        externalShareId: claim.id,
        employeeId: claim.employeeId,
        action: claim.action,
        evidenceHost: claim.evidence.host,
        provider: claim.evidence.provider,
        campaignId: claim.campaignId
    });

# `ExternalShareApproved`.
#
# + claim - Approved claim
# + return - Outbox row
public isolated function externalShareApprovedEvent(ExternalShare claim) returns events:OutboxEvent =>
    events:newExternalShareApproved({
        externalShareId: claim.id,
        employeeId: claim.employeeId,
        decidedBy: claim.decidedBy ?: "",
        decidedAt: timeText(claim.decidedAt),
        campaignId: claim.campaignId
    });

# `ExternalShareRejected`.
#
# + claim - Rejected claim
# + return - Outbox row
public isolated function externalShareRejectedEvent(ExternalShare claim) returns events:OutboxEvent =>
    events:newExternalShareRejected({
        externalShareId: claim.id,
        employeeId: claim.employeeId,
        decidedBy: claim.decidedBy ?: "",
        decidedAt: timeText(claim.decidedAt)
    });

# `ExternalShareAmplified`.
#
# + claim - Amplified claim
# + markedBy - PO who marked it
# + return - Outbox row
public isolated function externalShareAmplifiedEvent(ExternalShare claim, types:EmployeeId markedBy)
        returns events:OutboxEvent =>
    events:newExternalShareAmplified({
        externalShareId: claim.id,
        employeeId: claim.employeeId,
        markedBy,
        amplifiedAt: timeText(claim.amplifiedAt)
    });

isolated function timeText(time:Utc? t) returns string => t is () ? "" : time:utcToString(t);
