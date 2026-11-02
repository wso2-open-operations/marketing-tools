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

// ---- Point rules ----------------------------------------------------------------------------------

# The rule version in force for an action at a time: the latest `effectiveFrom` not after `at`.
#
# + rules - All rule versions
# + action - Action to price
# + at - Pricing time
# + return - The rule, or `RULE_NOT_FOUND`
public isolated function ruleInForce(PointRule[] rules, types:PointAction action, time:Utc at)
        returns PointRule|types:DomainError {
    PointRule? best = ();
    foreach PointRule rule in rules {
        if rule.action != action || types:isBefore(at, rule.effectiveFrom) {
            continue;
        }
        if best is () || types:isBefore(best.effectiveFrom, rule.effectiveFrom) {
            best = rule;
        }
    }
    if best is () {
        return types:domainError(types:ERR_RULE_NOT_FOUND, string `No point rule for ${action}`);
    }
    return best;
}

# Builds a new rule version. Points are zero or more; a version can't be backdated (past awards keep
# their value) and can't repeat an existing `(action, effectiveFrom)`.
#
# + rules - Existing versions
# + action - Action
# + points - Points
# + effectiveFrom - Start; `()` = now
# + actor - PO (ADR-011)
# + id - New UUIDv7
# + now - Current time
# + return - The new version, or a domain error
public isolated function newRuleVersion(PointRule[] rules, types:PointAction action, int points, time:Utc? effectiveFrom,
        types:EmployeeId actor, string id, time:Utc now) returns PointRule|types:DomainError {
    if points < 0 {
        return types:domainError(types:ERR_INVALID_POINTS, "Points can't be negative");
    }
    time:Utc 'from = effectiveFrom ?: now;
    if types:isBefore('from, now) {
        return types:domainError(types:ERR_RULE_BACKDATED, "A rule change applies from now on, not to the past");
    }
    foreach PointRule rule in rules {
        if rule.action == action && rule.effectiveFrom == 'from {
            return types:domainError(types:ERR_RULE_VERSION_EXISTS, "A version already starts at that time");
        }
    }
    return {id, action, points, effectiveFrom: 'from, createdBy: actor, createdAt: now};
}

// ---- Ledger rows (pure) ---------------------------------------------------------------------------

# Award row for an engagement (C1 → C2): `AMP-` reference, `HELD`, priced at the rule in force now
# (a rule change applies from the next scoring pass).
#
# + rules - Rule versions
# + fact - Engagement
# + correlationId - Run correlation id
# + now - Engagement time: picks the rule version and stamps the row
# + return - Row and event, or a domain error
public isolated function awardForEngagement(PointRule[] rules, EngagementFact fact, string? correlationId, time:Utc now)
        returns LedgerAppend|types:DomainError {
    PointRule rule = check ruleInForce(rules, fact.action, now);
    types:LedgerReference reference = check types:awardReference(fact.provider, fact.targetResourceUrn, fact.employeeId,
            fact.action);
    return toAppend(award(reference, fact.employeeId, fact.campaignId, types:ENGAGEMENT, fact.engagementId, fact.action,
            rule, rule.points, correlationId, now));
}

# `OWN_POST` award row for an approved external share, priced at the rules in force on approval.
#
# + rules - Rule versions
# + fact - Approved claim
# + correlationId - Request correlation id
# + now - Insert time
# + return - Row and event, or a domain error
public isolated function awardForExternalShare(PointRule[] rules, ExternalShareFact fact, string? correlationId,
        time:Utc now) returns LedgerAppend|types:DomainError {
    PointRule rule = check ruleInForce(rules, types:OWN_POST, fact.approvedAt);
    types:LedgerReference reference = check types:awardReference(fact.provider, fact.evidenceUrl, fact.employeeId,
            types:OWN_POST);
    return toAppend(award(reference, fact.employeeId, fact.campaignId, types:EXTERNAL_SHARE, fact.externalShareId,
            types:OWN_POST, rule, rule.points, correlationId, now));
}

# Net `OWN_POST` points already on the ledger for an approved claim: the award row plus its reversal, so a
# fully reversed own post nets to 0. Priced from the ledger, not from the rules, so a rule change between
# approval and amplification (or a reversal) can't over- or under-award the top-up.
#
# + ledger - Ledger repository
# + fact - Approved claim
# + return - Net `OWN_POST` points (0 when the award is absent), or a repository error
public isolated function ownPostNet(LedgerRepository ledger, ExternalShareFact fact) returns int|error {
    types:LedgerReference reference = check types:awardReference(fact.provider, fact.evidenceUrl, fact.employeeId,
            types:OWN_POST);
    types:LedgerEntry? award = check ledger.findByReference(reference);
    int net = award is types:LedgerEntry ? award.points : 0;
    types:LedgerEntry? reversal = check ledger.findReversalOf(reference);
    if reversal is types:LedgerEntry {
        net += reversal.points;
    }
    return net;
}

# T4 top-up row when an approved claim is amplified (C4): `OWN_POST_AMPLIFIED` points minus the net
# `OWN_POST` points actually awarded for the claim (`ownPostNet`; 0 after a full reversal). The original
# rows stay (append-only), so original tier plus top-up is exactly the amplified tier.
#
# + rules - Rule versions
# + fact - Approved claim
# + ownPostPoints - Net `OWN_POST` points already awarded (from `ownPostNet`)
# + correlationId - Request correlation id
# + now - Insert time
# + return - Row and event, `TOP_UP_NOT_POSITIVE` if the amplified tier isn't above what was awarded, or
#            another error
public isolated function amplifiedTopUp(PointRule[] rules, ExternalShareFact fact, int ownPostPoints,
        string? correlationId, time:Utc now) returns LedgerAppend|types:DomainError {
    PointRule amplified = check ruleInForce(rules, types:OWN_POST_AMPLIFIED, fact.approvedAt);
    int difference = amplified.points - ownPostPoints;
    if difference <= 0 {
        return types:domainError(types:ERR_TOP_UP_NOT_POSITIVE,
                "The amplified tier must be worth more than the points already awarded");
    }
    types:LedgerReference reference = check types:awardReference(fact.provider, fact.evidenceUrl, fact.employeeId,
            types:OWN_POST_AMPLIFIED);
    return toAppend(award(reference, fact.employeeId, fact.campaignId, types:EXTERNAL_SHARE, fact.externalShareId,
            types:OWN_POST_AMPLIFIED, amplified, difference, correlationId, now));
}

# Reversal row: cancels `original` with the opposite points. A reversal can't be reversed, a row is
# reversed at most once, and a reason is required (ADR-010).
#
# + original - Row to cancel
# + existingReversal - Its reversal, if one exists
# + reason - Why
# + actorId - PO, or `system`
# + id - New UUIDv7
# + correlationId - Request correlation id
# + now - Insert time
# + return - Row and event, or a domain error
public isolated function reversal(types:LedgerEntry original, types:LedgerEntry? existingReversal, string reason,
        string actorId, string id, string? correlationId, time:Utc now) returns LedgerAppend|types:DomainError {
    if original.employeeId == actorId {
        return types:domainError(types:ERR_SELF_REVIEW, "You can't reverse your own points");
    }
    if original.sourceType == types:REVERSAL {
        return types:domainError(types:ERR_CANNOT_REVERSE_REVERSAL, "A reversal can't be reversed; add an adjustment");
    }
    if existingReversal !is () {
        return types:domainError(types:ERR_ALREADY_REVERSED, "This entry is already reversed");
    }
    string trimmed = check requiredReason(reason);
    return toAppend({
        reference: check types:reversalReference(id),
        employeeId: original.employeeId,
        campaignId: original.campaignId,
        sourceType: types:REVERSAL,
        sourceId: (),
        action: original.action,
        points: -original.points,
        ruleId: (),
        reversesReference: original.reference,
        reason: trimmed,
        actorId,
        correlationId,
        createdAt: now,
        status: types:HELD,
        statusChangedAt: (),
        paidAt: (),
        coinReference: ()
    });
}

# Adjustment row: PO adds or removes points with a reason (ADR-010).
#
# + employeeId - Who
# + points - Signed, non-zero
# + reason - Why
# + actorId - PO
# + campaignId - Campaign, optional
# + id - New UUIDv7
# + correlationId - Request correlation id
# + now - Insert time
# + return - Row and event, or a domain error (`SELF_REVIEW` when the PO adjusts their own points)
public isolated function adjustment(types:EmployeeId employeeId, int points, string reason, types:EmployeeId actorId,
        string? campaignId, string id, string? correlationId, time:Utc now) returns LedgerAppend|types:DomainError {
    if employeeId == actorId {
        return types:domainError(types:ERR_SELF_REVIEW, "You can't adjust your own points");
    }
    if points == 0 {
        return types:domainError(types:ERR_INVALID_POINTS, "An adjustment must change the points");
    }
    string trimmed = check requiredReason(reason);
    return toAppend({
        reference: check types:adjustmentReference(id),
        employeeId,
        campaignId,
        sourceType: types:ADJUSTMENT,
        sourceId: (),
        action: (),
        points,
        ruleId: (),
        reversesReference: (),
        reason: trimmed,
        actorId,
        correlationId,
        createdAt: now,
        status: types:HELD,
        statusChangedAt: (),
        paidAt: (),
        coinReference: ()
    });
}

# Settlement change: only `status` and `statusChangedAt` move; every fact stays as it was. `PAID` is
# refused in phase 1 (Coins are phase 2).
#
# + entry - Ledger row
# + status - `HELD`, or `()` for action required
# + now - Change time
# + return - The row with new settlement fields, or `PAID_NOT_ALLOWED`
public isolated function changeSettlement(types:LedgerEntry entry, types:LedgerStatus? status, time:Utc now)
        returns types:LedgerEntry|types:DomainError {
    if status == types:PAID {
        return types:domainError(types:ERR_PAID_NOT_ALLOWED, "Points can't be paid out in phase 1");
    }
    types:LedgerEntry changed = entry.clone();
    changed.status = status;
    changed.statusChangedAt = now;
    return changed;
}

// ---- Use cases ------------------------------------------------------------------------------------

# Adds a rule version (`POST /po/point-rules`, `amplify_po`).
#
# + repo - Rule repository
# + action - Action
# + points - Points
# + effectiveFrom - Start; `()` = now
# + actor - PO
# + now - Current time
# + return - The new version, a domain error, or a repository error
public isolated function setPointRule(PointRuleRepository repo, types:PointAction action, int points,
        time:Utc? effectiveFrom, types:EmployeeId actor, time:Utc now) returns PointRule|error {
    PointRule rule = check newRuleVersion(check repo.all(), action, points, effectiveFrom, actor, types:newUuidV7(), now);
    check repo.insert(rule);
    return rule;
}

# Appends an award. Re-running with the same fact is a no-op (`ON CONFLICT DO NOTHING`).
#
# + repo - Ledger repository
# + append - Row and event from `awardFor*` or `amplifiedTopUp`
# + return - True if a new row was written, or an error
public isolated function appendAward(LedgerRepository repo, LedgerAppend append) returns boolean|error =>
    repo.append(append);

# Reverses a ledger row (`POST /po/points/{reference}/reverse`).
#
# + repo - Ledger repository
# + reference - Row to reverse
# + reason - Why
# + actorId - PO
# + correlationId - Request correlation id
# + now - Current time
# + return - The reversal row, a domain error, or a repository error
public isolated function reverseEntry(LedgerRepository repo, string reference, string reason, types:EmployeeId actorId,
        string? correlationId, time:Utc now) returns types:LedgerEntry|error {
    types:LedgerReference ref = check types:parseLedgerReference(reference);
    types:LedgerEntry? original = check repo.findByReference(ref);
    if original is () {
        return types:domainError(types:ERR_NOT_FOUND, "Ledger entry not found");
    }
    LedgerAppend append = check reversal(original, check repo.findReversalOf(ref), reason, actorId,
            types:newUuidV7(), correlationId, now);
    if !check repo.append(append) {
        return types:domainError(types:ERR_ALREADY_REVERSED, "This entry is already reversed");
    }
    return append.entry;
}

# Adjusts an employee's points (`POST /po/points/adjustments`).
#
# + repo - Ledger repository
# + employeeId - Who
# + points - Signed, non-zero
# + reason - Why
# + actorId - PO
# + campaignId - Campaign, optional
# + correlationId - Request correlation id
# + now - Current time
# + return - The adjustment row, a domain error, or a repository error
public isolated function adjustPoints(LedgerRepository repo, types:EmployeeId employeeId, int points, string reason,
        types:EmployeeId actorId, string? campaignId, string? correlationId, time:Utc now)
        returns types:LedgerEntry|error {
    LedgerAppend append = check adjustment(employeeId, points, reason, actorId, campaignId, types:newUuidV7(),
            correlationId, now);
    _ = check repo.append(append);
    return append.entry;
}

// ---- Helpers --------------------------------------------------------------------------------------

isolated function award(types:LedgerReference reference, types:EmployeeId employeeId, string? campaignId,
        types:LedgerSourceType sourceType, string sourceId, types:PointAction action, PointRule rule, int points,
        string? correlationId, time:Utc now) returns types:LedgerEntry => {
    reference,
    employeeId,
    campaignId,
    sourceType,
    sourceId,
    action,
    points,
    ruleId: rule.id,
    reversesReference: (),
    reason: (),
    actorId: types:SYSTEM_ACTOR,
    correlationId,
    createdAt: now,
    status: types:HELD,
    statusChangedAt: (),
    paidAt: (),
    coinReference: ()
};

isolated function toAppend(types:LedgerEntry entry) returns LedgerAppend => {entry, event: pointsChangedEvent(entry)};

isolated function requiredReason(string reason) returns string|types:DomainError {
    string? trimmed = types:trimToNil(reason);
    if trimmed is () {
        return types:domainError(types:ERR_REASON_REQUIRED, "A reason is required");
    }
    return trimmed;
}
