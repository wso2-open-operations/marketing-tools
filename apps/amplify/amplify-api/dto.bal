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


// Request and response bodies of the published API (openapi.yaml) and the mapping from domain records.
// Times are RFC 3339 strings. Requests are closed records, so unknown fields are a 400.

import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.external_sharing;
import amplify_domain.scoring;
import amplify_domain.sharing;

import ballerina/time;

// ---- Requests ---------------------------------------------------------------------------------------

# `POST /campaigns` body.
type CampaignDraftBody record {|
    string resourceUrn;
    string ownerUrn;
    string? resourceUrl = ();
    string title;
    string? summary = ();
    string? imageUrl = ();
    string categoryCode;
    boolean isPriority = false;
    string[] tags = [];
    string? opensAt = ();
    string? closesAt = ();
|};

# `PATCH /campaigns/{id}` body.
type CampaignPatchBody record {|
    int version;
    string? resourceUrn = ();
    string? resourceUrl = ();
    string? title = ();
    string? summary = ();
    string? imageUrl = ();
    string? categoryCode = ();
    boolean? isPriority = ();
    string[]? tags = ();
    string? opensAt = ();
    string? closesAt = ();
|};

# `POST /connections/linkedin/start` body.
type ConnectStartBody record {|
    string? returnTo = ();
    string? pendingCampaignId = ();
|};

# `POST /connections/linkedin/complete` body.
type ConnectCompleteBody record {|
    string code;
    string state;
    // Callback page the browser landed on (no query); must equal the configured redirect URI.
    string redirectUri;
|};

# `POST /connections/linkedin/decline` body.
type ConnectDeclineBody record {|
    // The person's LinkedIn profile URL, https://www.linkedin.com/in/<name>; optional
    string? profileUrl = ();
|};

# `POST /campaigns/{id}/shares` body.
type ShareBody record {|
    string kind;
    string? commentary = ();
|};

# `POST /external-shares` body.
type ExternalShareBody record {|
    # Any public HTTPS URL. Send this or `activityId`, not both.
    string? evidenceUrl = ();
    # A LinkedIn post number (digits). Amplify builds the canonical post URL from it.
    string? activityId = ();
    boolean certified;
    string? campaignId = ();
|};

# Reason body (reject, reverse).
type ReasonBody record {|
    string reason;
|};

# `POST /po/point-rules` body.
type PointRuleBody record {|
    string action;
    int points;
    string? effectiveFrom = ();
|};

# `POST /po/points/adjustments` body.
type AdjustmentBody record {|
    string employeeId;
    int points;
    string reason;
    string? campaignId = ();
|};

# `PUT /admin/settings` change.
type SettingChangeBody record {|
    string key;
    json value;
    int version;
|};

# `PUT /admin/settings` body.
type SettingChangesBody record {|
    SettingChangeBody[] changes;
|};

// ---- Responses ----------------------------------------------------------------------------------------

type CampaignDto record {|
    string id;
    string provider;
    string resourceUrn;
    string resourceType;
    string ownerUrn;
    string? resourceUrl;
    string title;
    string? summary;
    string? imageUrl;
    string categoryCode;
    boolean isPriority;
    string[] tags;
    string opensAt;
    string closesAt;
    string? archivedAt;
    string status;
    string createdBy;
    string createdAt;
    string updatedAt;
    int version;
|};

type ShareDto record {|
    string id;
    string campaignId;
    string kind;
    string status;
    string? failureReason;
    int attempts;
    string requestedAt;
    string? publishedAt;
    string? failedAt;
    json metrics = ();
|};

type ExternalShareDto record {|
    string id;
    string employeeId;
    string? campaignId;
    string action;
    string evidenceUrl;
    string evidenceHost;
    string evidenceProvider;
    string status;
    string? decidedBy;
    string? decidedAt;
    string? decisionReason;
    string? amplifiedAt;
    string createdAt;
    int version;
|};

type LedgerEntryDto record {|
    string reference;
    string employeeId;
    string? campaignId;
    string sourceType;
    string? action;
    int points;
    string? reason;
    string? reversesReference;
    string actorId;
    string createdAt;
    string? status;
|};

type PointRuleDto record {|
    string id;
    string action;
    int points;
    string effectiveFrom;
    string createdBy;
    string createdAt;
    boolean inForce;
|};

type AnnouncementDto record {|
    string campaignId;
    string status;
    string space;
    string queuedAt;
    string? sentAt;
    string? failedAt;
    string? lastError;
|};

isolated function ts(time:Utc t) returns string => time:utcToString(t);

isolated function tsOpt(time:Utc? t) returns string? => t is () ? () : time:utcToString(t);

isolated function campaignDto(campaign:Campaign c, time:Utc now) returns CampaignDto => {
    id: c.id,
    provider: c.provider,
    resourceUrn: c.resourceUrn,
    resourceType: c.resourceType,
    ownerUrn: c.ownerUrn,
    resourceUrl: c.resourceUrl,
    title: c.title,
    summary: c.summary,
    imageUrl: c.imageUrl,
    categoryCode: c.categoryCode,
    isPriority: c.isPriority,
    tags: c.tags,
    opensAt: ts(c.opensAt),
    closesAt: ts(c.closesAt),
    archivedAt: tsOpt(c.archivedAt),
    status: campaign:campaignStatus(c, now),
    createdBy: c.createdBy,
    createdAt: ts(c.createdAt),
    updatedAt: ts(c.updatedAt),
    version: c.version
};

isolated function shareDto(sharing:ShareRequest r) returns ShareDto => {
    id: r.id,
    campaignId: r.campaignId,
    kind: r.kind,
    status: sharing:shareStatus(r),
    failureReason: r.failureReason,
    attempts: r.attempts,
    requestedAt: ts(r.requestedAt),
    publishedAt: tsOpt(r.publishedAt),
    failedAt: tsOpt(r.failedAt)
};

isolated function shareViewDto(sharing:ShareView v) returns ShareDto => {
    id: v.id,
    campaignId: v.campaignId,
    kind: v.kind,
    status: v.status,
    failureReason: v.failureReason,
    attempts: v.attempts,
    requestedAt: ts(v.requestedAt),
    publishedAt: tsOpt(v.publishedAt),
    failedAt: tsOpt(v.failedAt)
};

isolated function externalShareDto(external_sharing:ExternalShare c) returns ExternalShareDto => {
    id: c.id,
    employeeId: c.employeeId,
    campaignId: c.campaignId,
    action: c.action,
    evidenceUrl: c.evidence.normalized,
    evidenceHost: c.evidence.host,
    evidenceProvider: c.evidence.provider,
    status: external_sharing:externalShareStatus(c),
    decidedBy: c.decidedBy,
    decidedAt: tsOpt(c.decidedAt),
    decisionReason: c.decisionReason,
    amplifiedAt: tsOpt(c.amplifiedAt),
    createdAt: ts(c.createdAt),
    version: c.version
};

isolated function ledgerDto(types:LedgerEntry e) returns LedgerEntryDto => {
    reference: e.reference,
    employeeId: e.employeeId,
    campaignId: e.campaignId,
    sourceType: e.sourceType,
    action: e.action,
    points: e.points,
    reason: e.reason,
    reversesReference: e.reversesReference,
    actorId: e.actorId,
    createdAt: ts(e.createdAt),
    status: e.status
};

# Label shown in place of a PO's free-text reason on adjustment and reversal rows.
const string PO_ADJUSTMENT_LABEL = "Adjusted by the PO team";

# A ledger row for someone who is not a PO. The PO's free-text reason and employee id stay internal (threat model
# 5.4): adjustment and reversal rows carry a fixed label and no `actorId`.
#
# + e - Ledger row
# + return - The row as JSON without `actorId`
isolated function ledgerDtoForTeammate(types:LedgerEntry e) returns json {
    map<json> row = <map<json>>ledgerDto(e).toJson();
    _ = row.remove("actorId");
    boolean byPo = e.sourceType == types:ADJUSTMENT || e.sourceType == types:REVERSAL;
    row["reason"] = byPo ? PO_ADJUSTMENT_LABEL : ();
    return row;
}

isolated function pointRuleDto(scoring:PointRule r, scoring:PointRule[] all, time:Utc now) returns PointRuleDto {
    scoring:PointRule|types:DomainError current = scoring:ruleInForce(all, r.action, now);
    return {
        id: r.id,
        action: r.action,
        points: r.points,
        effectiveFrom: ts(r.effectiveFrom),
        createdBy: r.createdBy,
        createdAt: ts(r.createdAt),
        inForce: current is scoring:PointRule && current.id == r.id
    };
}

isolated function announcementDto(announcements:Announcement a) returns AnnouncementDto => {
    campaignId: a.campaignId,
    status: announcements:announcementStatus(a),
    space: a.space,
    queuedAt: ts(a.queuedAt),
    sentAt: tsOpt(a.sentAt),
    failedAt: tsOpt(a.failedAt),
    lastError: a.lastError
};

# Parses an optional RFC 3339 time from a request.
#
# + value - Text, or `()`
# + 'field - Field name for the error
# + return - The time, `()`, or a `VALIDATION_FAILED` domain error
isolated function parseTime(string? value, string 'field) returns time:Utc?|types:DomainError {
    if value is () {
        return ();
    }
    time:Utc|time:Error t = time:utcFromString(value);
    if t is time:Error {
        return types:domainError(VALIDATION_FAILED, string `${'field} must be an RFC 3339 date-time`);
    }
    return t;
}

# Checks a UUID path or body value.
#
# + value - Text
# + 'field - Field name for the error
# + return - The value, or a `VALIDATION_FAILED` domain error
isolated function uuidOf(string value, string 'field) returns string|types:DomainError {
    if !re `[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}`.isFullMatch(value) {
        return types:domainError(VALIDATION_FAILED, string `${'field} must be a UUID`);
    }
    return value.toLowerAscii();
}

# Checks a string length.
#
# + value - Text, or `()`
# + max - Most characters
# + 'field - Field name
# + return - `()` or a `VALIDATION_FAILED` domain error
isolated function maxLen(string? value, int max, string 'field) returns types:DomainError? {
    if value is string && value.length() > max {
        return types:domainError(VALIDATION_FAILED, string `${'field} must be at most ${max} characters`);
    }
    return ();
}
