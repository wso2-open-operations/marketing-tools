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
import amplify_domain.scoring;

import ballerina/time;

# Derived external share status (`external_sharing.external_share_v`). Never stored.
public enum ExternalShareStatus {
    PENDING,
    APPROVED,
    REJECTED,
    AMPLIFIED
}

# PO decision value (`decision` column). Named `DECISION_*` so it doesn't clash with the status enum.
public const DECISION_APPROVED = "APPROVED";
# PO decision value.
public const DECISION_REJECTED = "REJECTED";

# PO decision on a claim.
public type Decision DECISION_APPROVED|DECISION_REJECTED;

# External share aggregate (`external_sharing.external_share`, "My Campaign"): an employee's claim for
# promotion done outside Amplify. Unique per normalized `(evidenceUrl, action)` across all employees (C5).
public type ExternalShare record {|
    # UUIDv7
    string id;
    # Claimant
    types:EmployeeId employeeId;
    # Campaign, optional
    string? campaignId;
    # Action (phase 1: `OWN_POST`)
    types:ExternalAction action;
    # Evidence URL, normalized
    types:EvidenceUrl evidence;
    # "I certify this is related to WSO2"
    time:Utc certifiedAt;
    # `()` while pending
    Decision? decision;
    # PO who decided
    types:EmployeeId? decidedBy;
    # Decision time
    time:Utc? decidedAt;
    # Required on reject
    string? decisionReason;
    # Set by PO on an approved claim only (C4)
    time:Utc? amplifiedAt;
    # Insert time
    time:Utc createdAt;
    # Optimistic lock
    int version;
|};

# An employee's claim.
public type ExternalShareClaim record {|
    # Signed-in employee
    types:EmployeeId employeeId;
    # URL as typed
    string evidenceUrl;
    # Certification checkbox
    boolean certified;
    # Campaign, optional
    string? campaignId = ();
|};

# Persistence port for the `external_sharing` schema.
public type ExternalShareRepository isolated object {
    # Finds a claim by id.
    #
    # + id - Claim id
    # + return - The claim, `()` if none, or an error
    public isolated function findById(string id) returns ExternalShare|error?;

    # Whether anyone already claimed this normalized URL for this action.
    #
    # + normalizedUrl - Normalized evidence URL
    # + action - Action
    # + return - True if claimed, or an error
    public isolated function isClaimed(string normalizedUrl, types:ExternalAction action) returns boolean|error;

    # Inserts a claim with its events. The unique key backs up `isClaimed` under a race.
    #
    # + claim - New claim
    # + outbox - Events
    # + return - `EVIDENCE_ALREADY_CLAIMED` on the unique key, or another error
    public isolated function insert(ExternalShare claim, events:OutboxEvent[] outbox) returns error?;

    # Updates a claim if its stored version still equals `expectedVersion`.
    #
    # + claim - Changed claim
    # + expectedVersion - Version read before the change
    # + outbox - Events
    # + return - `VERSION_CONFLICT`, or another error
    public isolated function update(ExternalShare claim, int expectedVersion, events:OutboxEvent[] outbox) returns error?;

    # Updates a claim and appends its points award in one transaction (S3 → C2 "same transaction in api",
    # phase1-data-model › Domain events; ADR-024).
    #
    # + claim - Changed claim
    # + expectedVersion - Version read before the change
    # + outbox - Claim events
    # + award - Ledger row and event (`OWN_POST` award or the amplified top-up)
    # + return - `VERSION_CONFLICT`, or another error
    public isolated function updateWithAward(ExternalShare claim, int expectedVersion, events:OutboxEvent[] outbox,
            scoring:LedgerAppend award) returns error?;
};
