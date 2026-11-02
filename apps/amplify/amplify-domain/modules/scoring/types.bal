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

// The ledger row (`types:LedgerEntry`) and its reference live in amplify_common because amplify-jobs
// writes award rows too. Pricing and correction rules live here.

import amplify_common.events;
import amplify_common.types;

import ballerina/time;

# Point rule (`scoring.point_rule`): versioned by `effectiveFrom`, one row per action per effective time.
# The action is the tier. Past awards keep the value of the rule in force when they were priced.
public type PointRule record {|
    # UUIDv7
    string id;
    # Priced action
    types:PointAction action;
    # Points, zero or more
    int points;
    # From when this version applies
    time:Utc effectiveFrom;
    # PO who set it (ADR-011)
    types:EmployeeId createdBy;
    # Insert time
    time:Utc createdAt;
|};

# An engagement fact to price (from `EngagementRecorded`).
public type EngagementFact record {|
    # `engagement.id`
    string engagementId;
    # Provider
    types:Provider provider;
    # Resource acted on
    types:PostUrn targetResourceUrn;
    # Employee
    types:EmployeeId employeeId;
    # Action
    types:EngagementAction action;
    # Campaign, when known
    string? campaignId;
|};

# An approved external share to price.
public type ExternalShareFact record {|
    # `external_share.id`
    string externalShareId;
    # Detected provider of the evidence (`linkedin`, `medium`, `other`)
    string provider;
    # Normalized evidence URL
    string evidenceUrl;
    # Claimant
    types:EmployeeId employeeId;
    # Campaign, optional
    string? campaignId;
    # Approval time; pricing uses the rules in force then
    time:Utc approvedAt;
|};

# A ledger row plus the event to write with it.
public type LedgerAppend record {|
    # Row to insert
    types:LedgerEntry entry;
    # `PointsAwarded`, `PointsAdjusted` or `PointsReversed`
    events:OutboxEvent event;
|};

# Persistence port for `scoring.points_ledger`. Append-only: there is no update of facts, only `append`
# (`INSERT … ON CONFLICT (reference) DO NOTHING`) and the settlement-column update.
public type LedgerRepository isolated object {
    # Appends a row and its event in one transaction.
    #
    # + append - Row and event
    # + return - True if inserted, false if the reference already existed (idempotent re-run), or an error
    public isolated function append(LedgerAppend append) returns boolean|error;

    # Finds a row by reference.
    #
    # + reference - Ledger reference
    # + return - The row, `()` if none, or an error
    public isolated function findByReference(types:LedgerReference reference) returns types:LedgerEntry|error?;

    # Finds the reversal of a row.
    #
    # + reference - Reference of the original row
    # + return - The reversal row, `()` if none, or an error
    public isolated function findReversalOf(types:LedgerReference reference) returns types:LedgerEntry|error?;

    # Updates only the settlement columns (`status`, `status_changed_at`, `paid_at`, `coin_reference`).
    #
    # + reference - Ledger reference
    # + status - New status, `()` = action required
    # + changedAt - Change time
    # + return - An error on failure
    public isolated function updateSettlement(types:LedgerReference reference, types:LedgerStatus? status, time:Utc changedAt)
        returns error?;
};

# Persistence port for `scoring.point_rule`.
public type PointRuleRepository isolated object {
    # All versions of every rule.
    #
    # + return - Rules, or an error
    public isolated function all() returns PointRule[]|error;

    # Inserts a new rule version.
    #
    # + rule - New version
    # + return - An error (including the `(action, effective_from)` unique key)
    public isolated function insert(PointRule rule) returns error?;
};
