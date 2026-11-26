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


// Reach and the SLT reports against PostgreSQL (group `integration`, `AMPLIFY_IT=true`): the Reach connection
// repository, the reach refresh's reads and writes, and the report queries that count reactions, comments and reach
// apart from reposts. Counts are compared before and after (the database is shared).

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.reporting;
import amplify_domain.sharing;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], enable: itEnabled}
function testReachConnectionRepositoryRoundTrip() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "reachconn");
    crypto:TokenCipher cipher = check new ([check crypto:keyFromBase64("k1",
        "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")], "k1");
    time:Utc now = time:utcNow();
    connection:StoredToken access = check connection:sealReachToken(cipher, "a-1", emp, "ACCESS",
            time:utcAddSeconds(now, 5184000), now);
    connection:StoredToken refresh = check connection:sealReachToken(cipher, "r-1", emp, "REFRESH",
            time:utcAddSeconds(now, 31536000), now);
    connection:PgReachConnectionRepository repo = new (db, {actorId: emp});
    int consentingBefore = check reporting:reachConsenting(db);
    check repo.save(connection:connectReach((), emp, ["r_member_postAnalytics"], access, refresh, now), ());
    connection:ReachConnection c = <connection:ReachConnection>check repo.find(emp);
    test:assertEquals(c.version, 1);
    test:assertEquals(c.refreshToken, connection:tokenRef(refresh));
    test:assertEquals(check reporting:reachConsenting(db), consentingBefore + 1);
    test:assertTrue((check repo.allConnections()).some(r => r.employeeId == emp));

    connection:StoredToken access2 = check connection:sealReachToken(cipher, "a-2", emp, "ACCESS",
            time:utcAddSeconds(now, 9000000), now);
    check repo.save(connection:refreshReach(c, access2, ()), c.version);
    test:assertTrue(repo.save(connection:refreshReach(c, access2, ()), c.version) is error, "a stale version");
    connection:ReachConnection renewed = <connection:ReachConnection>check repo.find(emp);
    test:assertEquals(renewed.version, 2);
    int rows = check db->queryRow(`SELECT count(*)::int FROM connection_provider_token
                                   WHERE owner_type = 'MEMBER_ANALYTICS' AND owner_id = ${emp}`);
    test:assertEquals(rows, 2, "the old access row went, the new one and the refresh row stay");

    test:assertTrue(check repo.delete(renewed));
    test:assertEquals(check repo.find(emp), ());
    int left = check db->queryRow(`SELECT count(*)::int FROM connection_provider_token
                                   WHERE owner_type = 'MEMBER_ANALYTICS' AND owner_id = ${emp}`);
    test:assertEquals(left, 0);
    test:assertFalse(check repo.delete(renewed), "already gone");
    int audits = check db->queryRow(`SELECT count(*)::int FROM audit_log
                                     WHERE entity_type = 'connection_member_analytics' AND entity_id = ${emp}`);
    test:assertEquals(audits, 3, "connected, refreshed, disconnected");
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testReachReadingsAndTheReports() returns error? {
    postgresql:Client apiDb = check api();
    postgresql:Client jobsDb = check jobs();
    string po = check newEmployee(apiDb, "reachpo");
    string emp = check newEmployee(apiDb, "reachemp");
    string fan = check newEmployee(apiDb, "reachfan");
    time:Utc t0 = time:utcNow();
    time:Utc monthStart = check time:utcFromString(time:utcToString(t0).substring(0, 7) + "-01T00:00:00Z");
    reporting:EngagementTotals totalsBefore = check reporting:engagementTotalsBetween(apiDb, monthStart,
            time:utcAddSeconds(t0, 3600));
    int repostsBefore = check reporting:repostsBetween(apiDb, monthStart, time:utcAddSeconds(t0, 3600));

    campaign:Campaign c = check registerCampaign(apiDb, po);
    sharing:CampaignSnapshot snap = {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn, open: true};
    sharing:ConnectionSnapshot conn = {memberUrn: "urn:li:person:" + uniq(), usable: true};
    sharing:ShareRequest req = check sharing:requestShare(new sharing:PgShareRepository(apiDb, {actorId: emp}), snap,
            conn, {employeeId: emp, kind: types:REPOST}, time:utcNow());
    string postUrn = "urn:li:share:" + uniq();
    sharing:PublishResult published = check sharing:markPublished(req, postUrn, conn.memberUrn, types:newUuidV7(),
            time:utcNow());
    check (new sharing:PgShareRepository(jobsDb)).recordPublish(published, req.version);

    // A synced reaction and comment on the campaign post: counted, never as reposts.
    foreach [string, string?] [action, activity] in [["REACTION", ()], ["COMMENT", "urn:li:comment:(x," + uniq() + ")"]] {
        _ = check jobsDb->execute(`INSERT INTO sharing_engagement (provider, provider_api, origin, target_resource_urn,
                campaign_id, actor_member_urn, employee_id, action, activity_urn, occurred_at)
            VALUES ('linkedin', 'COMMUNITY_MANAGEMENT', 'API_SYNC', ${c.resourceUrn}, CAST(${c.id} AS uuid),
                ${"urn:li:person:" + uniq()}, ${fan}, ${action}, ${activity}, now())`);
    }
    test:assertEquals(check reporting:repostsBetween(apiDb, monthStart, time:utcAddSeconds(t0, 3600)), repostsBefore + 1,
            "the reaction and the comment are not reposts");

    // The refresh finds the share for a consenting employee, reads it once a day.
    sharing:PgReachRepository reach = new (jobsDb);
    string today = time:utcToString(t0).substring(0, 10);
    sharing:ReachTarget[] targets = check reach.sharesToMeasure([emp, fan], time:utcAddSeconds(t0, -86400), today);
    test:assertEquals(targets.length(), 1, "only the in-app repost, not the synced reaction or comment");
    test:assertEquals(targets[0].postUrn, postUrn);
    check reach.saveReading(targets[0], {impressions: 300, membersReached: 120}, t0);
    check reach.saveReading(targets[0], {impressions: 350, membersReached: 140}, t0);
    test:assertEquals((check reach.sharesToMeasure([emp], time:utcAddSeconds(t0, -86400), today)).length(), 0,
            "read today already");

    reporting:CampaignRow[] rows = check reporting:campaignRows(apiDb, 30, 500, t0);
    reporting:CampaignRow[] mine = from reporting:CampaignRow r in rows where r.campaignId == c.id select r;
    test:assertEquals(mine.length(), 1);
    test:assertEquals(mine[0].reposts, 1);
    test:assertEquals(mine[0].reactions, 1);
    test:assertEquals(mine[0].comments, 1);
    test:assertEquals(mine[0].impressions, 350, "the day's latest reading");
    test:assertEquals(mine[0].membersReached, 140);
    test:assertEquals(mine[0].measuredReposts, 1);

    reporting:EngagementTotals totals = check reporting:engagementTotalsBetween(apiDb, monthStart,
            time:utcAddSeconds(t0, 3600));
    test:assertEquals(totals.reactions, totalsBefore.reactions + 1);
    test:assertEquals(totals.comments, totalsBefore.comments + 1);
    test:assertEquals(totals.membersReached, totalsBefore.membersReached + 140);

    reporting:PersonParticipation[] people = check reporting:participationByPerson(apiDb);
    reporting:PersonParticipation[] me = from reporting:PersonParticipation p in people
        where p.email == emp + "@wso2.com" select p;
    test:assertEquals(me.length(), 1);
    test:assertTrue(me[0].reposted);
    test:assertEquals(me[0].membersReached, 140);
    test:assertFalse(people.some(p => p.email == fan + "@wso2.com" && p.reposted), "a reaction is not a repost");

    reporting:ExportRow[] export = check reporting:exportRows(apiDb, time:utcAddSeconds(t0, -3600),
            time:utcAddSeconds(t0, 3600));
    reporting:ExportRow[] campaignRow = from reporting:ExportRow r in export
        where r.recordType == "CAMPAIGN" && r.campaignId == c.id select r;
    test:assertEquals(campaignRow.length(), 1);
    test:assertEquals(campaignRow[0].reactions, 1);
    test:assertEquals(campaignRow[0].comments, 1);
    test:assertEquals(campaignRow[0].reach, 140);
    reporting:ExportRow[] shareRow = from reporting:ExportRow r in export
        where r.recordType == "ENGAGEMENT" && r.employeeId == emp && r.campaignId == c.id select r;
    test:assertEquals(shareRow[0].reach, 140);
    check apiDb.close();
    check jobsDb.close();
}
