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


// M5 integration tests (group `integration`, `AMPLIFY_IT=true`) for the flows amplify-api runs, against a
// migrated PostgreSQL 18 as `amplify_api`: register → list → share, OAuth state single use, external
// share → approve → amplified top-up (one transaction each), adjust → reverse → standing, idempotency
// keys, settings optimistic lock, and every PO dashboard / leaderboard read query.

import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.recognition;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

@test:Config {groups: ["integration"], enable: itEnabled}
function testM5RegisterListAndShare() returns error? {
    postgresql:Client db = check api();
    string po = check newEmployee(db, "m5po");
    campaign:Campaign c = check registerCampaign(db, po);
    time:Utc now = time:utcNow();
    campaign:CampaignPage page = check campaign:listCampaigns(db, {statuses: [campaign:OPEN], windowDays: 14,
        tag: "it", size: 50}, now);
    test:assertTrue(page.total >= 1);
    test:assertTrue(page.items.some(i => i.id == c.id), "the new campaign is listed");
    test:assertTrue((check campaign:listTags(db)).indexOf("ballerina") !is ());
    test:assertTrue((check campaign:listCategories(db)).length() > 0);

    string emp = check newEmployee(db, "m5share");
    sharing:ShareRequest r = check sharing:requestShare(new sharing:PgShareRepository(db, {actorId: emp}),
            {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn, open: true},
            {memberUrn: "urn:li:person:" + uniq(), usable: true}, {employeeId: emp, kind: types:REPOST}, now);
    sharing:ShareView[] mine = check sharing:sharesOf(db, emp);
    test:assertEquals(mine.length(), 1);
    test:assertEquals(mine[0].id, r.id);
    test:assertEquals(mine[0].status, sharing:QUEUED);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM messaging.outbox
                                       WHERE idempotency_key = ${"RepostRequested:" + r.id + ":1"}`), 1);
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testM5OAuthStateIsSingleUseAndOwned() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "m5oauth");
    connection:PgOAuthStateRepository repo = new (db);
    time:Utc now = time:utcNow();
    connection:OAuthState s = check connection:newOAuthState(emp, "/amplify/posts", (), now);
    check repo.issue(s);
    test:assertEquals(check repo.consume(s.state, "someone-else", now), (), "another employee can't use it");
    connection:OAuthState? used = check repo.consume(s.state, emp, now);
    test:assertTrue(used is connection:OAuthState);
    test:assertEquals(check repo.consume(s.state, emp, now), (), "single use");
    connection:OAuthState old = check connection:newOAuthState(emp, (), (), time:utcAddSeconds(now, -700));
    check repo.issue(old);
    test:assertEquals(check repo.consume(old.state, emp, now), (), "expired after 10 minutes");
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testM5ApproveAndAmplifyAwardInTheSameTransaction() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "m5ext");
    string po = check newEmployee(db, "m5extpo");
    external_sharing:PgExternalShareRepository repo = new (db, poActor(po), 3);
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    time:Utc now = time:utcNow();
    external_sharing:ExternalShare claim = check external_sharing:submitExternalShare(
            new external_sharing:PgExternalShareRepository(db, {actorId: emp}),
            {employeeId: emp, evidenceUrl: "https://medium.com/@it/" + uniq(), certified: true}, now);
    scoring:PointRule[] rules = check (new scoring:PgPointRuleRepository(db)).all();
    _ = check external_sharing:approveWithPoints(repo, rules, claim.id, po, "it-approve", now);
    recognition:Standing? afterApprove = check recognition:standingOf(db, emp);
    int ownPost = (check scoring:ruleInForce(rules, types:OWN_POST, now)).points;
    int amplifiedTier = (check scoring:ruleInForce(rules, types:OWN_POST_AMPLIFIED, now)).points;
    test:assertEquals(afterApprove is recognition:Standing ? afterApprove.totalPoints : -1, ownPost);
    _ = check external_sharing:amplifyWithPoints(repo, rules, claim.id, po, "it-amplify", time:utcNow(), ledger);
    recognition:Standing? afterAmplify = check recognition:standingOf(db, emp);
    test:assertEquals(afterAmplify is recognition:Standing ? afterAmplify.totalPoints : -1, amplifiedTier,
            "approve + top-up = the amplified tier");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM scoring.points_ledger WHERE employee_id = ${emp}`), 2);
    // A failed award rolls back the decision: amplifying again is refused and writes nothing.
    assertCode(external_sharing:amplifyWithPoints(repo, rules, claim.id, po, (), time:utcNow(), ledger), types:ERR_ALREADY_AMPLIFIED);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM scoring.points_ledger WHERE employee_id = ${emp}`), 2);

    external_sharing:ReviewQueue queue = check external_sharing:reviewQueue(db, 48, time:utcNow());
    test:assertEquals(queue.pending, check count(db, `SELECT count(*)::int FROM external_sharing.external_share
                                                      WHERE decision IS NULL`), "the queue counts the undecided claims");
    external_sharing:ReviewThroughput tp = check external_sharing:reviewThroughput(db, time:utcAddSeconds(now, -60));
    test:assertTrue(tp.approved >= 1 && tp.amplified >= 1);
    external_sharing:ExternalSharePage review = check external_sharing:claimsForReview(db, external_sharing:AMPLIFIED, 0, 10);
    test:assertTrue(review.total >= 1);
    test:assertEquals((check external_sharing:claimsOf(db, emp)).length(), 1);
}

// Round 2: the amplified top-up is priced from the ledger, so reversing the OWN_POST award first means the
// top-up pays the whole amplified tier instead of only the rule gap.
@test:Config {groups: ["integration"], enable: itEnabled}
function testM5AmplifiedTopUpPricesAgainstTheLedger() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "m5topup");
    string po = check newEmployee(db, "m5topuppo");
    external_sharing:PgExternalShareRepository repo = new (db, poActor(po), 3);
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    time:Utc now = time:utcNow();
    external_sharing:ExternalShare claim = check external_sharing:submitExternalShare(
            new external_sharing:PgExternalShareRepository(db, {actorId: emp}),
            {employeeId: emp, evidenceUrl: "https://medium.com/@it/reversed-" + uniq(), certified: true}, now);
    scoring:PointRule[] rules = check (new scoring:PgPointRuleRepository(db)).all();
    _ = check external_sharing:approveWithPoints(repo, rules, claim.id, po, "it-topup-approve", now);
    int amplifiedTier = (check scoring:ruleInForce(rules, types:OWN_POST_AMPLIFIED, now)).points;
    types:LedgerReference ownPostReference = check types:awardReference(claim.evidence.provider,
            claim.evidence.normalized, emp, types:OWN_POST);
    _ = check scoring:reverseEntry(ledger, ownPostReference, "IT reassessing", po, "it-topup-rev", time:utcNow());
    recognition:Standing? reversed = check recognition:standingOf(db, emp);
    test:assertEquals(reversed is recognition:Standing ? reversed.totalPoints : -1, 0, "own post reversed to 0");
    _ = check external_sharing:amplifyWithPoints(repo, rules, claim.id, po, "it-topup-amplify", time:utcNow(), ledger);
    recognition:Standing? after = check recognition:standingOf(db, emp);
    test:assertEquals(after is recognition:Standing ? after.totalPoints : -1, amplifiedTier,
            "0 left on the ledger + the whole amplified tier as the top-up");
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testM5AdjustReverseUpdatesStanding() returns error? {    postgresql:Client db = check api();
    string emp = check newEmployee(db, "m5adj");
    string po = check newEmployee(db, "m5adjpo");
    scoring:PgLedgerRepository ledger = new (db, poActor(po), 3);
    time:Utc now = time:utcNow();
    int versionBefore = check recognition:standingVersion(db);
    types:LedgerEntry adj = check scoring:adjustPoints(ledger, emp, 40, "IT adjustment", po, (), "it-adj", now);
    recognition:Standing? s1 = check recognition:standingOf(db, emp);
    test:assertEquals(s1 is recognition:Standing ? s1.totalPoints : -1, 40);
    test:assertTrue(check recognition:standingVersion(db) > versionBefore, "standing version bumped");
    recognition:TeamPage found = check recognition:teamPage(db, recognition:PERIOD_ALL, (), "Name m5adj",
            recognition:SORT_NAME, 0, 10);
    test:assertTrue(found.total >= 1, "the board finds a person with points");
    _ = check scoring:reverseEntry(ledger, adj.reference, "IT reversal", po, "it-rev", time:utcNow());
    recognition:Standing? s2 = check recognition:standingOf(db, emp);
    test:assertEquals(s2 is recognition:Standing ? s2.totalPoints : -1, 0);
    assertCode(scoring:reverseEntry(ledger, adj.reference, "again", po, (), time:utcNow()), types:ERR_ALREADY_REVERSED);

    scoring:LedgerPage history = check scoring:historyOf(db, emp, 0, 10);
    test:assertEquals(history.total, 2);
    // Reversed back to 0: the row leaves the board (phase 1 lists only people with points), so it holds no
    // rank slot and isn't counted in `total`.
    recognition:TeamPage team = check recognition:teamPage(db, recognition:PERIOD_ALL, [emp + "@wso2.com"], (),
            recognition:SORT_RANK, 0, 10);
    test:assertEquals(team.total, 0, "a fully reversed row drops off the team board");
    test:assertEquals(team.items.length(), 0, "and comes back as no row");
    recognition:TeamPage search = check recognition:teamPage(db, recognition:PERIOD_ALL, (), "Name m5adj",
            recognition:SORT_NAME, 0, 10);
    test:assertFalse(search.items.some(i => i.standing.employeeId == emp),
            "search doesn't surface the reversed row either");
    // Whole company (no roster, no search): ranks come from the stored company rank (M11 fast path) and
    // match the window-function result of a filtered page.
    recognition:TeamPage company = check recognition:teamPage(db, recognition:PERIOD_ALL, (), (),
            recognition:SORT_RANK, 0, 1000);
    int standings = check db->queryRow(`SELECT count(*)::int FROM recognition.standing
                                        WHERE period_key = 'ALL' AND total_points > 0`);
    test:assertEquals(company.total, standings, "the whole-company total counts people with points");
    int lastRank = 0;
    foreach recognition:TeamEntry e in company.items {
        test:assertEquals(e.teamRank, e.standing.rank);
        test:assertTrue(e.teamRank >= lastRank, "ordered by rank");
        lastRank = e.teamRank;
    }
    recognition:TeamPage byPoints = check recognition:teamPage(db, recognition:PERIOD_ALL, (), (),
            recognition:SORT_POINTS, 0, 5);
    test:assertTrue(byPoints.items.length() > 0 && byPoints.total == company.total);
    test:assertTrue((check recognition:monthlyPointsOf(db, emp)).length() >= 1);
    test:assertEquals(check recognition:emailOf(db, emp), emp + "@wso2.com");
    test:assertTrue((check recognition:topStandings(db)).length() >= 1);
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testM5IdempotencyKeysAndSettings() returns error? {
    postgresql:Client db = check api();
    string emp = "emp-idem-" + uniq();
    time:Utc now = time:utcNow();
    test:assertEquals(check store:claimIdempotencyKey(db, emp, "k1", "h1", 86400, now), ());
    store:IdempotencyRecord? running = check store:claimIdempotencyKey(db, emp, "k1", "h1", 86400, now);
    test:assertEquals(running is store:IdempotencyRecord ? running.responseStatus : -1, ());
    check store:completeIdempotencyKey(db, emp, "k1", 201, {id: "x"});
    store:IdempotencyRecord? replay = check store:claimIdempotencyKey(db, emp, "k1", "h1", 86400, now);
    if replay is () {
        test:assertFail("expected a stored response");
    }
    test:assertEquals(replay.responseStatus, 201);
    test:assertEquals(replay.responseBody, {id: "x"});
    test:assertEquals(check store:claimIdempotencyKey(db, emp, "k1", "h1", 86400, time:utcAddSeconds(now, 90000)), (),
            "an expired key is replaced");
    check store:releaseIdempotencyKey(db, emp, "k1");

    store:Setting[] settings = check store:readSettings(db);
    store:Setting topN = settings.filter(s => s.key == "leaderboard.top_n")[0];
    store:Actor admin = {actorId: "it-admin", roles: ["amplify_admin"]};
    check store:updateSettings(db, admin, [{key: topN.key, value: topN.value, expectedVersion: topN.version}], now);
    error? stale = store:updateSettings(db, admin, [{key: topN.key, value: 3, expectedVersion: topN.version}], now);
    test:assertTrue(stale is types:DomainError && stale.detail().code == types:ERR_VERSION_CONFLICT);
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testM5DashboardQueriesRun() returns error? {
    postgresql:Client db = check api();
    time:Utc now = time:utcNow();
    string month = time:utcToString(now).substring(0, 7);
    time:Utc monthStart = check time:utcFromString(month + "-01T00:00:00Z");
    transaction {
        _ = check scoring:actionRequiredCount(db);
        scoring:ActionPoints[] byAction = check scoring:pointsByAction(db, monthStart, time:utcAddSeconds(now, 60));
        test:assertEquals(byAction.length(), 12, "every dashboard group present: ten priced actions plus adjustments and reversals");
        _ = check recognition:recognitionTotals(db, month + "-01", now);
        _ = check connection:connectionCounts(db);
        campaign:Campaign[] recent = check campaign:dashboardCampaigns(db, 30, 20, now);
        string[] ids = from var c in recent select c.id;
        _ = check recognition:campaignNumbers(db, ids);
        _ = check announcements:statusesOf(db, ids);
        sharing:ShareHealth health = check sharing:shareHealth(db, time:utcAddSeconds(now, -604800));
        test:assertEquals(health.failedByReason.length(), 3);
        _ = check scoring:recentCorrections(db, 10);
        check commit;
    }
    announcements:PgAnnouncementRepository repo = new (db);
    _ = check repo.list(announcements:FAILED, 10);
}
