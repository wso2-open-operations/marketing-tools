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


// In-memory fakes for the M5 seams (database.bal, outbound.bal): repositories, reads, settings and the
// idempotency store. Endpoint and contract tests run on these; the IT runs the real ones.

import amplify_common.events;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.external_sharing;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/test;
import ballerina/time;

isolated boolean dbUp = true;

function setDbUp(boolean up) {
    lock {
        dbUp = up;
    }
}

@test:Mock {functionName: "dbReachable"}
isolated function mockDbReachable() returns boolean {
    lock {
        return dbUp;
    }
}

// Settings rows; empty = defaults. scheduler_sync_test.bal fills them through the saveSettings fake.
isolated store:Setting[] fakeSettingRows = [];

@test:Mock {functionName: "settingRows"}
isolated function mockSettingRows() returns store:Setting[]|error {
    lock {
        return fakeSettingRows.clone();
    }
}

@test:Mock {functionName: "categoryList"}
isolated function mockCategories() returns campaign:Category[]|error => [{code: "PRODUCT", label: "Product", sortOrder: 1}];

@test:Mock {functionName: "tagList"}
isolated function mockTags() returns string[]|error => ["ballerina"];

@test:Mock {functionName: "triggerJobs"}
isolated function mockTriggerJobs(string path, string? correlationId) returns RunTrigger => "DEFERRED";

// ---- Idempotency store ---------------------------------------------------------------------------

isolated map<store:IdempotencyRecord> idemRows = {};

# When set, claiming a key fails with this error (the key store is the database).
isolated error? idemClaimError = ();

function setIdemClaimError(error? err) {
    lock {
        idemClaimError = err;
    }
}

function idemRow(string employeeId, string key) returns store:IdempotencyRecord? {
    lock {
        return idemRows[employeeId + "|" + key].clone();
    }
}

function putIdemRow(string employeeId, string key, store:IdempotencyRecord row) {
    lock {
        idemRows[employeeId + "|" + key] = row.clone();
    }
}

@test:Mock {functionName: "claimIdempotency"}
isolated function mockClaim(types:EmployeeId employeeId, string key, string hash) returns store:IdempotencyRecord|error? {
    lock {
        error? failing = idemClaimError;
        if failing is error {
            return failing;
        }
    }
    lock {
        string k = employeeId + "|" + key;
        store:IdempotencyRecord? seen = idemRows[k];
        if seen is store:IdempotencyRecord {
            return seen.clone();
        }
        idemRows[k] = {requestHash: hash, responseStatus: (), responseBody: ()};
        return ();
    }
}

@test:Mock {functionName: "completeIdempotency"}
isolated function mockComplete(types:EmployeeId employeeId, string key, int status, json body) returns error? {
    lock {
        string k = employeeId + "|" + key;
        store:IdempotencyRecord? seen = idemRows[k];
        if seen is store:IdempotencyRecord {
            idemRows[k] = {requestHash: seen.requestHash, responseStatus: status, responseBody: body.clone()};
        }
    }
}

@test:Mock {functionName: "releaseIdempotency"}
isolated function mockRelease(types:EmployeeId employeeId, string key) returns error? {
    lock {
        _ = idemRows.removeIfHasKey(employeeId + "|" + key);
    }
}

// ---- Repositories ------------------------------------------------------------------------------------

isolated class FakeCampaigns {
    *campaign:CampaignRepository;
    private map<campaign:Campaign> rows = {};
    private int inserts = 0;
    private string? bumpOnRead = ();
    private string[] active = [];

    # A share (or other activity) now exists for the campaign.
    #
    # + id - Campaign id
    isolated function markActive(string id) {
        lock {
            self.active.push(id);
        }
    }

    public isolated function hasActivity(string id, string resourceUrn) returns boolean|error {
        lock {
            return self.active.indexOf(id) !is ();
        }
    }

    public isolated function findById(string id) returns campaign:Campaign|error? {
        lock {
            campaign:Campaign? found = self.rows[id].clone();
            if found is campaign:Campaign && self.bumpOnRead == id {
                // Another editor commits right after this read (the race the PATCH lock must catch).
                self.bumpOnRead = ();
                campaign:Campaign other = found.clone();
                other.title = "Changed by someone else";
                other.version = found.version + 1;
                self.rows[id] = other;
            }
            return found.clone();
        }
    }

    # The next read of `id` is followed at once by a concurrent edit.
    #
    # + id - Campaign id
    isolated function bumpAfterNextRead(string id) {
        lock {
            self.bumpOnRead = id;
        }
    }

    public isolated function findByResource(types:Provider provider, types:PostUrn resourceUrn) returns campaign:Campaign|error? {
        lock {
            foreach campaign:Campaign c in self.rows {
                if c.resourceUrn == resourceUrn {
                    return c.clone();
                }
            }
            return ();
        }
    }

    public isolated function insert(campaign:Campaign c, events:OutboxEvent[] outbox) returns error? {
        lock {
            self.rows[c.id] = c.clone();
            self.inserts += 1;
        }
    }

    public isolated function update(campaign:Campaign c, int expectedVersion) returns error? {
        lock {
            campaign:Campaign? stored = self.rows[c.id];
            if stored is () || stored.version != expectedVersion {
                return store:versionConflict("campaign");
            }
            self.rows[c.id] = c.clone();
        }
    }

    isolated function insertCount() returns int {
        lock {
            return self.inserts;
        }
    }

    isolated function all() returns campaign:Campaign[] {
        lock {
            return self.rows.toArray().clone();
        }
    }
}

isolated class FakeShares {
    *sharing:ShareRepository;
    private map<sharing:ShareRequest> rows = {};

    public isolated function findByCampaignAndEmployee(string campaignId, types:EmployeeId employeeId)
            returns sharing:ShareRequest|error? {
        lock {
            return self.rows[campaignId + "|" + employeeId].clone();
        }
    }

    public isolated function insert(sharing:ShareRequest r, events:OutboxEvent[] outbox) returns error? {
        lock {
            self.rows[r.campaignId + "|" + r.employeeId] = r.clone();
        }
    }

    public isolated function update(sharing:ShareRequest r, int expectedVersion, events:OutboxEvent[] outbox) returns error? {
        lock {
            self.rows[r.campaignId + "|" + r.employeeId] = r.clone();
        }
    }
}

isolated class FakeExternalShares {
    *external_sharing:ExternalShareRepository;
    private map<external_sharing:ExternalShare> rows = {};
    private types:LedgerEntry[] awards = [];

    public isolated function findById(string id) returns external_sharing:ExternalShare|error? {
        lock {
            return self.rows[id].clone();
        }
    }

    public isolated function isClaimed(string normalizedUrl, types:ExternalAction action) returns boolean|error {
        lock {
            foreach var c in self.rows {
                if c.evidence.normalized == normalizedUrl {
                    return true;
                }
            }
            return false;
        }
    }

    public isolated function insert(external_sharing:ExternalShare c, events:OutboxEvent[] outbox) returns error? {
        lock {
            self.rows[c.id] = c.clone();
        }
    }

    public isolated function update(external_sharing:ExternalShare c, int expectedVersion, events:OutboxEvent[] outbox)
            returns error? {
        lock {
            self.rows[c.id] = c.clone();
        }
    }

    public isolated function updateWithAward(external_sharing:ExternalShare c, int expectedVersion,
            events:OutboxEvent[] outbox, scoring:LedgerAppend award) returns error? {
        lock {
            self.rows[c.id] = c.clone();
            self.awards.push(award.entry.clone());
        }
        // The award is on the ledger too: `amplifyWithPoints` prices the top-up from what the ledger holds.
        _ = check fakeLedger.append(award);
    }

    isolated function awardRows() returns types:LedgerEntry[] {
        lock {
            return self.awards.clone();
        }
    }
}

isolated class FakeLedger {
    *scoring:LedgerRepository;
    private map<types:LedgerEntry> rows = {};

    public isolated function append(scoring:LedgerAppend a) returns boolean|error {
        lock {
            if self.rows.hasKey(a.entry.reference) {
                return false;
            }
            self.rows[a.entry.reference] = a.entry.clone();
            return true;
        }
    }

    public isolated function findByReference(types:LedgerReference reference) returns types:LedgerEntry|error? {
        lock {
            return self.rows[reference].clone();
        }
    }

    public isolated function findReversalOf(types:LedgerReference reference) returns types:LedgerEntry|error? {
        lock {
            foreach var e in self.rows {
                if e.reversesReference == reference {
                    return e.clone();
                }
            }
            return ();
        }
    }

    public isolated function updateSettlement(types:LedgerReference reference, types:LedgerStatus? status,
            time:Utc changedAt) returns error? {
    }
}

isolated class FakeRules {
    *scoring:PointRuleRepository;
    private scoring:PointRule[] rows = [
        {id: "01900000-0000-7000-8000-000000000001", action: types:OWN_POST, points: 25,
            effectiveFrom: [1700000000, 0], createdBy: "seed", createdAt: [1700000000, 0]},
        {id: "01900000-0000-7000-8000-000000000002", action: types:OWN_POST_AMPLIFIED, points: 40,
            effectiveFrom: [1700000000, 0], createdBy: "seed", createdAt: [1700000000, 0]}
    ];

    public isolated function all() returns scoring:PointRule[]|error {
        lock {
            return self.rows.clone();
        }
    }

    public isolated function insert(scoring:PointRule rule) returns error? {
        lock {
            self.rows.push(rule.clone());
        }
    }
}

final FakeCampaigns fakeCampaigns = new;
final FakeShares fakeShares = new;
final FakeExternalShares fakeExternalShares = new;
final FakeLedger fakeLedger = new;
final FakeRules fakeRules = new;

@test:Mock {functionName: "campaignRepository"}
isolated function mockCampaignRepository(store:Actor actor) returns campaign:CampaignRepository|error => fakeCampaigns;

@test:Mock {functionName: "shareRepository"}
isolated function mockShareRepository(store:Actor actor) returns sharing:ShareRepository|error => fakeShares;

@test:Mock {functionName: "externalShareRepository"}
isolated function mockExternalShareRepository(store:Actor actor, int topN)
        returns external_sharing:ExternalShareRepository|error => fakeExternalShares;

@test:Mock {functionName: "ledgerRepository"}
isolated function mockLedgerRepository(store:Actor actor, int topN) returns scoring:LedgerRepository|error => fakeLedger;

@test:Mock {functionName: "pointRuleRepository"}
isolated function mockPointRuleRepository(store:Actor actor) returns scoring:PointRuleRepository|error => fakeRules;

@test:Mock {functionName: "campaignPage"}
isolated function mockCampaignPage(campaign:CampaignQuery query, time:Utc now) returns campaign:CampaignPage|error {
    campaign:Campaign[] items = from var c in fakeCampaigns.all()
        where query.statuses.length() == 0 || query.statuses.indexOf(campaign:campaignStatus(c, now)) !is ()
        select c;
    return {items, total: items.length()};
}
