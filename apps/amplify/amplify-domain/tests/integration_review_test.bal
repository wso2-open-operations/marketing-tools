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


// Deep-review regression tests (2026-10-17, group `integration`, `AMPLIFY_IT=true`): concurrency of the
// ledger + recognition write, optimistic locking under two writers, rollback on a version conflict, the
// self-amplify guard, before/after audit rows, the announcement requeue guard, token re-seal on rotation
// and the paging guards.

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.identity;
import amplify_domain.recognition;
import amplify_domain.scoring;
import amplify_domain.store;

import ballerina/io;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

isolated function adjustOnce(postgresql:Client db, string emp, int points) returns error? {
    scoring:PgLedgerRepository ledger = new (db, {actorId: "it-po-concurrency", roles: ["amplify_po"]}, 3);
    _ = check scoring:adjustPoints(ledger, emp, points, "IT concurrency", "it-po-concurrency", (), (), time:utcNow());
}

// R-01: two ledger appends at once both re-rank the whole period. Without a period lock they deadlock
// (each holds its own standing row and waits for the other's in the re-rank UPDATE) or store ranks
// computed from a snapshot without the other's row.
@test:Config {groups: ["integration"], enable: itEnabled}
function testConcurrentLedgerAppendsNeitherDeadlockNorMisrank() returns error? {
    postgresql:Client db = check store:newClient({host: dbHost, port: dbPort, database: dbName, user: "amplify_api",
        password: apiDbPassword, sslMode: dbSslMode, maxOpenConnections: 12});
    string[] emps = [];
    foreach int i in 0 ..< 8 {
        emps.push(check newEmployee(db, "conc" + i.toString()));
    }
    // One sequential append first: the Ballerina runtime initialises some type descriptors lazily, and
    // the very first parallel strands can trip over that (ConcurrentModificationException) before any
    // SQL runs. The lock under test is about the database, so warm the runtime up.
    check adjustOnce(db, check newEmployee(db, "concwarm"), 1);
    int failures = 0;
    int runtimeRaces = 0;
    string firstError = "";
    foreach int round in 0 ..< 6 {
        future<error?>[] running = [];
        foreach int i in 0 ..< emps.length() {
            future<error?> f = start adjustOnce(db, emps[i], (i + 1) * (round + 1));
            running.push(f);
        }
        foreach int i in 0 ..< running.length() {
            error? result = waitFor(running[i]);
            if result is error && result.message().includes("ConcurrentModificationException") {
                // Known, rare race inside the Ballerina SQL/transaction runtime under parallel transactions
                // (R-13, HANDOFF in the review doc). Not what this test is about, and not retried here
                // (a retry could double-apply if the runtime reported the error after a commit): the
                // invariants below hold over whatever committed.
                runtimeRaces += 1;
                continue;
            }
            if result is error {
                failures += 1;
                firstError = firstError == "" ? result.message() : firstError;
            }
        }
    }
    io:println(string `R-13 runtime ConcurrentModificationException: ${runtimeRaces} of 48 appends`);
    test:assertEquals(failures, 0, "concurrent appends failed: " + firstError);
    // Every stored rank equals the dense rank recomputed over the committed totals.
    int misranked = check count(db, `
        SELECT count(*)::int FROM (
            SELECT s.rank, dense_rank() OVER (ORDER BY s.total_points DESC)::int AS expected
            FROM recognition.standing s WHERE s.period_key = 'ALL') r
        WHERE r.rank IS DISTINCT FROM r.expected`);
    test:assertEquals(misranked, 0, "stored ranks match the committed totals");
    // B12: each standing equals the sum of that employee's committed ledger rows (no lost or doubled
    // apply), and nothing was lost beyond the runtime races counted above.
    int expectedTotal = 0;
    int ledgerTotal = 0;
    foreach int i in 0 ..< emps.length() {
        expectedTotal += (i + 1) * 21;
        int ledger = check count(db, `SELECT COALESCE(sum(points), 0)::int FROM scoring.points_ledger
                                      WHERE employee_id = ${emps[i]}`);
        ledgerTotal += ledger;
        recognition:Standing? s = check recognition:standingOf(db, emps[i]);
        test:assertEquals(s is recognition:Standing ? s.totalPoints : -1, ledger, "standing = ledger for " + emps[i]);
    }
    // Not asserted: R-13 also loses the odd append silently (success reported, never committed); the
    // probe below reproduces that without Amplify code. Printed for the record.
    io:println(string `R-13 ledger total ${ledgerTotal} of ${expectedTotal} attempted`);
    check db.close();
}

isolated function waitFor(future<error?> f) returns error? {
    error? result = wait f;
    return result;
}

isolated function approveAs(postgresql:Client db, string claimId, string po) returns external_sharing:ExternalShare|error =>
    external_sharing:approveExternalShare(new external_sharing:PgExternalShareRepository(db,
        {actorId: po, roles: ["amplify_po"]}), claimId, po, time:utcNow());

// R-12: two POs approve the same claim at the same moment. Exactly one wins; the other gets
// VERSION_CONFLICT (or NOT_PENDING if it read after the commit), and only one decision event and audit
// row exist. Also proves a row-lock wait between two transactions in one process completes.
@test:Config {groups: ["integration"], enable: itEnabled}
function testTwoWritersOneWinsTheOtherConflicts() returns error? {
    postgresql:Client db = check store:newClient({host: dbHost, port: dbPort, database: dbName, user: "amplify_api",
        password: apiDbPassword, sslMode: dbSslMode, maxOpenConnections: 6});
    string emp = check newEmployee(db, "tw");
    string po1 = check newEmployee(db, "twpo1");
    string po2 = check newEmployee(db, "twpo2");
    external_sharing:ExternalShare claim = check external_sharing:submitExternalShare(
            new external_sharing:PgExternalShareRepository(db, {actorId: emp}),
            {employeeId: emp, evidenceUrl: "https://medium.com/@tw/" + uniq(), certified: true}, time:utcNow());
    future<external_sharing:ExternalShare|error> a = start approveAs(db, claim.id, po1);
    future<external_sharing:ExternalShare|error> b = start approveAs(db, claim.id, po2);
    external_sharing:ExternalShare|error ra = wait a;
    external_sharing:ExternalShare|error rb = wait b;
    test:assertTrue(ra is external_sharing:ExternalShare != rb is external_sharing:ExternalShare, "exactly one wins");
    error loser = ra is error ? ra : <error>rb;
    test:assertTrue(loser is types:DomainError, "the loser gets a domain code, not a raw SQL error");
    if loser is types:DomainError {
        string code = loser.detail().code;
        test:assertTrue(code == types:ERR_VERSION_CONFLICT || code == types:ERR_NOT_PENDING, code);
    }
    test:assertEquals(check count(db, `SELECT count(*)::int FROM messaging.outbox
                                       WHERE event_type = 'ExternalShareApproved' AND aggregate_id = ${claim.id}`), 1);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit.audit_log
                                       WHERE entity_id = ${claim.id} AND action = 'ExternalShareApproved'`), 1);
    check db.close();
}

// R-03: the update audit row carries `before` as well as `after` (threat model sample audit row).
// R-12: a stale write rolls back the whole unit of work: no outbox row, no audit row.
@test:Config {groups: ["integration"], enable: itEnabled}
function testAuditBeforeAfterAndVersionConflictRollsBack() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "ba");
    string po = check newEmployee(db, "bapo");
    external_sharing:PgExternalShareRepository repo = new (db, poActor(po));
    external_sharing:ExternalShare claim = check external_sharing:submitExternalShare(repo,
            {employeeId: emp, evidenceUrl: "https://medium.com/@ba/" + uniq(), certified: true}, time:utcNow());
    external_sharing:ExternalShare approved = check external_sharing:approveExternalShare(repo, claim.id, po, time:utcNow());
    string before = check db->queryRow(`SELECT before::text FROM audit.audit_log
                                        WHERE entity_id = ${claim.id} AND action = 'ExternalShareApproved'`);
    string after = check db->queryRow(`SELECT after::text FROM audit.audit_log
                                       WHERE entity_id = ${claim.id} AND action = 'ExternalShareApproved'`);
    test:assertEquals(check before.fromJsonString(), {status: "PENDING", version: 1});
    test:assertEquals(check after.fromJsonString(), {status: "APPROVED", version: 2});

    // Stale version: nothing of the unit of work survives.
    external_sharing:ExternalShare stale = check external_sharing:markAmplified(approved, time:utcNow());
    error? staleWrite = repo.update(stale, 1, [external_sharing:externalShareAmplifiedEvent(stale, po)]);
    assertCode(staleWrite, types:ERR_VERSION_CONFLICT);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM messaging.outbox
                                       WHERE event_type = 'ExternalShareAmplified' AND aggregate_id = ${claim.id}`), 0);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit.audit_log
                                       WHERE entity_id = ${claim.id} AND action = 'ExternalShareAmplified'`), 0);

    // Campaign edit, share and connection updates record before too.
    campaign:Campaign c = check registerCampaign(db, po);
    _ = check campaign:updateCampaign(new campaign:PgCampaignRepository(db, poActor(po)), c.id, 1, {title: "After"},
            time:utcNow());
    string cb = check db->queryRow(`SELECT before::text FROM audit.audit_log
                                    WHERE entity_id = ${c.id} AND action = 'CampaignUpdated'`);
    test:assertEquals(check cb.fromJsonString(), {version: 1, title: "Integration campaign", archived: false});

    // Settlement change: before = HELD.
    scoring:PgLedgerRepository ledger = new (db, poActor(po));
    types:LedgerEntry adj = check scoring:adjustPoints(ledger, emp, 3, "IT audit", po, (), (), time:utcNow());
    check ledger.updateSettlement(adj.reference, (), time:utcNow());
    string sb = check db->queryRow(`SELECT before::text FROM audit.audit_log
                                    WHERE entity_id = ${adj.reference} AND action = 'PointsSettlementChanged'`);
    test:assertEquals(check sb.fromJsonString(), {status: "HELD"});
    error? missing = ledger.updateSettlement("ADJ-" + types:newUuidV7(), (), time:utcNow());
    assertCode(missing, types:ERR_NOT_FOUND);

    // Setting change: before = the old value; an unknown key is NOT_FOUND, not VERSION_CONFLICT.
    store:Setting topN = (check store:readSettings(db)).filter(s => s.key == "leaderboard.top_n")[0];
    store:Actor admin = {actorId: "it-admin-" + uniq(), roles: ["amplify_admin"]};
    check store:updateSettings(db, admin, [{key: topN.key, value: topN.value, expectedVersion: topN.version}],
            time:utcNow());
    string setBefore = check db->queryRow(`SELECT before::text FROM audit.audit_log
                                           WHERE actor_id = ${admin.actorId} AND action = 'SettingChanged'`);
    test:assertEquals(check setBefore.fromJsonString(), {value: topN.value});
    error? unknown = store:updateSettings(db, admin, [{key: "nope.missing", value: 1, expectedVersion: 1}],
            time:utcNow());
    assertCode(unknown, types:ERR_NOT_FOUND);
    check db.close();
}

// R-02: a PO can't mark their own (approved) claim amplified and pay themselves the top-up.
@test:Config {groups: ["integration"], enable: itEnabled}
function testPoCantAmplifyOwnClaim() returns error? {
    postgresql:Client db = check api();
    string poClaimant = check newEmployee(db, "selfpo");
    string otherPo = check newEmployee(db, "otherpo");
    external_sharing:ExternalShare claim = check external_sharing:submitExternalShare(
            new external_sharing:PgExternalShareRepository(db, {actorId: poClaimant}),
            {employeeId: poClaimant, evidenceUrl: "https://medium.com/@self/" + uniq(), certified: true}, time:utcNow());
    scoring:PointRule[] rules = check (new scoring:PgPointRuleRepository(db)).all();
    _ = check external_sharing:approveWithPoints(new external_sharing:PgExternalShareRepository(db, poActor(otherPo)),
            rules, claim.id, otherPo, (), time:utcNow());
    external_sharing:ExternalShare|error ownMark = external_sharing:amplifyWithPoints(
            new external_sharing:PgExternalShareRepository(db, poActor(poClaimant)), rules, claim.id, poClaimant, (),
            time:utcNow(), new scoring:PgLedgerRepository(db, poActor(poClaimant)));
    assertCode(ownMark, types:ERR_SELF_REVIEW);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM scoring.points_ledger
                                       WHERE employee_id = ${poClaimant} AND action = 'OWN_POST_AMPLIFIED'`), 0);
    check db.close();
}

// R-06: the admin retry must not reset an outbox row a run is processing right now.
@test:Config {groups: ["integration"], enable: itEnabled}
function testAnnouncementRequeueSkipsARowInProgress() returns error? {
    postgresql:Client db = check api();
    string po = check newEmployee(db, "annpo");
    campaign:Campaign c = check registerCampaign(db, po);
    string key = "CampaignRegistered:" + c.id;
    _ = check db->execute(`UPDATE messaging.outbox SET status = 'IN_PROGRESS', locked_by = 'run-x',
                           locked_until = now() + interval '5 minutes' WHERE idempotency_key = ${key}`);
    announcements:PgAnnouncementRepository repo = new (db, poActor(po));
    error? busy = repo.requeue(c.id);
    assertCode(busy, types:ERR_ANNOUNCEMENT_NOT_FAILED);
    string lockedBy = check db->queryRow(`SELECT locked_by FROM messaging.outbox WHERE idempotency_key = ${key}`);
    test:assertEquals(lockedBy, "run-x", "the running claim is untouched");
    _ = check db->execute(`UPDATE messaging.outbox SET status = 'FAILED', locked_by = NULL, locked_until = NULL
                           WHERE idempotency_key = ${key}`);
    check repo.requeue(c.id);
    string status = check db->queryRow(`SELECT status FROM messaging.outbox WHERE idempotency_key = ${key}`);
    test:assertEquals(status, "PENDING");
    assertCode(repo.requeue(types:newUuidV7()), types:ERR_NOT_FOUND);
    check db.close();
}

// Token rotation, DB half (R-05): `updateSeal` swaps ciphertext/nonce/key id on the same row, guarded by
// the old key id; the cipher half (`TokenCipher.reseal`) arrives with amplify_common 0.6 (HANDOFF).
@test:Config {groups: ["integration"], enable: itEnabled}
function testTokenUpdateSealIsGuardedByTheOldKey() returns error? {
    postgresql:Client db = check jobs();
    byte[] k1 = [];
    byte[] k2 = [];
    foreach int i in 0 ..< 32 {
        k1.push(<byte>(i + 1));
        k2.push(<byte>(i + 7));
    }
    crypto:TokenCipher oldCipher = check new ([{keyId: "rv-1", key: k1}], "rv-1");
    crypto:TokenCipher ring = check new ([{keyId: "rv-1", key: k1}, {keyId: "rv-2", key: k2}], "rv-2");
    string emp = "emp-seal-" + uniq();
    time:Utc now = time:utcNow();
    connection:StoredToken stored = check connection:sealToken(oldCipher, "bearer-rotate", emp,
            time:utcAddSeconds(now, 3600), now);
    connection:PgTokenRepository tokens = new (db);
    // Only a sign-in creates a token row, so the fixture goes in through the API role: amplify_jobs has no INSERT.
    postgresql:Client seedDb = check api();
    check (new connection:PgTokenRepository(seedDb)).insert(stored);
    check seedDb.close();
    test:assertTrue(ring.needsRotation(stored.keyId));
    crypto:SealedToken fresh = check ring.seal(check connection:openToken(ring, stored),
            {tokenId: stored.tokenId, ownerId: stored.ownerId, provider: stored.provider});
    test:assertTrue(check tokens.updateSeal(stored, fresh));
    test:assertFalse(check tokens.updateSeal(stored, fresh), "second re-seal from the stale read is a no-op");
    connection:StoredToken? reread = check tokens.find(connection:tokenRef(stored));
    if reread is () {
        test:assertFail("row gone");
    }
    test:assertEquals(reread.keyId, "rv-2");
    test:assertFalse(ring.needsRotation(reread.keyId));
    test:assertEquals(check connection:openToken(ring, reread), "bearer-rotate");
    test:assertTrue(connection:openToken(oldCipher, reread) is error, "the old key alone can't read it any more");
    check db.close();
}

// R-07: paging guards. Negative page / size never reach SQL (they were raw errors), and a page past the
// end still reports the total.
@test:Config {groups: ["integration"], enable: itEnabled}
function testPagingGuardsAndTotalPastTheEnd() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "page");
    string po = check newEmployee(db, "pagepo");
    scoring:PgLedgerRepository ledger = new (db, poActor(po));
    _ = check scoring:adjustPoints(ledger, emp, 5, "IT paging 1", po, (), (), time:utcNow());
    _ = check scoring:adjustPoints(ledger, emp, 6, "IT paging 2", po, (), (), time:utcNow());
    scoring:LedgerPage negative = check scoring:historyOf(db, emp, -3, -1);
    test:assertEquals(negative.items.length(), 1, "size < 1 is 1, page < 0 is 0");
    test:assertEquals(negative.total, 2);
    scoring:LedgerPage past = check scoring:historyOf(db, emp, 9, 10);
    test:assertEquals(past.items.length(), 0);
    test:assertEquals(past.total, 2, "total survives past the last page");
    scoring:LedgerPage huge = check scoring:historyOf(db, emp, int:MAX_VALUE, 10);
    test:assertEquals(huge.total, 2, "no int overflow panic");

    recognition:TeamPage team = check recognition:teamPage(db, recognition:PERIOD_ALL, [emp + "@wso2.com"], (),
            recognition:SORT_RANK, 5, 10);
    test:assertEquals(team.items.length(), 0);
    test:assertEquals(team.total, 1);
    _ = check recognition:teamPage(db, recognition:PERIOD_ALL, (), (), recognition:SORT_RANK, -1, 0);

    external_sharing:ExternalSharePage review = check external_sharing:claimsForReview(db, (), -1, 0);
    test:assertTrue(review.items.length() <= 1);
    int all = check count(db, `SELECT count(*)::int FROM external_sharing.external_share`);
    external_sharing:ExternalSharePage beyond = check external_sharing:claimsForReview(db, (), 100000, 50);
    test:assertEquals(beyond.total, all);
    check db.close();
}

// Rebuild takes the same lock as the append and still matches the incremental totals.
@test:Config {groups: ["integration"], enable: itEnabled}
function testRebuildUnderTheLockMatchesIncrementalTotals() returns error? {
    postgresql:Client db = check jobs();
    // Every employee's total, not just their sum: a rebuild that moved points between people would still sum alike.
    string before = check db->queryRow(`SELECT COALESCE(string_agg(employee_id || ':' || total_points::text, ',' ORDER BY employee_id), '')
                                        FROM recognition.standing WHERE period_key = 'ALL'`);
    int version = check recognition:rebuild(db);
    test:assertTrue(version > 0);
    string after = check db->queryRow(`SELECT COALESCE(string_agg(employee_id || ':' || total_points::text, ',' ORDER BY employee_id), '')
                                       FROM recognition.standing WHERE period_key = 'ALL'`);
    test:assertEquals(after, before, "a rebuild reproduces every employee's incremental total");
    check db.close();
}

isolated function probeTx(postgresql:Client db, string tag, int i) returns error? {
    transaction {
        _ = check db->execute(`INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload, idempotency_key)
                               VALUES ('probe', ${tag}, 'Probe', CAST('{}' AS jsonb), ${tag + ":" + i.toString()})`);
        _ = check db->execute(`INSERT INTO audit.audit_log (actor_id, action, entity_type, entity_id, outcome)
                               VALUES ('probe', 'Probe', 'probe', ${tag}, 'SUCCESS')`);
        check commit;
    }
}

// R-13 reproducer (group `runtime-probe`, not in `integration`): 8 x 6 plain transactions (outbox row +
// audit row) started in parallel on one client, no Amplify code involved. On Ballerina 2201.13.3 /
// ballerinax/postgresql 1.19.1 some report success yet never commit (outbox = audit < 48), and some fail
// with ConcurrentModificationException. Run it with
// `AMPLIFY_IT=true bal test --groups runtime-probe`; it prints the counts and asserts nothing.
@test:Config {groups: ["runtime-probe"], enable: itEnabled}
function testRuntimeProbeConcurrentTransactions() returns error? {
    postgresql:Client db = check store:newClient({host: dbHost, port: dbPort, database: dbName, user: "amplify_api",
        password: apiDbPassword, sslMode: dbSslMode, maxOpenConnections: 12});
    string tag = "probe-" + uniq();
    int errors = 0;
    string firstErr = "";
    foreach int round in 0 ..< 6 {
        future<error?>[] fs = [];
        foreach int i in 0 ..< 8 {
            future<error?> f = start probeTx(db, tag, round * 8 + i);
            fs.push(f);
        }
        foreach future<error?> f in fs {
            error? r = waitFor(f);
            if r is error {
                errors += 1;
                firstErr = firstErr == "" ? r.message() : firstErr;
            }
        }
    }
    int outbox = check count(db, `SELECT count(*)::int FROM messaging.outbox WHERE aggregate_id = ${tag}`);
    int audit = check count(db, `SELECT count(*)::int FROM audit.audit_log WHERE entity_id = ${tag}`);
    io:println(string `PROBE errors=${errors} outbox=${outbox} audit=${audit} of 48 ${firstErr}`);
    check db.close();
}

// Jobs-side announcement writes (were untested): queue once, send with CampaignAnnounced + audit, the
// api's read port sees it; a failed card is listed by status.
@test:Config {groups: ["integration"], enable: itEnabled}
function testAnnouncementWriterQueueSendAndFail() returns error? {
    postgresql:Client apiDb = check api();
    postgresql:Client jobsDb = check jobs();
    announcements:PgAnnouncementWriter writer = new (jobsDb);
    announcements:PgAnnouncementRepository reader = new (apiDb);
    time:Utc now = time:utcNow();
    // Outbox ids feed the CampaignAnnounced idempotency key, so they must be unique per run.
    string sentId = types:newUuidV7();
    announcements:Announcement queued = check announcements:queueAnnouncement((), sentId, check int:fromHexString(uniq()), "dev-test", now);
    check writer.insertQueued(queued);
    check writer.insertQueued(queued);
    announcements:Announcement? stored = check reader.findByCampaign(sentId);
    if stored is () {
        test:assertFail("announcement not stored");
    }
    test:assertEquals(announcements:announcementStatus(stored), announcements:QUEUED);
    announcements:Announcement sent = check announcements:markSent(stored, "spaces/x/messages/y", now, "spaces/x/threads/z");
    check writer.save(sent, [announcements:campaignAnnouncedEvent(sent)]);
    announcements:Announcement? reread = check reader.findByCampaign(sentId);
    test:assertEquals(reread is announcements:Announcement ? reread.chatThreadName : (), "spaces/x/threads/z");
    test:assertEquals(check count(jobsDb, `SELECT count(*)::int FROM messaging.outbox
                                           WHERE event_type = 'CampaignAnnounced' AND aggregate_id = ${sentId}`), 1);
    test:assertEquals(check count(jobsDb, `SELECT count(*)::int FROM audit.audit_log
                                           WHERE entity_id = ${sentId} AND action = 'CampaignAnnounced'`), 1);

    string failedId = types:newUuidV7();
    announcements:Announcement q2 = check announcements:queueAnnouncement((), failedId, check int:fromHexString(uniq()), "dev-test", now);
    check writer.insertQueued(q2);
    check writer.save(check announcements:markFailed(q2, "HTTP 500", now), []);
    announcements:Announcement[] failed = check reader.list(announcements:FAILED, 50);
    test:assertTrue(failed.some(a => a.campaignId == failedId));
    map<announcements:AnnouncementStatus> statuses = check announcements:statusesOf(apiDb, [sentId, failedId]);
    test:assertEquals(statuses[sentId], announcements:SENT);
    test:assertEquals(statuses[failedId], announcements:FAILED);
    test:assertEquals(check reader.findByCampaign(types:newUuidV7()), ());
    check apiDb.close();
    check jobsDb.close();
}

// Identity: an upsert refreshes name and last seen, never moves first seen; an unknown id is `()`.
@test:Config {groups: ["integration"], enable: itEnabled}
function testEmployeeUpsertKeepsFirstSeen() returns error? {
    postgresql:Client db = check api();
    identity:PgEmployeeRepository repo = new (db);
    string id = "emp-idn-" + uniq();
    time:Utc t0 = time:utcNow();
    check repo.upsert(check identity:recordSeen((), {sub: id, email: id + "@wso2.com", name: "First"}, t0));
    identity:Employee? first = check repo.findById(id);
    time:Utc t1 = time:utcAddSeconds(t0, 60);
    check repo.upsert(check identity:recordSeen(first, {sub: id, email: id + "@wso2.com", name: "Renamed"}, t1));
    identity:Employee? second = check repo.findById(id);
    if first is () || second is () {
        test:assertFail("employee missing");
    }
    test:assertEquals(second.displayName, "Renamed");
    test:assertEquals(second.firstSeenAt, first.firstSeenAt);
    test:assertTrue(time:utcDiffSeconds(second.lastSeenAt, first.lastSeenAt) > 0d);
    test:assertEquals(check repo.findById("emp-none-" + uniq()), ());
    check db.close();
}
