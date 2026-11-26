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

// The page connection and the engagement sync repositories against PostgreSQL (V025): org tokens sealed as ORG and
// replaced in the pointer's transaction, the call budget in one statement, a synced engagement with its event, the
// reshare de-duplication against an in-app share, and the native intent.

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.sharing;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], enable: itEnabled}
function testOrgConnectionRoundTrip() returns error? {
    postgresql:Client db = check api();
    crypto:TokenCipher cipher = check new ([check crypto:keyFromBase64("k1",
        "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")], "k1");
    string page = "urn:li:organization:9" + uniq().substring(0, 6);
    time:Utc now = time:utcNow();
    connection:StoredToken access = check connection:sealOrgToken(cipher, "a-1", page, "ACCESS",
            time:utcAddSeconds(now, 5184000), now);
    connection:StoredToken refresh = check connection:sealOrgToken(cipher, "r-1", page, "REFRESH",
            time:utcAddSeconds(now, 31536000), now);
    connection:PgOrgConnectionRepository repo = new (db, poActor("admin-it"));
    check repo.save(connection:connectOrg((), {orgUrn: page, connectedBy: "admin-it", scopes: ["r_organization_social_feed"],
        access, refresh}, now), ());
    connection:OrgConnection? stored = check repo.find(types:LINKEDIN, page);
    if stored is () {
        test:assertFail("page connection not stored");
    }
    test:assertEquals(stored.accessToken, connection:tokenRef(access));
    test:assertEquals(stored.refreshToken, connection:tokenRef(refresh));
    test:assertEquals(check count(db, `SELECT count(*)::int FROM connection_provider_token
        WHERE owner_type = 'ORG' AND owner_id = ${page}`), 2);

    connection:StoredToken access2 = check connection:sealOrgToken(cipher, "a-2", page, "ACCESS",
            time:utcAddSeconds(now, 5184000), now);
    check repo.save(check connection:refreshOrg(stored, access2, ()), stored.version);
    connection:OrgConnection refreshed = <connection:OrgConnection>check repo.find(types:LINKEDIN, page);
    connection:StoredToken? opened = check (new connection:PgTokenRepository(db)).find(
            <connection:TokenRef>refreshed.accessToken);
    test:assertEquals(check connection:openToken(cipher, <connection:StoredToken>opened), "a-2");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM connection_provider_token
        WHERE owner_type = 'ORG' AND owner_id = ${page}`), 2, "the old access row went with the refresh");
    test:assertTrue(repo.save(check connection:refreshOrg(stored, access2, ()), stored.version) is error,
            "a stale version is refused");

    check repo.save(connection:revokeOrg(refreshed, now), refreshed.version);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM connection_provider_token
        WHERE owner_type = 'ORG' AND owner_id = ${page}`), 0, "a disconnect deletes both rows");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit_log
        WHERE entity_type = 'connection_org_connection' AND entity_id = ${page}`), 3);
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testSyncRepositoryRecordsOncePerPostAndDetectsIntent() returns error? {
    postgresql:Client db = check jobs();
    string po = check newEmployee(db, "sync-po");
    campaign:Campaign c = check registerCampaign(db, po);
    string emp = check newEmployee(db, "sync-emp");
    sharing:PgEngagementSyncRepository repo = new (db);
    time:Utc now = time:utcNow();

    // Budget: two calls, then no more today.
    string day = time:utcToString(now).substring(0, 10);
    _ = check db->execute(`DELETE FROM sharing_api_usage WHERE day = CAST(${day} AS date)`);
    test:assertTrue(check repo.takeCall(now, 2));
    test:assertTrue(check repo.takeCall(now, 2));
    test:assertFalse(check repo.takeCall(now, 2), "the third call is over the budget");
    test:assertEquals(check sharing:apiCallsOn(db, now), 2);

    // Cursor upsert.
    check repo.saveCursor(c.resourceUrn, sharing:REACTIONS, "5", now);
    check repo.saveCursor(c.resourceUrn, sharing:REACTIONS, "7", now);
    test:assertEquals(check repo.cursor(c.resourceUrn, sharing:REACTIONS), "7");
    test:assertEquals(check repo.cursor(c.resourceUrn, sharing:COMMENTS), ());

    // Native intent, then a reaction, a second reaction (refused), and a reshare that detects the intent.
    sharing:PgNativeIntentRepository intents = new (db);
    sharing:NativeIntent opened = check intents.open(emp, c.id, now);
    test:assertEquals(sharing:nativeStatus(opened, now), sharing:LOOKING);
    sharing:SyncCampaign sc = {id: c.id, resourceUrn: c.resourceUrn, opensAt: c.opensAt, closesAt: c.closesAt};
    string member = "urn:li:person:it" + uniq();
    sharing:Observed reaction = {kind: "REACTION", actorUrn: member, targetUrn: c.resourceUrn, occurredAt: now};
    test:assertTrue(check repo.recordSynced(sharing:syncedEngagement(reaction, sc, member, emp, types:newUuidV7(), now), now));
    test:assertFalse(check repo.recordSynced(sharing:syncedEngagement(reaction, sc, member, emp, types:newUuidV7(), now),
            now), "one reaction per post per person");
    sharing:Observed reshare = {kind: "RESHARE", actorUrn: member, targetUrn: c.resourceUrn,
        activityUrn: "urn:li:share:" + uniq(), occurredAt: now};
    test:assertTrue(check repo.recordSynced(sharing:syncedEngagement(reshare, sc, member, emp, types:newUuidV7(), now), now));
    sharing:Observed another = {kind: "RESHARE", actorUrn: member, targetUrn: c.resourceUrn,
        activityUrn: "urn:li:share:" + uniq(), hasCommentary: true, occurredAt: now};
    test:assertFalse(check repo.recordSynced(sharing:syncedEngagement(another, sc, member, emp, types:newUuidV7(), now),
            now), "a second reshare of the same post is covered by the first");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM messaging_outbox o
        JOIN sharing_engagement e ON o.aggregate_id = e.id::text
        WHERE e.employee_id = ${emp} AND o.event_type = 'EngagementRecorded'`), 2, "one event per recorded engagement");
    sharing:NativeIntent[] mine = check intents.ofEmployee(emp);
    test:assertEquals(mine.length(), 1);
    test:assertEquals(sharing:nativeStatus(mine[0], now), sharing:DETECTED);
    sharing:NativeIntent clickedAgain = check intents.open(emp, c.id, time:utcAddSeconds(now, 60));
    test:assertEquals(clickedAgain.openedAt, mine[0].openedAt, "a click after detection keeps the first time");

    map<types:EmployeeId> found = check connection:employeesOfMembers(db, [member]);
    test:assertEquals(found.length(), 0, "no member connection for the made-up member");
    check db.close();
}
