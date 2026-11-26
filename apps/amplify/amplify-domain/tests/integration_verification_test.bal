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

// Pre-coin verification against PostgreSQL (V027): the rows due for a check, the three outcomes on the ledger (and the
// V027 guard letting them through), the conversion's candidate rule (recently verified engagement rows, reversal
// pairs), the PO clearing a row, the action-required list, and the sharing side (find, recordCheck, the member
// budget). The database is shared with the other integration tests, so every read is filtered to this test's rows.

import amplify_common.types;
import amplify_domain.scoring;
import amplify_domain.sharing;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

type VerificationRow record {|
    string? status;
    string? verification;
    string? verification_reason;
|};

function ledgerRow(postgresql:Client db, string reference) returns VerificationRow|error {
    return db->queryRow(`SELECT status, verification, verification_reason FROM scoring_points_ledger
        WHERE reference = ${reference}`);
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testVerificationOutcomesAndTheConversionRule() returns error? {
    postgresql:Client db = check jobs();
    string po = check newEmployee(db, "verify-po");
    string alice = check newEmployee(db, "verify-alice");
    scoring:PointRule[] rules = check (new scoring:PgPointRuleRepository(db)).all();
    scoring:PgLedgerRepository ledger = new (db);
    time:Utc now = time:utcNow();
    string[] refs = [];
    types:EngagementAction[] actions = [types:REPOST, types:REPOST_COMMENTARY, types:REACTION];
    foreach types:EngagementAction action in actions {
        scoring:LedgerAppend award = check scoring:awardForEngagement(rules, {engagementId: types:newUuidV7(),
            provider: types:LINKEDIN, targetResourceUrn: "urn:li:share:" + uniq(), employeeId: alice, action,
            campaignId: ()}, "it-verify", now);
        test:assertTrue(check scoring:appendAward(ledger, award));
        refs.push(award.entry.reference);
    }
    types:LedgerEntry adj = check scoring:adjustPoints(new scoring:PgLedgerRepository(db, poActor(po)), alice, 7, "it",
            po, (), (), now);

    scoring:PgVerificationRepository repo = new (db);
    string[] due = from scoring:VerifyCandidate c in check repo.dueForCheck(time:utcAddSeconds(now, 1), 100000)
        where c.employeeId == alice select c.reference;
    test:assertEquals(due.sort(), refs.clone().sort(), "the engagement rows only (same created_at: ordered by reference)");

    check repo.markVerified(refs[0], now);
    check repo.markUnverifiable(refs[1], scoring:VERIFY_NO_TOKEN, now);
    test:assertTrue(check repo.reverseRemoved(refs[2], "it-verify", now));
    test:assertFalse(check repo.reverseRemoved(refs[2], "it-verify", now), "reversed once");
    test:assertEquals(check ledgerRow(db, refs[0]), {status: "HELD", verification: "VERIFIED", verification_reason: ()});
    test:assertEquals(check ledgerRow(db, refs[1]), {status: (), verification: "UNVERIFIABLE",
        verification_reason: "NO_TOKEN"}, "action required");
    test:assertEquals(check ledgerRow(db, refs[2]), {status: "HELD", verification: "REMOVED", verification_reason: ()});
    types:LedgerEntry reversal = <types:LedgerEntry>check ledger.findReversalOf(refs[2]);
    test:assertEquals([reversal.reason, reversal.actorId], [scoring:REASON_NO_LONGER_ON_LINKEDIN, types:SYSTEM_ACTOR]);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit_log WHERE entity_id IN (${refs[0]}, ${refs[1]})
        AND action IN ('PointsVerified', 'PointsSettlementChanged')`), 2);
    test:assertEquals((from scoring:VerifyCandidate c in check repo.dueForCheck(time:utcAddSeconds(now, -1), 100000)
        where c.employeeId == alice select c).length(), 0, "nothing due once each has an outcome");
    test:assertEquals((from scoring:VerifyCandidate c in check repo.dueForCheck(time:utcAddSeconds(now, 60), 100000)
        where c.employeeId == alice select c.reference), [refs[0]], "a VERIFIED row gets stale");

    // The conversion: the verified row, the adjustment, the removed row with its reversal; not the action-required one.
    scoring:PgCoinRepository coins = new (db);
    scoring:CoinCandidate c1 = <scoring:CoinCandidate>find(check coins.candidates(time:utcAddSeconds(now, -172800)), alice);
    string[] taken = from scoring:ConvertibleRow r in c1.rows select r.reference;
    string[] expected = [refs[0], refs[2], adj.reference, reversal.reference];
    test:assertEquals(taken.sort(), expected.sort());
    scoring:CoinCandidate c2 = <scoring:CoinCandidate>find(check coins.candidates(time:utcAddSeconds(now, 1)), alice);
    test:assertEquals(c2.rows.length(), 3, "the verified row is too old for this cutoff");

    // The PO team sees the action-required row and clears it; it then converts without another check.
    scoring:LedgerPage page = check scoring:actionRequiredOf(db, 0, 100);
    test:assertTrue(page.items.some(e => e.reference == refs[1] && e.verificationReason == "NO_TOKEN"));
    types:LedgerEntry cleared = check scoring:settleEntry(new scoring:PgLedgerRepository(db, poActor(po)), refs[1],
            types:HELD, po, now);
    test:assertEquals([cleared.status, cleared.verification], [types:HELD, types:PO_CLEARED]);
    scoring:CoinCandidate c3 = <scoring:CoinCandidate>find(check coins.candidates(time:utcAddSeconds(now, 1)), alice);
    test:assertEquals(c3.rows.length(), 4);
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testSharingRecordsWhatTheCheckFound() returns error? {
    postgresql:Client db = check jobs();
    string emp = check newEmployee(db, "verify-share-emp");
    sharing:PgEngagementSyncRepository sync = new (db);
    time:Utc now = time:utcNow();
    string resourceUrn = "urn:li:share:" + uniq();
    sharing:SyncCampaign sc = {id: types:newUuidV7(), resourceUrn, opensAt: time:utcAddSeconds(now, -3600),
        closesAt: time:utcAddSeconds(now, 3600)};
    string member = "urn:li:person:it" + uniq();
    string id = types:newUuidV7();
    sharing:Engagement e = sharing:syncedEngagement({kind: "REACTION", actorUrn: member, targetUrn: resourceUrn,
        occurredAt: now}, sc, member, emp, id, now);
    test:assertTrue(check sync.recordSynced(e, now));

    sharing:PgEngagementVerificationRepository repo = new (db);
    sharing:Engagement found = <sharing:Engagement>check repo.find(id);
    test:assertEquals([found.action, found.actorMemberUrn, found.employeeId], [types:REACTION, member, emp]);
    test:assertEquals(check repo.find(types:newUuidV7()), ());
    test:assertEquals(sharing:verifyTarget(found), {kind: sharing:TARGET_REACTION, urn: resourceUrn, actorUrn: member});

    check repo.recordCheck(id, types:COMMUNITY_MANAGEMENT, true, now);
    check repo.recordCheck(id, types:COMMUNITY_MANAGEMENT, false, now);
    sharing:Engagement after = <sharing:Engagement>check repo.find(id);
    test:assertTrue(after.lastVerifiedAt !is () && after.deletedAt !is ());
    test:assertEquals(check count(db, `SELECT count(*)::int FROM sharing_engagement_verification
        WHERE engagement_id = CAST(${id} AS uuid)`), 2);

    // The member-token budget is its own row (V027 widened the check).
    string day = time:utcToString(now).substring(0, 10);
    _ = check db->execute(`DELETE FROM sharing_api_usage WHERE provider_api = 'SHARE_ON_LINKEDIN'
        AND day = CAST(${day} AS date)`);
    test:assertTrue(check repo.takeCall(types:SHARE_ON_LINKEDIN, now, 1));
    test:assertFalse(check repo.takeCall(types:SHARE_ON_LINKEDIN, now, 1));
    check db.close();
}
