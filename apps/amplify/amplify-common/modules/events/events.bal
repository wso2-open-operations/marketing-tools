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

// Domain events: one record per row of the catalogue in phase1-data-model › "Domain events → which table
// changes" (B9). Every event becomes a `messaging.outbox` row written in the producer's transaction.
// `EngagementDeleted` is a future phase (ADR-018) and `EmployeeErased` is not in phase 1 (C3), so neither
// is here. Payloads never hold tokens or commentary. Times are RFC 3339 UTC strings.

import amplify_common.types;

import ballerina/time;

// ---- Event types (outbox `event_type`) ------------------------------------------------------------

public const CAMPAIGN_REGISTERED = "CampaignRegistered";
public const CAMPAIGN_ANNOUNCED = "CampaignAnnounced";
public const CONNECTION_READY = "ConnectionReady";
public const CONNECTION_REVOKED = "ConnectionRevoked";
public const CONNECTION_REMOVED = "ConnectionRemoved";
public const REPOST_REQUESTED = "RepostRequested";
public const ENGAGEMENT_RECORDED = "EngagementRecorded";
public const REPOST_FAILED = "RepostFailed";
public const EXTERNAL_SHARE_SUBMITTED = "ExternalShareSubmitted";
public const EXTERNAL_SHARE_APPROVED = "ExternalShareApproved";
public const EXTERNAL_SHARE_REJECTED = "ExternalShareRejected";
public const EXTERNAL_SHARE_AMPLIFIED = "ExternalShareAmplified";
public const POINTS_AWARDED = "PointsAwarded";
public const POINTS_ADJUSTED = "PointsAdjusted";
public const POINTS_REVERSED = "PointsReversed";

# Outbox `event_type`.
public type EventType CAMPAIGN_REGISTERED|CAMPAIGN_ANNOUNCED|CONNECTION_READY|CONNECTION_REVOKED|CONNECTION_REMOVED
    |REPOST_REQUESTED|ENGAGEMENT_RECORDED|REPOST_FAILED|EXTERNAL_SHARE_SUBMITTED|EXTERNAL_SHARE_APPROVED
    |EXTERNAL_SHARE_REJECTED|EXTERNAL_SHARE_AMPLIFIED|POINTS_AWARDED|POINTS_ADJUSTED|POINTS_REVERSED;

// ---- Aggregate types (outbox `aggregate_type`) -----------------------------------------------------

public const string AGG_CAMPAIGN = "campaign";
public const string AGG_ANNOUNCEMENT = "announcement";
public const string AGG_MEMBER_CONNECTION = "member_connection";
public const string AGG_SHARE_REQUEST = "share_request";
public const string AGG_ENGAGEMENT = "engagement";
public const string AGG_EXTERNAL_SHARE = "external_share";
public const string AGG_POINTS_LEDGER = "points_ledger";

// ---- Payloads -------------------------------------------------------------------------------------

# S1: a campaign was saved (Save, or Save & Share Now).
public type CampaignRegistered record {|
    # Campaign id
    string campaignId;
    # Provider
    types:Provider provider;
    # Campaign resource URN
    types:PostUrn resourceUrn;
    # Campaign title
    string title;
    # Priority flag
    boolean isPriority;
    # True for Save & Share Now: announce on this run, not the next scheduled one
    boolean shareNow;
    # Window start
    string opensAt;
|};

# S5: the Club card was sent.
public type CampaignAnnounced record {|
    # Campaign id
    string campaignId;
    # Outbox id of the `CampaignRegistered` row that triggered the card
    int outboxId;
    # Chat message name returned by the webhook
    string chatMessageName;
    # When the card was sent
    string sentAt;
|};

# S2: OAuth completed or the employee reconnected.
public type ConnectionReady record {|
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # Provider
    types:Provider provider;
    # LinkedIn member URN
    types:MemberUrn memberUrn;
    # Connection time
    string connectedAt;
    # Access token expiry
    string accessExpiresAt;
|};

# S2: LinkedIn returned 401, or consent was withdrawn.
public type ConnectionRevoked record {|
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # Provider
    types:Provider provider;
    # LinkedIn member URN
    types:MemberUrn memberUrn;
    # Revocation time
    string revokedAt;
|};

# S2: the employee removed the connection.
public type ConnectionRemoved record {|
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # Provider
    types:Provider provider;
    # LinkedIn member URN
    types:MemberUrn memberUrn;
    # Removal time
    string removedAt;
|};

# C1: a new share, or a retry of a failed one on the same row (ADR-015).
public type RepostRequested record {|
    # Share request id
    string shareRequestId;
    # Campaign id
    string campaignId;
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # Share kind
    types:ShareKind kind;
    # Resource being shared
    types:PostUrn targetResourceUrn;
    # Request attempt, starting at 1
    int attempts;
|};

# C1: the share was published and the engagement fact recorded.
public type EngagementRecorded record {|
    # Engagement id
    string engagementId;
    # Provider
    types:Provider provider;
    # Resource being shared
    types:PostUrn targetResourceUrn;
    # Campaign id
    string? campaignId;
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # Action
    types:EngagementAction action;
    # When it happened
    string occurredAt;
|};

# C1: the share failed.
public type RepostFailed record {|
    # Share request id
    string shareRequestId;
    # Campaign id
    string campaignId;
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # Request attempt, starting at 1
    int attempts;
    # Why it failed
    types:FailureReason failureReason;
    # Provider error code, if any
    string? errorCode;
|};

# S3: an employee claimed an external share.
public type ExternalShareSubmitted record {|
    # External share id
    string externalShareId;
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # Action
    types:ExternalAction action;
    # Evidence URL host
    string evidenceHost;
    # Provider
    string provider;
    # Campaign id
    string? campaignId;
|};

# S3: PO approved the claim.
public type ExternalShareApproved record {|
    # External share id
    string externalShareId;
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # PO who decided
    types:EmployeeId decidedBy;
    # Decision time
    string decidedAt;
    # Campaign id
    string? campaignId;
|};

# S3: PO rejected the claim.
public type ExternalShareRejected record {|
    # External share id
    string externalShareId;
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # PO who decided
    types:EmployeeId decidedBy;
    # Decision time
    string decidedAt;
|};

# S3: PO marked an approved claim as amplified (C4).
public type ExternalShareAmplified record {|
    # External share id
    string externalShareId;
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # PO who marked it
    types:EmployeeId markedBy;
    # When it was marked amplified
    string amplifiedAt;
|};

# C2: a ledger row was appended (award, adjustment or reversal).
public type PointsChanged record {|
    # Ledger reference
    types:LedgerReference reference;
    # Employee (IdP `sub`)
    types:EmployeeId employeeId;
    # Signed points
    int points;
    # Action
    types:PointAction? action;
    # Campaign id
    string? campaignId;
    # Row this reversal cancels
    types:LedgerReference? reversesReference;
    # Insert time
    string createdAt;
|};

# Any event payload.
public type EventPayload CampaignRegistered|CampaignAnnounced|ConnectionReady|ConnectionRevoked|ConnectionRemoved
    |RepostRequested|EngagementRecorded|RepostFailed|ExternalShareSubmitted|ExternalShareApproved
    |ExternalShareRejected|ExternalShareAmplified|PointsChanged;

# One outbox row before insert. `idempotency_key` is unique, so it is `<event_type>:<catalogue key>`;
# the event-type prefix stops two events of one aggregate (for example `RepostRequested` and
# `RepostFailed`, both keyed `share_request.id` + `attempts`) from colliding.
public type OutboxEvent record {|
    # Outbox `aggregate_type`
    string aggregateType;
    # Outbox `aggregate_id`
    string aggregateId;
    # Outbox `event_type`
    EventType eventType;
    # Event payload (`jsonb`)
    EventPayload payload;
    # Unique outbox key
    string idempotencyKey;
|};

# Builds the idempotency key for an event.
#
# + eventType - Event type
# + parts - Catalogue key parts, in catalogue order
# + return - `<event_type>:<part>[:<part>]`
public isolated function idempotencyKey(EventType eventType, string... parts) returns string =>
    eventType + ":" + string:'join(":", ...parts);

// ---- Builders, one per catalogue row (idempotency key from the catalogue) --------------------------

# + payload - Event payload
# + return - Outbox row, key `campaign.id`
public isolated function newCampaignRegistered(CampaignRegistered payload) returns OutboxEvent => {
    aggregateType: AGG_CAMPAIGN,
    aggregateId: payload.campaignId,
    eventType: CAMPAIGN_REGISTERED,
    payload,
    idempotencyKey: idempotencyKey(CAMPAIGN_REGISTERED, payload.campaignId)
};

# + payload - Event payload
# + return - Outbox row, key `outbox.id`
public isolated function newCampaignAnnounced(CampaignAnnounced payload) returns OutboxEvent => {
    aggregateType: AGG_ANNOUNCEMENT,
    aggregateId: payload.campaignId,
    eventType: CAMPAIGN_ANNOUNCED,
    payload,
    idempotencyKey: idempotencyKey(CAMPAIGN_ANNOUNCED, payload.outboxId.toString())
};

# + payload - Event payload
# + return - Outbox row, key `member_urn` + `connected_at`
public isolated function newConnectionReady(ConnectionReady payload) returns OutboxEvent => {
    aggregateType: AGG_MEMBER_CONNECTION,
    aggregateId: payload.employeeId,
    eventType: CONNECTION_READY,
    payload,
    idempotencyKey: idempotencyKey(CONNECTION_READY, payload.memberUrn, payload.connectedAt)
};

# + payload - Event payload
# + return - Outbox row, key `member_urn` + `revoked_at`
public isolated function newConnectionRevoked(ConnectionRevoked payload) returns OutboxEvent => {
    aggregateType: AGG_MEMBER_CONNECTION,
    aggregateId: payload.employeeId,
    eventType: CONNECTION_REVOKED,
    payload,
    idempotencyKey: idempotencyKey(CONNECTION_REVOKED, payload.memberUrn, payload.revokedAt)
};

# + payload - Event payload
# + return - Outbox row, key `member_urn` + `removed_at`
public isolated function newConnectionRemoved(ConnectionRemoved payload) returns OutboxEvent => {
    aggregateType: AGG_MEMBER_CONNECTION,
    aggregateId: payload.employeeId,
    eventType: CONNECTION_REMOVED,
    payload,
    idempotencyKey: idempotencyKey(CONNECTION_REMOVED, payload.memberUrn, payload.removedAt)
};

# + payload - Event payload
# + return - Outbox row, key `share_request.id` + `attempts`
public isolated function newRepostRequested(RepostRequested payload) returns OutboxEvent => {
    aggregateType: AGG_SHARE_REQUEST,
    aggregateId: payload.shareRequestId,
    eventType: REPOST_REQUESTED,
    payload,
    idempotencyKey: idempotencyKey(REPOST_REQUESTED, payload.shareRequestId, payload.attempts.toString())
};

# + payload - Event payload
# + return - Outbox row, key `engagement.id`
public isolated function newEngagementRecorded(EngagementRecorded payload) returns OutboxEvent => {
    aggregateType: AGG_ENGAGEMENT,
    aggregateId: payload.engagementId,
    eventType: ENGAGEMENT_RECORDED,
    payload,
    idempotencyKey: idempotencyKey(ENGAGEMENT_RECORDED, payload.engagementId)
};

# + payload - Event payload
# + return - Outbox row, key `share_request.id` + `attempts`
public isolated function newRepostFailed(RepostFailed payload) returns OutboxEvent => {
    aggregateType: AGG_SHARE_REQUEST,
    aggregateId: payload.shareRequestId,
    eventType: REPOST_FAILED,
    payload,
    idempotencyKey: idempotencyKey(REPOST_FAILED, payload.shareRequestId, payload.attempts.toString())
};

# + payload - Event payload
# + return - Outbox row, key `external_share.id`
public isolated function newExternalShareSubmitted(ExternalShareSubmitted payload) returns OutboxEvent => {
    aggregateType: AGG_EXTERNAL_SHARE,
    aggregateId: payload.externalShareId,
    eventType: EXTERNAL_SHARE_SUBMITTED,
    payload,
    idempotencyKey: idempotencyKey(EXTERNAL_SHARE_SUBMITTED, payload.externalShareId)
};

# + payload - Event payload
# + return - Outbox row, key `external_share.id`
public isolated function newExternalShareApproved(ExternalShareApproved payload) returns OutboxEvent => {
    aggregateType: AGG_EXTERNAL_SHARE,
    aggregateId: payload.externalShareId,
    eventType: EXTERNAL_SHARE_APPROVED,
    payload,
    idempotencyKey: idempotencyKey(EXTERNAL_SHARE_APPROVED, payload.externalShareId)
};

# + payload - Event payload
# + return - Outbox row, key `external_share.id`
public isolated function newExternalShareRejected(ExternalShareRejected payload) returns OutboxEvent => {
    aggregateType: AGG_EXTERNAL_SHARE,
    aggregateId: payload.externalShareId,
    eventType: EXTERNAL_SHARE_REJECTED,
    payload,
    idempotencyKey: idempotencyKey(EXTERNAL_SHARE_REJECTED, payload.externalShareId)
};

# + payload - Event payload
# + return - Outbox row, key `external_share.id` + `AMPLIFIED`
public isolated function newExternalShareAmplified(ExternalShareAmplified payload) returns OutboxEvent => {
    aggregateType: AGG_EXTERNAL_SHARE,
    aggregateId: payload.externalShareId,
    eventType: EXTERNAL_SHARE_AMPLIFIED,
    payload,
    idempotencyKey: idempotencyKey(EXTERNAL_SHARE_AMPLIFIED, payload.externalShareId, "AMPLIFIED")
};

# Builds `PointsAwarded`, `PointsAdjusted` or `PointsReversed` from the ledger row's source type.
#
# + entry - Ledger row just appended
# + return - Outbox row, key ledger `reference`
public isolated function newPointsChanged(types:LedgerEntry entry) returns OutboxEvent {
    EventType eventType = entry.sourceType == types:ADJUSTMENT ? POINTS_ADJUSTED
        : entry.sourceType == types:REVERSAL ? POINTS_REVERSED : POINTS_AWARDED;
    return {
        aggregateType: AGG_POINTS_LEDGER,
        aggregateId: entry.reference,
        eventType,
        payload: <PointsChanged>{
            reference: entry.reference,
            employeeId: entry.employeeId,
            points: entry.points,
            action: entry.action,
            campaignId: entry.campaignId,
            reversesReference: entry.reversesReference,
            createdAt: time:utcToString(entry.createdAt)
        },
        idempotencyKey: idempotencyKey(eventType, entry.reference)
    };
}
