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


// Reporting integration tests (group `integration`, `AMPLIFY_IT=true`): every query behind the dashboards and
// the group leaderboards (`recognition:pointsByEmail`, `reporting:*`) against a migrated PostgreSQL 18, as
// `amplify_api` (the role that serves them). The database is shared with the other integration tests, so
// counts are compared before and after, never against absolute numbers.

import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.recognition;
import amplify_domain.reporting;
import amplify_domain.scoring;
import amplify_domain.sharing;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], enable: itEnabled}
function testPointsByEmailReturnsLowercaseEmailAndTotal() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "rptpts");
    string po = check newEmployee(db, "rptptspo");
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    types:LedgerEntry adj = check scoring:adjustPoints(ledger, emp, 40, "IT points by email", po, (), "it-rpt-adj", time:utcNow());

    recognition:EmailPoints[] all = check recognition:pointsByEmail(db);
    recognition:EmailPoints[] mine = from recognition:EmailPoints e in all
        where e.email == emp + "@wso2.com"
        select e;
    test:assertEquals(mine.length(), 1, "one row per person");
    test:assertEquals(mine[0].totalPoints, 40);
    test:assertTrue(all.every(e => e.email == e.email.toLowerAscii()), "emails come back lowercase");

    _ = check scoring:reverseEntry(ledger, adj.reference, "IT reversal", po, "it-rpt-rev", time:utcNow());
    recognition:EmailPoints[] after = from recognition:EmailPoints e in check recognition:pointsByEmail(db)
        where e.email == emp + "@wso2.com"
        select e;
    test:assertEquals(after[0].totalPoints, 0, "a reversal brings the total back");
    // A period with no standings has no rows for them.
    recognition:EmailPoints[] none = from recognition:EmailPoints e in check recognition:pointsByEmail(db, "1999-01")
        where e.email == emp + "@wso2.com"
        select e;
    test:assertEquals(none.length(), 0);
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testRepostsAndPostsFeedTheBoards() returns error? {
    postgresql:Client apiDb = check api();
    postgresql:Client jobsDb = check jobs();
    string po = check newEmployee(apiDb, "rptpo");
    string emp = check newEmployee(apiDb, "rptshare");
    time:Utc t0 = time:utcNow();
    int liveBefore = (check reporting:liveCounts(apiDb)).live;
    int repostsBefore = check reporting:repostsBetween(apiDb, time:utcAddSeconds(t0, -60), time:utcAddSeconds(t0, 3600));
    int peopleBefore = check reporting:repostingPeople(apiDb);
    int commentBefore = check reporting:commentaryRepostsBetween(apiDb, time:utcAddSeconds(t0, -60), time:utcAddSeconds(t0, 3600));
    reporting:ParticipationCounts funnelBefore = check reporting:participationCounts(apiDb);

    campaign:Campaign c = check registerCampaign(apiDb, po);
    test:assertEquals((check reporting:liveCounts(apiDb)).live, liveBefore + 1, "the new campaign is live");

    sharing:CampaignSnapshot snap = {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn, open: true};
    sharing:ConnectionSnapshot conn = {memberUrn: "urn:li:person:" + uniq(), usable: true};
    sharing:ShareRequest req = check sharing:requestShare(new sharing:PgShareRepository(apiDb, {actorId: emp}), snap,
            conn, {employeeId: emp, kind: types:REPOST}, time:utcNow());
    sharing:PublishResult published = check sharing:markPublished(req, "urn:li:share:" + uniq(), conn.memberUrn,
            types:newUuidV7(), time:utcNow());
    check (new sharing:PgShareRepository(jobsDb)).recordPublish(published, req.version);

    // A second person reposts with their own words.
    string emp2 = check newEmployee(apiDb, "rptcomment");
    sharing:ConnectionSnapshot conn2 = {memberUrn: "urn:li:person:" + uniq(), usable: true};
    sharing:ShareRequest req2 = check sharing:requestShare(new sharing:PgShareRepository(apiDb, {actorId: emp2}), snap,
            conn2, {employeeId: emp2, kind: types:REPOST_COMMENTARY, commentary: "Worth a read"}, time:utcNow());
    sharing:PublishResult published2 = check sharing:markPublished(req2, "urn:li:share:" + uniq(), conn2.memberUrn,
            types:newUuidV7(), time:utcNow());
    check (new sharing:PgShareRepository(jobsDb)).recordPublish(published2, req2.version);

    test:assertEquals(check reporting:repostsBetween(apiDb, time:utcAddSeconds(t0, -60), time:utcAddSeconds(t0, 3600)),
            repostsBefore + 2);
    test:assertEquals(check reporting:repostingPeople(apiDb), peopleBefore + 2);
    reporting:ParticipationCounts funnel = check reporting:participationCounts(apiDb);
    test:assertEquals(funnel.reposted, funnelBefore.reposted + 2);
    test:assertEquals(funnel.active30Days, funnelBefore.active30Days + 2);

    reporting:CampaignRow[] campaigns = from reporting:CampaignRow p in check reporting:campaignRows(apiDb, 30, 500, time:utcNow())
        where p.campaignId == c.id
        select p;
    test:assertEquals(campaigns.length(), 1);
    test:assertEquals(campaigns[0].reposts, 2);
    test:assertEquals(campaigns[0].repostsWithCommentary, 1, "one plain repost, one with commentary");
    test:assertEquals(campaigns[0].status, "OPEN");
    test:assertEquals(campaigns[0].categoryCode, "PRODUCT");
    test:assertTrue(campaigns[0].categoryLabel != "", "label joined from campaign.category");

    int[] byDay = check reporting:repostsByDay(apiDb, c.id, 7);
    test:assertEquals(byDay.length(), 7);
    test:assertEquals(byDay[0], 2, "published inside the first 24 hours");
    test:assertEquals(byDay.reduce(isolated function(int a, int b) returns int => a + b, 0), 2);

    test:assertEquals(check reporting:commentaryRepostsBetween(apiDb, time:utcAddSeconds(t0, -60), time:utcAddSeconds(t0, 3600)),
            commentBefore + 1, "one of the two reposts carries commentary");

    reporting:CategoryCount[] cats = from reporting:CategoryCount k in
            check reporting:repostsByCategory(apiDb, time:utcAddSeconds(t0, -60))
        where k.code == "PRODUCT"
        select k;
    test:assertEquals(cats.length(), 1);
    test:assertTrue(cats[0].reposts >= 1);
    test:assertTrue(cats[0].repostsWithCommentary >= 1 && cats[0].repostsWithCommentary <= cats[0].reposts,
            "reposts with comments are part of the category's reposts, not on top of them");

    reporting:MonthCount[] months = check reporting:monthlyReposts(apiDb, 6);
    test:assertEquals(months.length(), 6, "zero-filled, one row per month");
    test:assertTrue(months[5].reposts >= 1, "this month includes the repost");
    test:assertTrue(months[0].monthStart < months[5].monthStart, "oldest first");
    check apiDb.close();
    check jobsDb.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testConnectionBreakdownSplitsExpiredFromRevoked() returns error? {
    postgresql:Client db = check api();
    string expiredEmp = check newEmployee(db, "rptexp");
    string revokedEmp = check newEmployee(db, "rptrev");
    string removedEmp = check newEmployee(db, "rptrem");
    reporting:ConnectionBreakdown before = check reporting:connectionBreakdown(db);
    reporting:ParticipationCounts funnelBefore = check reporting:participationCounts(db);

    // Token past its expiry.
    _ = check db->execute(`
        INSERT INTO connection.member_connection (employee_id, provider, member_urn, provider_api, access_expires_at, connected_at)
        VALUES (${expiredEmp}, 'linkedin', ${"urn:li:person:" + uniq()}, 'SHARE_ON_LINKEDIN', now() - interval '1 day', now() - interval '61 days')`);
    // Not expired, but no token to use: needs reconnect for another reason.
    _ = check db->execute(`
        INSERT INTO connection.member_connection (employee_id, provider, member_urn, provider_api, access_expires_at, connected_at)
        VALUES (${revokedEmp}, 'linkedin', ${"urn:li:person:" + uniq()}, 'SHARE_ON_LINKEDIN', now() + interval '30 days', now() - interval '1 day')`);
    // Removed connections are not counted at all.
    _ = check db->execute(`
        INSERT INTO connection.member_connection (employee_id, provider, member_urn, provider_api, access_expires_at, connected_at, removed_at)
        VALUES (${removedEmp}, 'linkedin', ${"urn:li:person:" + uniq()}, 'SHARE_ON_LINKEDIN', now() - interval '1 day', now() - interval '5 days', now())`);

    reporting:ConnectionBreakdown after = check reporting:connectionBreakdown(db);
    test:assertEquals(after.expired, before.expired + 1);
    test:assertEquals(after.revoked, before.revoked + 1);
    test:assertEquals(after.active, before.active);
    reporting:ParticipationCounts funnel = check reporting:participationCounts(db);
    test:assertEquals(funnel.connected, funnelBefore.connected + 2, "removed connections don't count as connected");
    test:assertEquals(funnel.expired, funnelBefore.expired + 1);
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testAnnouncementDeliveryShowsRetriesAndCounts() returns error? {
    postgresql:Client apiDb = check api();
    postgresql:Client jobsDb = check jobs();
    string po = check newEmployee(apiDb, "rptcard");
    time:Utc since = time:utcAddSeconds(time:utcNow(), -60);
    reporting:CardCounts before = check reporting:cardCounts(apiDb, since);
    campaign:Campaign c = check registerCampaign(apiDb, po);
    int outboxId = check apiDb->queryRow(`SELECT id FROM messaging.outbox WHERE idempotency_key = ${"CampaignRegistered:" + c.id}`);

    reporting:CardCounts registered = check reporting:cardCounts(apiDb, since);
    test:assertEquals(registered.total, before.total + 1);
    test:assertEquals(registered.queued, before.queued + 1, "a campaign with no announcement row counts as queued");
    test:assertEquals((check reporting:deliveryOf(apiDb, [c.id])).length(), 0, "no announcement row yet");

    // Jobs creates the row and fails once: queued and retrying.
    _ = check jobsDb->execute(`
        INSERT INTO announcement.announcement (campaign_id, outbox_id, space, thread_key)
        VALUES (CAST(${c.id} AS uuid), ${outboxId}, 'dev-test', ${"campaign-" + c.id})`);
    _ = check jobsDb->execute(`UPDATE messaging.outbox SET attempts = 2 WHERE id = ${outboxId}`);
    reporting:Delivery queued = check deliveryFor(apiDb, c.id);
    test:assertEquals(queued.status, "QUEUED");
    test:assertEquals(queued.attempts, 2, "the retry the worker is on");
    reporting:CardCounts retrying = check reporting:cardCounts(apiDb, since);
    test:assertEquals(retrying.retrying, before.retrying + 1);

    // Sent.
    _ = check jobsDb->execute(`UPDATE announcement.announcement SET sent_at = now() WHERE campaign_id = CAST(${c.id} AS uuid)`);
    reporting:Delivery sent = check deliveryFor(apiDb, c.id);
    test:assertEquals(sent.status, "SENT");
    test:assertEquals(sent.attempts, (), "attempts only show while queued");
    test:assertTrue(sent.sentAt is time:Utc);
    reporting:CardCounts done = check reporting:cardCounts(apiDb, since);
    test:assertEquals(done.sent, before.sent + 1);
    test:assertEquals(done.queued, before.queued);
    check apiDb.close();
    check jobsDb.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testPointsInMonthAndEmptyIdLists() returns error? {
    postgresql:Client db = check api();
    test:assertTrue((check reporting:pointsInMonth(db, "1999-01-01")) == 0);
    test:assertEquals((check reporting:deliveryOf(db, [])).length(), 0);
    reporting:LiveCounts live = check reporting:liveCounts(db);
    test:assertTrue(live.livePriority <= live.live && live.closingWithin7Days <= live.live);
    check db.close();
}

function deliveryFor(postgresql:Client db, string campaignId) returns reporting:Delivery|error {
    reporting:Delivery? d = (check reporting:deliveryOf(db, [campaignId]))[campaignId];
    return d is () ? error("no announcement row for " + campaignId) : d;
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testPointsAwardedMoveWithTheLedgerInEveryWindow() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "rptwin");
    string po = check newEmployee(db, "rptwinpo");
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    reporting:PointsAwarded before = check reporting:pointsAwarded(db);
    types:LedgerEntry adj = check scoring:adjustPoints(ledger, emp, 40, "IT window", po, (), "it-rpt-win", time:utcNow());
    reporting:PointsAwarded after = check reporting:pointsAwarded(db);
    test:assertEquals(after.month, before.month + 40);
    test:assertEquals(after.year, before.year + 40);
    _ = check scoring:reverseEntry(ledger, adj.reference, "IT window reversal", po, "it-rpt-win-rev", time:utcNow());
    reporting:PointsAwarded reversed = check reporting:pointsAwarded(db);
    test:assertEquals(reversed.month, before.month, "a reversal nets the adjustment out");
    test:assertTrue(reversed.year >= reversed.month, "year contains month");
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testSnapshotReadsEverythingInOneRepeatableReadTransaction() returns error? {
    postgresql:Client apiDb = check api();
    postgresql:Client jobsDb = check jobs();
    string po = check newEmployee(apiDb, "rptsnap");
    string emp = check newEmployee(apiDb, "rptsnapshare");
    campaign:Campaign c = check registerCampaign(apiDb, po);
    sharing:CampaignSnapshot snap = {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn, open: true};
    sharing:ConnectionSnapshot conn = {memberUrn: "urn:li:person:" + uniq(), usable: true};
    sharing:ShareRequest req = check sharing:requestShare(new sharing:PgShareRepository(apiDb, {actorId: emp}), snap,
            conn, {employeeId: emp, kind: types:REPOST_COMMENTARY, commentary: "Snapshot"}, time:utcNow());
    sharing:PublishResult published = check sharing:markPublished(req, "urn:li:share:" + uniq(), conn.memberUrn,
            types:newUuidV7(), time:utcNow());
    check (new sharing:PgShareRepository(jobsDb)).recordPublish(published, req.version);

    time:Utc now = time:utcNow();
    // The statement SET TRANSACTION must be the first one in the transaction or Postgres refuses the whole read.
    reporting:Snapshot s = check reporting:loadSnapshot(apiDb, now);
    test:assertEquals(s.asOf, now);
    test:assertEquals(s.live, check reporting:liveCounts(apiDb));
    test:assertEquals(s.connections, check reporting:connectionBreakdown(apiDb));
    test:assertEquals(s.participation, check reporting:participationCounts(apiDb));
    test:assertEquals(s.points, check reporting:pointsAwarded(apiDb));
    test:assertEquals(s.monthly.length(), 6);
    test:assertTrue(s.repostsThisMonth >= 1 && s.repostsThisMonthWithCommentary >= 1
        && s.repostsThisMonthWithCommentary <= s.repostsThisMonth);
    reporting:CampaignRow[] mine = from reporting:CampaignRow r in s.campaigns
        where r.campaignId == c.id
        select r;
    test:assertEquals(mine.length(), 1, "the new campaign is in the snapshot");
    test:assertEquals(mine[0].reposts, 1);
    test:assertEquals(mine[0].repostsWithCommentary, 1);
    test:assertEquals(s.shares.failedByReason.length(), 3);
    check apiDb.close();
    check jobsDb.close();
}
