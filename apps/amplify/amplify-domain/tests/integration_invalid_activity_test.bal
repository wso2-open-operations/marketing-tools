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

// Remove invalid activity against PostgreSQL (V030, ADR-010 amendment 2026-11-26): the removal row keeps its reason
// code, `ActivityRemoved` is in the outbox with it, recognition nets to zero, and C1 flags the engagement once so the
// view reads INVALID.

import amplify_common.types;
import amplify_domain.recognition;
import amplify_domain.scoring;
import amplify_domain.sharing;

import ballerina/sql;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], enable: itEnabled}
function testRemoveInvalidActivityInPostgres() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "rm-emp");
    string po = check newEmployee(db, "rm-po");
    string urn = "urn:li:share:" + uniq();
    string engagementId = check db->queryRow(`INSERT INTO sharing_engagement (provider, provider_api, origin,
            target_resource_urn, actor_member_urn, employee_id, action, activity_urn, occurred_at)
            VALUES ('linkedin', 'SHARE_ON_LINKEDIN', 'IN_APP', ${urn}, 'urn:li:person:rm', ${emp}, 'REPOST',
                    ${urn + "-activity"}, now())
            RETURNING id::text`);
    scoring:PointRule[] rules = check (new scoring:PgPointRuleRepository(db)).all();
    time:Utc now = time:utcNow();
    scoring:LedgerAppend award = check scoring:awardForEngagement(rules, {engagementId, provider: types:LINKEDIN,
        targetResourceUrn: urn, employeeId: emp, action: types:REPOST, campaignId: ()}, "it-rm", now);
    test:assertTrue(check scoring:appendAward(new scoring:PgLedgerRepository(db), award));

    scoring:PgLedgerRepository ledger = new (db, poActor(po));
    scoring:Removal removal = check scoring:removeInvalidActivity(ledger, award.entry.reference, types:REMOVAL_DUPLICATE,
            "Counted twice", po, "it-rm", now);
    types:LedgerEntry? stored = check ledger.findByReference(removal.entry.reference);
    test:assertTrue(stored is types:LedgerEntry && stored.removalReason == types:REMOVAL_DUPLICATE,
            "the reason code is read back");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM messaging_outbox
        WHERE idempotency_key = ${"ActivityRemoved:" + engagementId}`), 1);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit_log WHERE action = 'ActivityRemoved'
        AND entity_id = ${removal.entry.reference}`), 1);
    recognition:Standing? standing = check recognition:standingOf(db, emp);
    test:assertTrue(standing is recognition:Standing && standing.totalPoints == 0, "the points are off the board");
    test:assertEquals(code(scoring:removeInvalidActivity(ledger, award.entry.reference, types:REMOVAL_SPAM, (), po,
            (), now)), types:ERR_ALREADY_REVERSED);

    sharing:PgInvalidActivityRepository flags = new (db, poActor(po));
    test:assertTrue(check sharing:markEngagementInvalid(flags, removal.removed));
    test:assertFalse(check sharing:markEngagementInvalid(flags, removal.removed), "the jobs backstop is a no-op");
    record {|string status; string? invalid_reason;|} row = check db->queryRow(`
        SELECT status, invalid_reason FROM sharing_engagement_v WHERE id = CAST(${engagementId} AS uuid)`);
    test:assertEquals(row, {status: "INVALID", invalid_reason: "DUPLICATE"});
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit_log WHERE action = 'EngagementInvalidated'
        AND entity_id = ${engagementId}`), 1);
    test:assertEquals(code(flags.markInvalid(types:newUuidV7(), types:REMOVAL_SPAM, removal.entry.reference, now)),
            types:ERR_NOT_FOUND);

    // The schema holds the rules too: a reason code only on a reversal, the engagement flag both or neither.
    string adjRef = "ADJ-" + types:newUuidV7();
    sql:ExecutionResult|sql:Error codeOnAdjustment = db->execute(`INSERT INTO scoring_points_ledger (reference,
            employee_id, source_type, points, actor_id, reason, removal_reason)
            VALUES (${adjRef}, ${emp}, 'ADJUSTMENT', 1, ${po}, 'x', 'SPAM')`);
    test:assertTrue(codeOnAdjustment is sql:Error, "points_ledger_removal_reason_ck");
    sql:ExecutionResult|sql:Error halfFlag = db->execute(`UPDATE sharing_engagement SET invalid_reason = NULL
            WHERE id = CAST(${engagementId} AS uuid)`);
    test:assertTrue(halfFlag is sql:Error, "engagement_invalidated_ck");
    check db.close();
}

function code(any|error result) returns string {
    if result is types:DomainError {
        return result.detail().code;
    }
    return result is error ? "ERROR" : "OK";
}
