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

// Phase 4 backend against PostgreSQL: a removed LinkedIn connection releases its member (V031), the native repost's
// points by campaign, and the engagement sync's last run time.

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.scoring;
import amplify_domain.sharing;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

function connectAs(postgresql:Client db, crypto:TokenCipher cipher, string emp, string member, time:Utc now)
        returns connection:LinkedInConnection|error {
    connection:StoredToken t = check connection:sealToken(cipher, "bearer-" + uniq(), emp, time:utcAddSeconds(now, 3600),
            now);
    return connection:completeConnection(new connection:PgConnectionRepository(db, {actorId: emp}), {employeeId: emp,
        memberUrn: member, scopes: ["openid", "w_member_social"], token: connection:tokenRef(t), expiresInSeconds: 3600},
        now, t);
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testARemovedConnectionReleasesTheMember() returns error? {
    postgresql:Client db = check api();
    crypto:TokenCipher cipher = check new ([{keyId: "p4-a", key: keyBytes(4)}], "p4-a");
    string first = check newEmployee(db, "relink-a");
    string second = check newEmployee(db, "relink-b");
    string member = "urn:li:person:" + uniq();
    time:Utc now = time:utcNow();
    _ = check connectAs(db, cipher, first, member, now);
    assertCode(connectAs(db, cipher, second, member, now), types:ERR_MEMBER_ALREADY_LINKED);

    _ = check connection:removeConnection(new connection:PgConnectionRepository(db, {actorId: first}), first, now);
    connection:LinkedInConnection taken = check connectAs(db, cipher, second, member, now);
    test:assertEquals(taken.employeeId, second, "the removed connection no longer holds the member");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM connection_member_connection
        WHERE member_urn = ${member}`), 2, "the removed row stays, with its member URN");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit_log WHERE action = 'ConnectionRemoved'
        AND entity_id = ${first}`), 1, "the removal is still audited");

    // The first employee reconnecting now: refused in the domain check, and by the partial unique index too.
    assertCode(connectAs(db, cipher, first, member, now), types:ERR_MEMBER_ALREADY_LINKED);
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testNativeRepostPointsAndLastSync() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "native-pts");
    string campaignId = types:newUuidV7();
    string otherCampaign = types:newUuidV7();
    scoring:PointRule[] rules = check (new scoring:PgPointRuleRepository(db)).all();
    time:Utc now = time:utcNow();
    scoring:LedgerAppend award = check scoring:awardForEngagement(rules, {engagementId: types:newUuidV7(),
        provider: types:LINKEDIN, targetResourceUrn: "urn:li:share:" + uniq(), employeeId: emp,
        action: types:REPOST_COMMENTARY, campaignId}, "it-native", now);
    _ = check scoring:appendAward(new scoring:PgLedgerRepository(db), award);
    string po = check newEmployee(db, "native-po");
    // A PO adjustment naming the campaign is not reshare points.
    _ = check scoring:adjustPoints(new scoring:PgLedgerRepository(db, poActor(po)), emp, 7, "bonus", po, campaignId,
            (), now);
    map<int> points = check scoring:resharePointsByCampaign(db, emp, [campaignId, otherCampaign]);
    test:assertEquals(points, {[campaignId]: award.entry.points});
    _ = check scoring:reverseEntry(new scoring:PgLedgerRepository(db, poActor(po)), award.entry.reference, "dup", po,
            (), now);
    test:assertEquals(check scoring:resharePointsByCampaign(db, emp, [campaignId]), {[campaignId]: 0},
            "net of the reversal");
    test:assertEquals(check scoring:resharePointsByCampaign(db, emp, []), {});

    string post = "urn:li:share:" + uniq();
    _ = check db->execute(`INSERT INTO sharing_sync_cursor (provider, provider_api, resource_urn, endpoint, cursor,
            last_run_at) VALUES ('linkedin', 'COMMUNITY_MANAGEMENT', ${post}, 'REACTIONS', '1', '2091-01-01T00:00:00Z')`);
    time:Utc? last = check sharing:lastSyncAt(db);
    _ = check db->execute(`DELETE FROM sharing_sync_cursor WHERE resource_urn = ${post}`);
    test:assertEquals(last, check time:utcFromString("2091-01-01T00:00:00Z"));
    check db.close();
}
