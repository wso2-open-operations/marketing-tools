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

import ballerina/test;
import ballerina/time;

final time:Utc T0 = [1790000000, 0];

isolated class InMemoryExternalShares {
    *ExternalShareRepository;
    private map<ExternalShare> rows = {};
    private events:OutboxEvent[] outbox = [];
    private types:LedgerEntry[] awards = [];

    public isolated function findById(string id) returns ExternalShare|error? {
        lock {
            return self.rows[id].clone();
        }
    }

    public isolated function isClaimed(string normalizedUrl, types:ExternalAction action) returns boolean|error {
        lock {
            foreach ExternalShare s in self.rows {
                if s.evidence.normalized == normalizedUrl && s.action == action {
                    return true;
                }
            }
            return false;
        }
    }

    public isolated function insert(ExternalShare claim, events:OutboxEvent[] outbox) returns error? {
        lock {
            self.rows[claim.id] = claim.clone();
            self.outbox.push(...outbox.clone());
        }
    }

    public isolated function updateWithAward(ExternalShare claim, int expectedVersion, events:OutboxEvent[] outbox,
            scoring:LedgerAppend award) returns error? {
        check self.update(claim, expectedVersion, outbox);
        lock {
            self.awards.push(award.entry.clone());
        }
    }

    isolated function awardRows() returns types:LedgerEntry[] {
        lock {
            return self.awards.clone();
        }
    }

    public isolated function update(ExternalShare claim, int expectedVersion, events:OutboxEvent[] outbox) returns error? {
        lock {
            ExternalShare? stored = self.rows[claim.id];
            if stored is () || stored.version != expectedVersion {
                return types:domainError(types:ERR_VERSION_CONFLICT, "stale");
            }
            self.rows[claim.id] = claim.clone();
            self.outbox.push(...outbox.clone());
        }
    }

    public isolated function events() returns events:OutboxEvent[] {
        lock {
            return self.outbox.clone();
        }
    }
}

// The ledger as `amplifyWithPoints` reads it: seeded with the rows the award path wrote.
isolated class InMemoryLedger {
    *scoring:LedgerRepository;
    private map<types:LedgerEntry> rows = {};

    isolated function seed(types:LedgerEntry entry) {
        lock {
            self.rows[entry.reference] = entry.clone();
        }
    }

    public isolated function append(scoring:LedgerAppend append) returns boolean|error {
        lock {
            if self.rows.hasKey(append.entry.reference) {
                return false;
            }
            self.rows[append.entry.reference] = append.entry.clone();
            return true;
        }
    }

    public isolated function findByReference(types:LedgerReference reference) returns types:LedgerEntry|error? {
        lock {
            return self.rows.hasKey(reference) ? self.rows[reference].clone() : ();
        }
    }

    public isolated function findReversalOf(types:LedgerReference reference) returns types:LedgerEntry|error? {
        lock {
            foreach types:LedgerEntry row in self.rows {
                if row.reversesReference == reference {
                    return row.clone();
                }
            }
            return ();
        }
    }

    public isolated function updateSettlement(types:LedgerReference reference, types:LedgerStatus? status,
            time:Utc changedAt) returns error? {
        lock {
            if self.rows.hasKey(reference) {
                types:LedgerEntry? stored = self.rows[reference];
                if stored is types:LedgerEntry {
                    types:LedgerEntry row = stored.clone();
                    row.status = status;
                    row.statusChangedAt = changedAt;
                    self.rows[reference] = row;
                }
            }
        }
    }
}

isolated function code(any|error result) returns string {
    if result is types:DomainError {
        return result.detail().code;
    }
    return result is error ? "ERROR" : "OK";
}

function claim(string employeeId = "emp-1", string url = "https://medium.com/@avery/wso2-rocks?utm_source=x")
        returns ExternalShareClaim => {employeeId, evidenceUrl: url, certified: true};

@test:Config
function claimNeedsCertificationAndHttps() {
    ExternalShareClaim uncertified = claim();
    uncertified.certified = false;
    test:assertEquals(code(newExternalShare(uncertified, "x1", T0)), types:ERR_CERTIFICATION_REQUIRED);
    test:assertEquals(code(newExternalShare(claim(url = "http://medium.com/a"), "x1", T0)), types:ERR_EVIDENCE_URL_NOT_HTTPS);
}

@test:Config
function claimIsPendingWithNormalizedUrl() returns error? {
    ExternalShare s = check newExternalShare(claim(), "x1", T0);
    test:assertEquals(externalShareStatus(s), PENDING);
    test:assertEquals(s.evidence.normalized, "https://medium.com/@avery/wso2-rocks");
    test:assertEquals(s.evidence.submitted, "https://medium.com/@avery/wso2-rocks?utm_source=x", "kept as typed for PO");
    test:assertEquals(s.action, types:OWN_POST);
}

@test:Config
function oneClaimPerUrlAcrossEmployees() returns error? {
    InMemoryExternalShares repo = new;
    _ = check submitExternalShare(repo, claim(), T0);
    ExternalShare|error second = submitExternalShare(repo,
            claim(employeeId = "emp-2", url = "HTTPS://Medium.com/@avery/wso2-rocks/#top"), T0);
    test:assertEquals(code(second), types:ERR_EVIDENCE_ALREADY_CLAIMED, "C5 on the normalized URL");
    if second is types:DomainError {
        test:assertEquals(second.message(), "Someone else already submitted this url, contact PO Team for review");
    }
}

@test:Config
function approveRejectAndSelfReview() returns error? {
    ExternalShare s = check newExternalShare(claim(), "x1", T0);
    test:assertEquals(code(approve(s, "emp-1", T0)), types:ERR_SELF_REVIEW, "can't review your own claim");
    ExternalShare approved = check approve(s, "po-1", T0);
    test:assertEquals(externalShareStatus(approved), APPROVED);
    test:assertEquals(approved.decidedBy, "po-1");
    test:assertEquals(approved.decidedAt, T0);
    test:assertEquals(code(approve(approved, "po-1", T0)), types:ERR_NOT_PENDING, "only pending can be decided");
    test:assertEquals(code(reject(approved, "po-1", "dup", T0)), types:ERR_NOT_PENDING);

    test:assertEquals(code(reject(s, "po-1", "  ", T0)), types:ERR_REASON_REQUIRED);
    ExternalShare rejected = check reject(s, "po-1", " Not about WSO2 ", T0);
    test:assertEquals(externalShareStatus(rejected), REJECTED);
    test:assertEquals(rejected.decisionReason, "Not about WSO2");
}

@test:Config
function amplifiedOnlyWhenApproved() returns error? {
    ExternalShare s = check newExternalShare(claim(), "x1", T0);
    test:assertEquals(code(markAmplified(s, T0)), types:ERR_NOT_APPROVED, "C4: pending can't be amplified");
    ExternalShare rejected = check reject(s, "po-1", "no", T0);
    test:assertEquals(code(markAmplified(rejected, T0)), types:ERR_NOT_APPROVED, "C4: rejected can't be amplified");
    ExternalShare amplified = check markAmplified(check approve(s, "po-1", T0), T0);
    test:assertEquals(externalShareStatus(amplified), AMPLIFIED);
    test:assertEquals(code(markAmplified(amplified, T0)), types:ERR_ALREADY_AMPLIFIED, "once per claim");
}

@test:Config
function useCasesWriteCatalogueEvents() returns error? {
    InMemoryExternalShares repo = new;
    ExternalShare s = check submitExternalShare(repo, claim(), T0);
    _ = check approveExternalShare(repo, s.id, "po-1", T0);
    _ = check amplifyExternalShare(repo, s.id, "po-1", T0);
    test:assertEquals(repo.events().map(e => e.idempotencyKey), [
        "ExternalShareSubmitted:" + s.id,
        "ExternalShareApproved:" + s.id,
        "ExternalShareAmplified:" + s.id + ":AMPLIFIED"
    ]);
    test:assertEquals(code(rejectExternalShare(repo, "missing", "po-1", "x", T0)), types:ERR_NOT_FOUND);
}

final scoring:PointRule[] & readonly TEST_RULES = [
    {id: "01900000-0000-7000-8000-000000000001", action: types:OWN_POST, points: 25, effectiveFrom: [1700000000, 0],
        createdBy: "po", createdAt: [1700000000, 0]},
    {id: "01900000-0000-7000-8000-000000000002", action: types:OWN_POST_AMPLIFIED, points: 40,
        effectiveFrom: [1700000000, 0], createdBy: "po", createdAt: [1700000000, 0]}
];

@test:Config
function testApproveAndAmplifyWritePointsWithTheDecision() returns error? {
    InMemoryExternalShares repo = new;
    InMemoryLedger ledger = new;
    ExternalShare claim = check submitExternalShare(repo,
            {employeeId: "emp-points", evidenceUrl: "https://medium.com/@emp/points-post", certified: true}, T0);
    ExternalShare approved = check approveWithPoints(repo, TEST_RULES, claim.id, "po-1", "cid-1", T0);
    test:assertEquals(externalShareStatus(approved), APPROVED);
    ledger.seed(repo.awardRows()[0]);
    ExternalShare amplified = check amplifyWithPoints(repo, TEST_RULES, claim.id, "po-1", "cid-2", T0, ledger);
    test:assertEquals(externalShareStatus(amplified), AMPLIFIED);
    types:LedgerEntry[] rows = repo.awardRows();
    test:assertEquals(rows.length(), 2);
    test:assertEquals(rows[0].points, 25);
    test:assertEquals(rows[0].action, types:OWN_POST);
    test:assertEquals(rows[1].points, 15, "top-up = amplified − the 25 on the ledger");
    test:assertEquals(rows[1].action, types:OWN_POST_AMPLIFIED);
}

// Round 2: the top-up reads the ledger, so a reversed own-post award is topped up to the whole tier.
@test:Config
function testAmplifiedTopUpAfterTheOwnPostIsReversed() returns error? {
    InMemoryExternalShares repo = new;
    InMemoryLedger ledger = new;
    ExternalShare claim = check submitExternalShare(repo,
            {employeeId: "emp-rev", evidenceUrl: "https://medium.com/@emp/reversed-post", certified: true}, T0);
    _ = check approveWithPoints(repo, TEST_RULES, claim.id, "po-1", "cid-1", T0);
    types:LedgerEntry own = repo.awardRows()[0];
    ledger.seed(own);
    _ = check scoring:reverseEntry(ledger, own.reference, "Reassessing", "po-2", (), T0);
    _ = check amplifyWithPoints(repo, TEST_RULES, claim.id, "po-1", "cid-2", T0, ledger);
    types:LedgerEntry[] rows = repo.awardRows();
    test:assertEquals(rows.length(), 2);
    test:assertEquals(rows[1].points, 40, "the whole amplified tier: the own post nets to 0");
}

// R-02: marking amplified pays a top-up, so the claimant can't mark their own claim.
@test:Config {}
function claimantCantMarkOwnClaimAmplified() returns error? {
    ExternalShare claim = check newExternalShare({employeeId: "po-self", evidenceUrl: "https://medium.com/@x/self",
        certified: true}, types:newUuidV7(), T0);
    ExternalShare approved = check approve(claim, "po-other", T0);
    ExternalShare|types:DomainError own = markAmplified(approved, T0, "po-self");
    test:assertTrue(own is types:DomainError && own.detail().code == types:ERR_SELF_REVIEW);
    ExternalShare ok = check markAmplified(approved, T0, "po-other");
    test:assertTrue(ok.amplifiedAt is time:Utc);
    // The use cases pass the PO through.
    InMemoryExternalShares repo = new;
    check repo.insert(approved, []);
    ExternalShare|error viaUseCase = amplifyExternalShare(repo, approved.id, "po-self", T0);
    test:assertTrue(viaUseCase is types:DomainError && viaUseCase.detail().code == types:ERR_SELF_REVIEW);
}
