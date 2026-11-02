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

// Points for approved and amplified claims are written in the same API transaction as the decision
// (`approveWithPoints` / `amplifyWithPoints` → `updateWithAward`, ADR-024).

import amplify_common.types;
import amplify_domain.scoring;

import ballerina/time;

// ---- Derived status -------------------------------------------------------------------------------

# Claim status from its facts, as `external_share_v` computes it.
#
# + claim - External share
# + return - `PENDING` if undecided; `AMPLIFIED` if amplified; else the decision
public isolated function externalShareStatus(ExternalShare claim) returns ExternalShareStatus {
    Decision? decision = claim.decision;
    if decision is () {
        return PENDING;
    }
    if claim.amplifiedAt !is () {
        return AMPLIFIED;
    }
    return decision == DECISION_APPROVED ? APPROVED : REJECTED;
}

// ---- Aggregate rules (pure) -----------------------------------------------------------------------

# Builds a claim: the URL is validated and normalized (C5) and the certification box is required.
#
# + claim - The claim
# + id - New UUIDv7
# + now - Current time
# + return - The pending claim, or a domain error
public isolated function newExternalShare(ExternalShareClaim claim, string id, time:Utc now)
        returns ExternalShare|types:DomainError {
    if !claim.certified {
        return types:domainError(types:ERR_CERTIFICATION_REQUIRED, "Please confirm this is related to WSO2");
    }
    types:EvidenceUrl evidence = check types:parseEvidenceUrl(claim.evidenceUrl);
    return {
        id,
        employeeId: claim.employeeId,
        campaignId: claim.campaignId,
        action: types:OWN_POST,
        evidence,
        certifiedAt: now,
        decision: (),
        decidedBy: (),
        decidedAt: (),
        decisionReason: (),
        amplifiedAt: (),
        createdAt: now,
        version: 1
    };
}

# Approves a pending claim. A PO can't decide their own claim.
#
# + claim - Pending claim
# + poId - Deciding PO
# + now - Current time
# + return - The approved claim, or `NOT_PENDING` / `SELF_REVIEW`
public isolated function approve(ExternalShare claim, types:EmployeeId poId, time:Utc now)
        returns ExternalShare|types:DomainError {
    check ensureDecidable(claim, poId);
    ExternalShare approved = claim.clone();
    approved.decision = DECISION_APPROVED;
    approved.decidedBy = poId;
    approved.decidedAt = now;
    approved.version = claim.version + 1;
    return approved;
}

# Rejects a pending claim; a reason is required.
#
# + claim - Pending claim
# + poId - Deciding PO
# + reason - Why
# + now - Current time
# + return - The rejected claim, or `NOT_PENDING` / `SELF_REVIEW` / `REASON_REQUIRED`
public isolated function reject(ExternalShare claim, types:EmployeeId poId, string reason, time:Utc now)
        returns ExternalShare|types:DomainError {
    check ensureDecidable(claim, poId);
    string? trimmed = types:trimToNil(reason);
    if trimmed is () {
        return types:domainError(types:ERR_REASON_REQUIRED, "A reason is required to reject a claim");
    }
    ExternalShare rejected = claim.clone();
    rejected.decision = DECISION_REJECTED;
    rejected.decidedBy = poId;
    rejected.decidedAt = now;
    rejected.decisionReason = trimmed;
    rejected.version = claim.version + 1;
    return rejected;
}

# Marks an approved claim as amplified by WSO2 or a senior leader (C4). Only once, only after approval,
# and never by the claimant: marking pays the top-up, so a PO can't mark their own claim (same rule as
# the decision, threat model 5.6).
#
# + claim - Approved claim
# + now - Current time
# + markedBy - PO marking it; `()` skips the self-review check (callers that check it themselves)
# + return - The amplified claim, or `NOT_APPROVED` / `ALREADY_AMPLIFIED` / `SELF_REVIEW`
public isolated function markAmplified(ExternalShare claim, time:Utc now, types:EmployeeId? markedBy = ())
        returns ExternalShare|types:DomainError {
    if markedBy is types:EmployeeId && markedBy == claim.employeeId {
        return types:domainError(types:ERR_SELF_REVIEW, "You can't mark your own claim amplified");
    }
    if claim.amplifiedAt !is () {
        return types:domainError(types:ERR_ALREADY_AMPLIFIED, "This claim is already marked amplified");
    }
    if claim.decision != DECISION_APPROVED {
        return types:domainError(types:ERR_NOT_APPROVED, "Only an approved claim can be marked amplified");
    }
    ExternalShare amplified = claim.clone();
    amplified.amplifiedAt = now;
    amplified.version = claim.version + 1;
    return amplified;
}

// ---- Use cases ------------------------------------------------------------------------------------

# Submits a claim (`POST /external-shares`). One claim per normalized URL and action, across everyone.
#
# + repo - External share repository
# + claim - The claim
# + now - Current time
# + return - The pending claim, `EVIDENCE_ALREADY_CLAIMED`, another domain error, or a repository error
public isolated function submitExternalShare(ExternalShareRepository repo, ExternalShareClaim claim, time:Utc now)
        returns ExternalShare|error {
    ExternalShare share = check newExternalShare(claim, types:newUuidV7(), now);
    if check repo.isClaimed(share.evidence.normalized, share.action) {
        return evidenceAlreadyClaimed();
    }
    check repo.insert(share, [externalShareSubmittedEvent(share)]);
    return share;
}

# Approves a claim (`POST /po/external-shares/{id}/approve`).
#
# + repo - External share repository
# + id - Claim id
# + poId - Deciding PO (role checked by the API layer)
# + now - Current time
# + return - The approved claim, a domain error, or a repository error
public isolated function approveExternalShare(ExternalShareRepository repo, string id, types:EmployeeId poId, time:Utc now)
        returns ExternalShare|error {
    ExternalShare current = check findOrFail(repo, id);
    ExternalShare approved = check approve(current, poId, now);
    check repo.update(approved, current.version, [externalShareApprovedEvent(approved)]);
    return approved;
}

# Rejects a claim (`POST /po/external-shares/{id}/reject`).
#
# + repo - External share repository
# + id - Claim id
# + poId - Deciding PO
# + reason - Why
# + now - Current time
# + return - The rejected claim, a domain error, or a repository error
public isolated function rejectExternalShare(ExternalShareRepository repo, string id, types:EmployeeId poId,
        string reason, time:Utc now) returns ExternalShare|error {
    ExternalShare current = check findOrFail(repo, id);
    ExternalShare rejected = check reject(current, poId, reason, now);
    check repo.update(rejected, current.version, [externalShareRejectedEvent(rejected)]);
    return rejected;
}

# Marks a claim amplified (`POST /po/external-shares/{id}/amplified`).
#
# + repo - External share repository
# + id - Claim id
# + poId - PO marking it
# + now - Current time
# + return - The amplified claim, a domain error, or a repository error
public isolated function amplifyExternalShare(ExternalShareRepository repo, string id, types:EmployeeId poId, time:Utc now)
        returns ExternalShare|error {
    ExternalShare current = check findOrFail(repo, id);
    ExternalShare amplified = check markAmplified(current, now, poId);
    check repo.update(amplified, current.version, [externalShareAmplifiedEvent(amplified, poId)]);
    return amplified;
}

# Approves a claim and awards `OWN_POST` points in the same transaction.
#
# + repo - External share repository
# + rules - Point rule versions
# + id - Claim id
# + poId - Deciding PO
# + correlationId - Request correlation id
# + now - Current time
# + return - The approved claim, a domain error (incl. `RULE_NOT_FOUND`), or a repository error
public isolated function approveWithPoints(ExternalShareRepository repo, scoring:PointRule[] rules, string id,
        types:EmployeeId poId, string? correlationId, time:Utc now) returns ExternalShare|error {
    ExternalShare current = check findOrFail(repo, id);
    ExternalShare approved = check approve(current, poId, now);
    scoring:LedgerAppend award = check scoring:awardForExternalShare(rules, factOf(approved, now), correlationId, now);
    check repo.updateWithAward(approved, current.version, [externalShareApprovedEvent(approved)], award);
    return approved;
}

# Marks an approved claim amplified and appends the T4 top-up in the same transaction (C4). The top-up is
# priced against the `OWN_POST` points actually on the ledger, so a reversed own-post award is topped up to
# the full amplified tier instead of only the rule difference.
#
# + repo - External share repository
# + rules - Point rule versions
# + id - Claim id
# + poId - PO marking it
# + correlationId - Request correlation id
# + now - Current time
# + ledger - Ledger repository (reads the net `OWN_POST` points already awarded)
# + return - The amplified claim, a domain error, or a repository error
public isolated function amplifyWithPoints(ExternalShareRepository repo, scoring:PointRule[] rules, string id,
        types:EmployeeId poId, string? correlationId, time:Utc now, scoring:LedgerRepository ledger)
        returns ExternalShare|error {
    ExternalShare current = check findOrFail(repo, id);
    ExternalShare amplified = check markAmplified(current, now, poId);
    scoring:ExternalShareFact fact = factOf(amplified, amplified.decidedAt ?: now);
    int ownPostPoints = check scoring:ownPostNet(ledger, fact);
    scoring:LedgerAppend topUp = check scoring:amplifiedTopUp(rules, fact, ownPostPoints, correlationId, now);
    check repo.updateWithAward(amplified, current.version, [externalShareAmplifiedEvent(amplified, poId)], topUp);
    return amplified;
}

# The scoring fact for an approved claim.
#
# + claim - Approved claim
# + approvedAt - Approval time (pricing time)
# + return - The fact
public isolated function factOf(ExternalShare claim, time:Utc approvedAt) returns scoring:ExternalShareFact => {
    externalShareId: claim.id,
    provider: claim.evidence.provider,
    evidenceUrl: claim.evidence.normalized,
    employeeId: claim.employeeId,
    campaignId: claim.campaignId,
    approvedAt
};

// ---- Helpers --------------------------------------------------------------------------------------

# The error My Campaign turns into "Someone else already submitted this url, contact PO Team for review".
#
# + return - `EVIDENCE_ALREADY_CLAIMED`
public isolated function evidenceAlreadyClaimed() returns types:DomainError =>
    types:domainError(types:ERR_EVIDENCE_ALREADY_CLAIMED,
        "Someone else already submitted this url, contact PO Team for review");

isolated function ensureDecidable(ExternalShare claim, types:EmployeeId poId) returns types:DomainError? {
    if claim.decision !is () {
        return types:domainError(types:ERR_NOT_PENDING, "This claim was already decided");
    }
    if claim.employeeId == poId {
        return types:domainError(types:ERR_SELF_REVIEW, "You can't review your own claim");
    }
    return ();
}

isolated function findOrFail(ExternalShareRepository repo, string id) returns ExternalShare|error {
    ExternalShare? claim = check repo.findById(id);
    if claim is () {
        return types:domainError(types:ERR_NOT_FOUND, "External share not found");
    }
    return claim;
}
