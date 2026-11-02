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

import ballerina/time;

# Derived share status (`sharing.share_request_v`, B14). There is no `PENDING` share state.
public enum ShareStatus {
    QUEUED,
    PUBLISHED,
    FAILED
}

# Longest commentary accepted (LinkedIn's post text limit).
public const int COMMENTARY_MAX_LENGTH = 3000;

# Share request aggregate (`sharing.share_request`): the command "Amplify, share this for me".
# Unique per `(campaignId, employeeId)` in phase 1 (B3); a retry after `FAILED` reuses the row (C2, ADR-015).
public type ShareRequest record {|
    # UUIDv7
    string id;
    # Campaign
    string campaignId;
    # Employee
    types:EmployeeId employeeId;
    # Provider
    types:Provider provider;
    # API product used to post
    types:ProviderApi providerApi;
    # Campaign resource being shared
    types:PostUrn targetResourceUrn;
    # Share kind; sets the tier
    types:ShareKind kind;
    # Employee's words; cleared once published
    string? commentary;
    # First request time
    time:Utc requestedAt;
    # Published fact
    time:Utc? publishedAt;
    # Failed fact
    time:Utc? failedAt;
    # Why it failed
    types:FailureReason? failureReason;
    # Request round, starting at 1; bumped by each retry
    int attempts;
    # Last provider error code
    string? lastErrorCode;
    # Engagement recorded on publish
    string? engagementId;
    # Optimistic lock
    int version;
|};

# Engagement fact (`sharing.engagement`): what an employee did on a provider resource. Scoring reads these,
# never share requests. Unique per `(provider, targetResourceUrn, employeeId, action)`.
public type Engagement record {|
    # UUIDv7
    string id;
    # Provider
    types:Provider provider;
    # API product the fact came from
    types:ProviderApi providerApi;
    # Where it came from (phase 1: `IN_APP`)
    types:EngagementOrigin origin;
    # Resource acted on
    types:PostUrn targetResourceUrn;
    # Campaign, when known
    string? campaignId;
    # Member who acted
    types:MemberUrn actorMemberUrn;
    # Employee who acted
    types:EmployeeId employeeId;
    # Action
    types:EngagementAction action;
    # Provider id of the repost (`x-restli-id`)
    types:PostUrn? activityUrn;
    # When it happened
    time:Utc occurredAt;
    # When Amplify saw it
    time:Utc observedAt;
    # Last verification (future phase, ADR-018)
    time:Utc? lastVerifiedAt;
    # Verified gone (future phase)
    time:Utc? deletedAt;
|};

# What sharing needs to know about the campaign (from S1, read through its own port).
public type CampaignSnapshot record {|
    # Campaign id
    string id;
    # Provider
    types:Provider provider;
    # Campaign resource
    types:PostUrn resourceUrn;
    # True while the campaign is `OPEN`
    boolean open;
|};

# What sharing needs to know about the employee's connection (from S2).
public type ConnectionSnapshot record {|
    # Member URN
    types:MemberUrn memberUrn;
    # True when `ACTIVE` or `EXPIRING`
    boolean usable;
|};

# An employee's share request.
public type ShareCommand record {|
    # Signed-in employee
    types:EmployeeId employeeId;
    # Share kind
    types:ShareKind kind;
    # Employee's words, required for the `*_COMMENTARY` kinds
    string? commentary = ();
|};

# Outcome of a publish: the published request and its engagement fact.
public type PublishResult record {|
    # Published request (commentary cleared)
    ShareRequest request;
    # New engagement fact
    Engagement engagement;
    # `EngagementRecorded`
    events:OutboxEvent[] outbox;
|};

# Persistence port for the `sharing` schema.
public type ShareRepository isolated object {
    # Finds the employee's request for a campaign.
    #
    # + campaignId - Campaign
    # + employeeId - Employee
    # + return - The request, `()` if none, or an error
    public isolated function findByCampaignAndEmployee(string campaignId, types:EmployeeId employeeId) returns ShareRequest|error?;

    # Inserts a new request with its events.
    #
    # + request - New request
    # + outbox - Events
    # + return - An error on failure (including the `(campaign_id, employee_id)` unique key)
    public isolated function insert(ShareRequest request, events:OutboxEvent[] outbox) returns error?;

    # Updates a request if its stored version still equals `expectedVersion`.
    #
    # + request - Changed request
    # + expectedVersion - Version read before the change
    # + outbox - Events
    # + return - `VERSION_CONFLICT`, or another error
    public isolated function update(ShareRequest request, int expectedVersion, events:OutboxEvent[] outbox) returns error?;
};
