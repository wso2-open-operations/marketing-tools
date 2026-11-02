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


// Round 2 regression tests (2026-10-17, group `integration`, `AMPLIFY_IT=true`): the token row written in
// the connection's transaction (api H3), key rotation over real rows (common H4 / domain H-2 / jobs H2), a
// duplicate publish settling (domain H-5), the idempotency claim race (api H2) and the R-13 transaction gate
// under 48 parallel writes (item 12).

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.identity;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/io;
import ballerina/sql;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

final string adminDbPassword = envOr("AMPLIFY_IT_ADMIN_PASSWORD", "postgres");

function admin() returns postgresql:Client|error => connect(envOr("AMPLIFY_IT_ADMIN_USER", "postgres"), adminDbPassword);

function keyBytes(int seed) returns byte[] {
    byte[] k = [];
    foreach int i in 0 ..< 32 {
        k.push(<byte>((i * 3 + seed) % 256));
    }
    return k;
}

function tokenRows(postgresql:Client db, string tokenId) returns int|error =>
    count(db, `SELECT count(*)::int FROM connection.provider_token WHERE token_id = CAST(${tokenId} AS uuid)`);

// api H3: the sealed token goes in with the connection change. A connection write that fails (a stale
// version, as when two tabs finish the OAuth flow at once) rolls the token row back with it.
@test:Config {groups: ["integration"], enable: itEnabled}
function testConnectionWriteFailureLeavesNoTokenRow() returns error? {
    postgresql:Client db = check api();
    crypto:TokenCipher cipher = check new ([{keyId: "r2-a", key: keyBytes(1)}], "r2-a");
    string emp = check newEmployee(db, "tokatomic");
    string member = "urn:li:person:" + uniq();
    connection:PgConnectionRepository repo = new (db, {actorId: emp});
    time:Utc now = time:utcNow();

    connection:StoredToken first = check connection:sealToken(cipher, "bearer-first", emp, time:utcAddSeconds(now, 3600), now);
    connection:LinkedInConnection c = check connection:completeConnection(repo, {employeeId: emp, memberUrn: member,
        scopes: ["openid", "w_member_social"], token: connection:tokenRef(first), expiresInSeconds: 3600}, now, first);
    test:assertEquals(check tokenRows(db, first.tokenId), 1, "inserted by the connection save");
    test:assertEquals(c.currentToken, connection:tokenRef(first));

    // Reconnect computed from a stale read: the UPDATE matches no row, the transaction fails, no token row.
    connection:StoredToken second = check connection:sealToken(cipher, "bearer-second", emp, time:utcAddSeconds(now, 3600), now);
    connection:ConnectionChange change = check connection:connect(c, {employeeId: emp, memberUrn: member,
        scopes: ["openid", "w_member_social"], token: connection:tokenRef(second), expiresInSeconds: 3600}, now);
    change.tokenToInsert = second;
    error? stale = repo.save(change, c.version + 5);
    assertCode(stale, types:ERR_VERSION_CONFLICT);
    test:assertEquals(check tokenRows(db, second.tokenId), 0, "the failed connection write left no token row");
    test:assertEquals(check tokenRows(db, first.tokenId), 1, "and didn't delete the current one");

    // Another employee claiming the same member hits member_connection_member_uk inside the save.
    string other = check newEmployee(db, "tokatomic2");
    connection:StoredToken third = check connection:sealToken(cipher, "bearer-third", other, time:utcAddSeconds(now, 3600), now);
    connection:ConnectionChange taken = check connection:connect((), {employeeId: other, memberUrn: member,
        scopes: ["w_member_social"], token: connection:tokenRef(third), expiresInSeconds: 3600}, now);
    taken.tokenToInsert = third;
    assertCode(repo.save(taken, ()), types:ERR_MEMBER_ALREADY_LINKED);
    test:assertEquals(check tokenRows(db, third.tokenId), 0, "unique violation: no orphan token row");
    check db.close();
}

// common H4 / domain H-2 / jobs H2: two keys. Rows sealed under the old key move to the new one in place,
// open with the ring, and no longer open with the old key alone; a second pass is a no-op.
@test:Config {groups: ["integration"], enable: itEnabled}
function testResealStaleTokensAgainstTheDatabase() returns error? {
    postgresql:Client db = check jobs();
    string oldId = "r2-old-" + uniq();
    string newId = "r2-new-" + uniq();
    crypto:TokenCipher oldCipher = check new ([{keyId: oldId, key: keyBytes(5)}], oldId);
    crypto:TokenCipher ring = check new ([{keyId: oldId, key: keyBytes(5)}, {keyId: newId, key: keyBytes(77)}], newId);
    connection:PgTokenRepository tokens = new (db);
    // Only a sign-in creates a token row, so the fixtures go in through the API role: amplify_jobs has no INSERT.
    postgresql:Client seedDb = check api();
    connection:PgTokenRepository seeder = new (seedDb);
    time:Utc now = time:utcNow();
    connection:StoredToken[] mine = [];
    foreach int i in 0 ..< 3 {
        connection:StoredToken t = check connection:sealToken(oldCipher, string `bearer-rot-${i}`,
                "emp-rot-" + uniq(), time:utcAddSeconds(now, 3600), now);
        check seeder.insert(t);
        mine.push(t);
    }
    check seedDb.close();
    connection:ResealReport report = check connection:resealStaleTokens(ring, tokens, batchSize = 2);
    test:assertTrue(report.resealed >= 3, string `re-sealed ${report.resealed}`);
    foreach int i in 0 ..< mine.length() {
        connection:StoredToken? row = check tokens.find(connection:tokenRef(mine[i]));
        if row is () {
            test:assertFail("row gone");
        }
        test:assertEquals(row.keyId, newId);
        test:assertEquals(check connection:openToken(ring, row), string `bearer-rot-${i}`);
        test:assertTrue(connection:openToken(oldCipher, row) is error, "the old key alone can't read it");
    }
    int left = check count(db, `SELECT count(*)::int FROM connection.provider_token WHERE key_id = ${oldId}`);
    test:assertEquals(left, 0, "nothing left on the old key");
    connection:ResealReport again = check connection:resealStaleTokens(ring, tokens);
    test:assertEquals(again.resealed, 0, "second pass re-seals nothing");
    check db.close();
}

// domain H-5: the engagement unique key fires on publish (this employee already has an engagement for the
// target); the request settles as PUBLISHED on the existing engagement instead of staying QUEUED, and no
// second EngagementRecorded is written.
@test:Config {groups: ["integration"], enable: itEnabled}
function testDuplicatePublishSettlesTheShare() returns error? {
    postgresql:Client apiDb = check api();
    postgresql:Client jobsDb = check jobs();
    string po = check newEmployee(apiDb, "duppo");
    string emp = check newEmployee(apiDb, "dup");
    campaign:Campaign c = check registerCampaign(apiDb, po);
    sharing:ConnectionSnapshot conn = {memberUrn: "urn:li:person:" + uniq(), usable: true};
    sharing:PgShareRepository apiRepo = new (apiDb, {actorId: emp});
    sharing:PgShareRepository jobsRepo = new (jobsDb);

    sharing:ShareRequest first = check sharing:requestShare(apiRepo,
            {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn, open: true}, conn,
            {employeeId: emp, kind: types:REPOST}, time:utcNow());
    sharing:PublishResult one = check sharing:markPublished(first, "urn:li:share:" + uniq(), conn.memberUrn,
            types:newUuidV7(), time:utcNow());
    check jobsRepo.recordPublish(one, first.version);

    // A second request on another campaign row pointing at the same post (same target, employee, action).
    string otherCampaign = types:newUuidV7();
    sharing:ShareRequest second = check sharing:requestShare(apiRepo,
            {id: otherCampaign, provider: c.provider, resourceUrn: c.resourceUrn, open: true}, conn,
            {employeeId: emp, kind: types:REPOST}, time:utcNow());
    sharing:PublishResult two = check sharing:markPublished(second, "urn:li:share:" + uniq(), conn.memberUrn,
            types:newUuidV7(), time:utcNow());
    error? clash = jobsRepo.recordPublish(two, second.version);
    test:assertTrue(clash is error && store:isUniqueViolation(clash), "the engagement unique key fires");
    test:assertTrue(check jobsRepo.recordDuplicatePublish(two, second.version));

    sharing:ShareRequest? settled = check jobsRepo.findByCampaignAndEmployee(otherCampaign, emp);
    if settled is () {
        test:assertFail("request gone");
    }
    test:assertEquals(sharing:shareStatus(settled), sharing:PUBLISHED, "no longer stuck QUEUED");
    test:assertEquals(settled.engagementId, one.engagement.id, "linked to the engagement that already exists");
    string key = "EngagementRecorded:" + two.engagement.id;
    test:assertEquals(check count(jobsDb, `SELECT count(*)::int FROM messaging.outbox WHERE idempotency_key = ${key}`), 0,
            "no second EngagementRecorded, so nothing is scored twice");
    int engagements = check count(jobsDb, `SELECT count(*)::int FROM sharing.engagement
                                            WHERE employee_id = ${emp} AND target_resource_urn = ${c.resourceUrn}`);
    test:assertEquals(engagements, 1);
    check apiDb.close();
    check jobsDb.close();
}

// api H2: the insert loses to a holder (0 rows) and the holder's row is gone before the read (its request
// failed and released the key). The claim retries the insert once and wins instead of answering NoRows
// (a 503). The window is forced with a statement trigger that deletes the holder's row right after the
// conflicting INSERT, once.
@test:Config {groups: ["integration"], enable: itEnabled}
function testIdempotencyClaimRetriesWhenTheHolderVanishes() returns error? {
    postgresql:Client su = check admin();
    postgresql:Client db = check api();
    string emp = "emp-race-" + uniq();
    time:Utc now = time:utcNow();
    check ddl(su, "CREATE TABLE IF NOT EXISTS public.it_claim_race (employee_id text PRIMARY KEY)");
    check ddl(su, string `
        CREATE OR REPLACE FUNCTION public.it_claim_race_fire() RETURNS trigger LANGUAGE plpgsql
        SECURITY DEFINER SET search_path = pg_catalog AS $fn$
        BEGIN
            DELETE FROM messaging.idempotency_key k USING public.it_claim_race r WHERE k.employee_id = r.employee_id;
            DELETE FROM public.it_claim_race;
            RETURN NULL;
        END $fn$`);
    check ddl(su, "DROP TRIGGER IF EXISTS it_claim_race_trg ON messaging.idempotency_key");
    do {
        // The holder's row exists before the claim.
        _ = check su->execute(`INSERT INTO messaging.idempotency_key (employee_id, key, request_hash, created_at, expires_at)
                               VALUES (${emp}, 'k-race', 'holder', now(), now() + interval '1 day')`);
        _ = check su->execute(`INSERT INTO public.it_claim_race (employee_id) VALUES (${emp})`);
        check ddl(su, string `CREATE TRIGGER it_claim_race_trg AFTER INSERT ON messaging.idempotency_key
                              FOR EACH STATEMENT EXECUTE FUNCTION public.it_claim_race_fire()`);
        store:IdempotencyRecord? claimed = check store:claimIdempotencyKey(db, emp, "k-race", "mine", 86400, now);
        test:assertEquals(claimed, (), "the claim retried and won the freed key");
        string hash = check db->queryRow(`SELECT request_hash FROM messaging.idempotency_key
                                          WHERE employee_id = ${emp} AND key = 'k-race'`);
        test:assertEquals(hash, "mine");
    } on fail error e {
        check ddl(su, "DROP TRIGGER IF EXISTS it_claim_race_trg ON messaging.idempotency_key");
        return e;
    }
    check ddl(su, "DROP TRIGGER IF EXISTS it_claim_race_trg ON messaging.idempotency_key");
    check su.close();
    check db.close();
}

function ddl(postgresql:Client db, string text) returns error? {
    sql:ParameterizedCallQuery q = ``;
    q.strings = [text];
    sql:ProcedureCallResult r = check db->call(q);
    check r.close();
}

// Item 12 (R-13): 48 parallel PO adjustments per round, 5 rounds, through the product path
// (`scoring:adjustPoints` -> `PgLedgerRepository.append` -> `store:inTransaction`). Every reported success
// must be committed, nothing may fail, and no session may be left idle in a transaction (a lost commit or
// a leaked pool connection). Without the gate this loses commits and leaks connections on 2201.13.3.
@test:Config {groups: ["integration"], enable: itEnabled}
function testGatedParallelWritesAllCommit() returns error? {
    postgresql:Client db = check store:newClient({host: dbHost, port: dbPort, database: dbName, user: "amplify_api",
        password: apiDbPassword, sslMode: dbSslMode, maxOpenConnections: 12, poolAcquireTimeoutSeconds: 10});
    string marker = "IT gate " + uniq();
    string[] emps = [];
    foreach int i in 0 ..< 8 {
        emps.push(check newEmployee(db, "gate" + i.toString()));
    }
    // One sequential write first: the very first parallel strands can hit a separate, non-SQL runtime race
    // while the runtime lazily initialises (a ConcurrentModificationException in pure code such as
    // `types:adjustmentReference`, seen before any transaction starts). That isn't what this test is about.
    check adjustWith(db, emps[0], 1, marker + " warm-up");
    int gatedBefore = store:gatedTransactions();
    int successes = 0;
    string firstError = "";
    int failures = 0;
    foreach int round in 0 ..< 5 {
        future<error?>[] running = [];
        foreach int i in 0 ..< 48 {
            future<error?> f = start adjustWith(db, emps[i % emps.length()], i + 1, marker);
            running.push(f);
        }
        foreach future<error?> f in running {
            error? result = waitFor(f);
            if result is error {
                failures += 1;
                firstError = firstError == "" ? result.message() : firstError;
            } else {
                successes += 1;
            }
        }
    }
    int committed = check count(db, `SELECT count(*)::int FROM scoring.points_ledger WHERE reason = ${marker}`);
    int idle = check count(db, `SELECT count(*)::int FROM pg_stat_activity
                                WHERE usename = current_user AND state LIKE 'idle in transaction%'`);
    io:println(string `R-13 gate: ${successes} successes, ${committed} committed, ${failures} failed, ${idle} idle in transaction`);
    test:assertEquals(failures, 0, "no parallel write failed: " + firstError);
    test:assertEquals(committed, successes, "every reported success is committed");
    test:assertEquals(successes, 240);
    test:assertEquals(idle, 0, "no session left idle in a transaction (lost commit or leaked connection)");
    test:assertTrue(store:gatedTransactions() - gatedBefore >= 240, "every write went through the gate");
    check db.close();
}

isolated function adjustWith(postgresql:Client db, string emp, int points, string reason) returns error? {
    scoring:PgLedgerRepository ledger = new (db, {actorId: "it-po-gate", roles: ["amplify_po"]}, 3);
    _ = check scoring:adjustPoints(ledger, emp, points, reason, "it-po-gate", (), (), time:utcNow());
}

// Outbox backlog (security review): pending, in-progress and failed rows are counted and the oldest pending row's age
// is measured from `created_at`, so a deferred row that keeps being retried still reads as old.
@test:Config {groups: ["integration"], enable: itEnabled}
function testOutboxBacklogCountsWhatIsWaiting() returns error? {
    postgresql:Client db = check jobs();
    store:OutboxBacklog before = check store:outboxBacklog(db);
    string tag = "backlog-" + uniq();
    foreach [string, string, string] [suffix, status, age] in [["a", "PENDING", "3 hours"], ["b", "PENDING", "1 minute"],
            ["c", "IN_PROGRESS", "1 minute"], ["d", "FAILED", "1 minute"]] {
        _ = check db->execute(`INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload,
                idempotency_key, status, created_at, next_attempt_at)
            VALUES ('t', ${tag}, 'T', '{}'::jsonb, ${"it:" + tag + suffix}, ${status}, now() - CAST(${age} AS interval),
                now() + interval '1 day')`);
    }
    _ = check db->execute(`INSERT INTO messaging.outbox (aggregate_type, aggregate_id, event_type, payload,
            idempotency_key, status, processed_at) VALUES ('t', ${tag}, 'T', '{}'::jsonb, ${"it:" + tag + "e"},
            'DONE', now())`);
    store:OutboxBacklog after = check store:outboxBacklog(db);
    test:assertEquals(after.pending - before.pending, 2, "two pending, the deferred one included");
    test:assertEquals(after.inProgress - before.inProgress, 1);
    test:assertEquals(after.failed - before.failed, 1);
    int oldest = after.oldestPendingSeconds ?: -1;
    test:assertTrue(oldest >= 3 * 3600 - 5, string `oldest pending is ${oldest}s, at least the 3 hour row`);
    // DONE rows are not part of the backlog.
    test:assertEquals(after.pending + after.inProgress + after.failed,
            before.pending + before.inProgress + before.failed + 4);
    check db.close();
}

// Leavers (security review): not in the directory AND away from Amplify for the grace period; erasing one is audited
// and takes the person off the candidate list.
@test:Config {groups: ["integration"], enable: itEnabled}
function testLeaverCandidatesNeedBothAbsenceAndDormancyAndErasureRemovesThem() returns error? {
    postgresql:Client apiDb = check api();
    postgresql:Client jobsDb = check jobs();
    string tag = "lv" + uniq();
    string[] ids = [tag + "-listed", tag + "-gone", tag + "-gone-recent"];
    foreach [string, string] [id, age] in [[ids[0], "90 days"], [ids[1], "90 days"], [ids[2], "2 days"]] {
        _ = check apiDb->execute(`INSERT INTO identity.employee (employee_id, email, display_name, first_seen_at, last_seen_at)
            VALUES (${id}, ${id + "@example.com"}, ${"Name " + id}, now() - interval '100 days',
                    now() - CAST(${age} AS interval))`);
    }
    string[] directory = [ids[0] + "@example.com"];
    string[] found = check identity:leaverCandidates(jobsDb, directory, 30, 1000);
    test:assertTrue(found.indexOf(ids[1]) !is (), "gone and dormant is a candidate");
    test:assertTrue(found.indexOf(ids[0]) is (), "listed in the directory is never a candidate, however dormant");
    test:assertTrue(found.indexOf(ids[2]) is (), "gone but active two days ago waits out the grace period");
    // The directory is compared case-insensitively.
    string[] upper = [(ids[0] + "@example.com").toUpperAscii(), ids[1] + "@example.com"];
    string[] foundUpper = check identity:leaverCandidates(jobsDb, upper, 30, 1000);
    test:assertTrue(foundUpper.indexOf(ids[0]) is () && foundUpper.indexOf(ids[1]) is ());

    json erased = check identity:eraseEmployee(jobsDb, ids[1], "system", "LEAVER_SWEEP");
    test:assertTrue(erased.toJsonString().includes("\"employee\":1") || erased.toJsonString().includes("\"employee\": 1"),
            erased.toJsonString());
    string[] after = check identity:leaverCandidates(jobsDb, directory, 30, 1000);
    test:assertTrue(after.indexOf(ids[1]) is (), "an erased person is not found again");
    int audited = check count(jobsDb, `SELECT count(*)::int FROM audit.audit_log
        WHERE entity_id = ${ids[1]} AND action = 'EMPLOYEE_DATA_ERASED' AND reason = 'LEAVER_SWEEP'`);
    test:assertEquals(audited, 1);
    check apiDb.close();
    check jobsDb.close();
}

// Token partition runway (review of V009): the migration creates two weeks ahead, and the days-ahead read is what
// amplify-jobs exports and alerts on.
@test:Config {groups: ["integration"], enable: itEnabled}
function testTokenPartitionRunwayIsTwoWeeksAndReadable() returns error? {
    postgresql:Client db = check jobs();
    int? ahead = check store:tokenPartitionDaysAhead(db);
    int days = ahead ?: -99;
    // 14 on the day the database was built; allow a day for a UTC rollover while the suite runs.
    test:assertTrue(days >= 13, string `newest token partition is ${days} days ahead`);
    // Creating more moves the runway out; creating fewer never shrinks it.
    _ = check db->queryRow(`SELECT connection.create_token_partitions(20)`, int);
    int? longer = check store:tokenPartitionDaysAhead(db);
    test:assertTrue((longer ?: -99) >= 20, "asking for 20 days creates 20 days");
    _ = check db->queryRow(`SELECT connection.create_token_partitions(2)`, int);
    test:assertEquals(check store:tokenPartitionDaysAhead(db), longer, "a shorter request does not drop partitions");
    check db.close();
}
