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

// Repository integration tests against a migrated PostgreSQL 18 (group `integration`), run as the real
// app roles (`amplify_api`, `amplify_jobs`). Off unless `AMPLIFY_IT=true`; the amplify-database
// integration tests create and migrate the database first (docs/migrations/README.md).
// Ids are fresh UUIDv7s per run, so the tests can run again on the same database.

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.identity;
import amplify_domain.recognition;
import amplify_domain.scoring;
import amplify_domain.sharing;
import amplify_domain.store;

import ballerina/os;
import ballerina/sql;
import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

// Settings come from environment variables, not configurables: a configurable here would be "unused" in
// every other module's test run and fail it. Only test code reads the environment.
final boolean itEnabled = os:getEnv("AMPLIFY_IT") == "true";
final string dbHost = envOr("AMPLIFY_IT_DB_HOST", "localhost");
final int dbPort = checkpanic int:fromString(envOr("AMPLIFY_IT_DB_PORT", "5432"));
final string dbName = envOr("AMPLIFY_IT_DB_NAME", "amplify_it");
final string apiDbPassword = envOr("AMPLIFY_IT_API_PASSWORD", "it-api-password-00001");
final string jobsDbPassword = envOr("AMPLIFY_IT_JOBS_PASSWORD", "it-jobs-password-0001");
final postgresql:SSLMode dbSslMode = os:getEnv("AMPLIFY_IT_DB_SSL") == "require" ? postgresql:REQUIRE : postgresql:DISABLE;

function envOr(string name, string fallback) returns string {
    string value = os:getEnv(name);
    return value == "" ? fallback : value;
}

const string WSO2_ORG = "urn:li:organization:1337";

function connect(string user, string password) returns postgresql:Client|error =>
    store:newClient({host: dbHost, port: dbPort, database: dbName, user, password, sslMode: dbSslMode,
        maxOpenConnections: 3});

function api() returns postgresql:Client|error => connect("amplify_api", apiDbPassword);

function jobs() returns postgresql:Client|error => connect("amplify_jobs", jobsDbPassword);

function uniq() returns string => types:newUuidV7().substring(24);

function poActor(string id) returns store:Actor => {actorId: id, roles: ["amplify_po"], correlationId: "it-" + id};

function newEmployee(postgresql:Client db, string label) returns string|error {
    string id = "emp-" + label + "-" + uniq();
    identity:Employee e = check identity:recordSeen((), {sub: id, email: id + "@wso2.com", name: "Name " + label},
            time:utcNow());
    check (new identity:PgEmployeeRepository(db)).upsert(e);
    return id;
}

function count(postgresql:Client db, sql:ParameterizedQuery query) returns int|error {
    int n = check db->queryRow(query);
    return n;
}

function registerCampaign(postgresql:Client db, string actor) returns campaign:Campaign|error =>
    campaign:registerCampaign(new campaign:PgCampaignRepository(db, poActor(actor)), {
        resourceUrn: "urn:li:share:" + uniq(),
        ownerUrn: WSO2_ORG,
        title: "Integration campaign",
        categoryCode: "PRODUCT",
        tags: ["Ballerina", "it"],
        resourceUrl: "https://www.linkedin.com/feed/update/x"
    }, {wso2OrganizationUrn: WSO2_ORG}, actor, true, time:utcNow());

// ---- campaign ------------------------------------------------------------------------------------

// Token tables are partitioned by day and the migration only creates today..today+7, so on a later
// day token inserts need upkeep to have run first. Do it once up front so no test depends on order.
@test:BeforeSuite
function ensureTokenPartitions() returns error? {
    if !itEnabled {
        return;
    }
    postgresql:Client db = check jobs();
    store:MaintenanceResult _ = check store:runPartitionMaintenance(db);
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testCampaignRoundTripOutboxAndAudit() returns error? {
    postgresql:Client db = check api();
    string po = check newEmployee(db, "po");
    campaign:Campaign c = check registerCampaign(db, po);
    campaign:PgCampaignRepository repo = new (db, poActor(po));
    campaign:Campaign? stored = check repo.findById(c.id);
    if stored is () {
        test:assertFail("campaign not stored");
    }
    test:assertEquals(stored.tags, ["ballerina", "it"]);
    test:assertEquals(stored.resourceUrn, c.resourceUrn);
    test:assertEquals(time:utcDiffSeconds(stored.closesAt, stored.opensAt), 30d * 86400d, "C7 default window");

    string key = "CampaignRegistered:" + c.id;
    test:assertEquals(check count(db, `SELECT count(*)::int FROM messaging.outbox WHERE idempotency_key = ${key}`), 1);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit.audit_log
                                       WHERE entity_id = ${c.id} AND actor_id = ${po}`), 1);
    string status = check db->queryRow(`SELECT status FROM campaign.campaign_v WHERE id = CAST(${c.id} AS uuid)`);
    test:assertEquals(status, "OPEN");

    // Same resource again: the unique key maps to the domain code.
    campaign:Campaign|error again = campaign:registerCampaign(repo, {resourceUrn: c.resourceUrn, ownerUrn: WSO2_ORG,
        title: "Dup", categoryCode: "PRODUCT"}, {wso2OrganizationUrn: WSO2_ORG}, po, false, time:utcNow());
    assertCode(again, types:ERR_CAMPAIGN_ALREADY_REGISTERED);

    // Optimistic lock: a stale version is refused.
    campaign:Campaign edited = check campaign:updateCampaign(repo, c.id, 1, {title: "Edited", tags: ["x"]}, time:utcNow());
    test:assertEquals(edited.version, 2);
    error? stale = repo.update(edited, 1);
    assertCode(stale, types:ERR_VERSION_CONFLICT);

    campaign:Campaign archived = check campaign:archiveCampaign(repo, c.id, time:utcNow());
    status = check db->queryRow(`SELECT status FROM campaign.campaign_v WHERE id = CAST(${archived.id} AS uuid)`);
    test:assertEquals(status, "ARCHIVED");
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testFailedWriteRollsBackAggregateOutboxAndAudit() returns error? {
    postgresql:Client db = check api();
    string po = check newEmployee(db, "po");
    campaign:Campaign good = check campaign:newCampaign({resourceUrn: "urn:li:share:" + uniq(), ownerUrn: WSO2_ORG,
        title: "Rollback", categoryCode: "PRODUCT"}, {wso2OrganizationUrn: WSO2_ORG}, types:newUuidV7(), po, time:utcNow());
    // A tag that breaks the CHECK (must be lowercase) fails after the campaign row and before the outbox.
    campaign:Campaign bad = good.clone();
    bad.tags = ["NOT-LOWER"];
    error? result = (new campaign:PgCampaignRepository(db, poActor(po))).insert(bad,
            [campaign:campaignRegisteredEvent(bad, false)]);
    assertCheckViolation(result, "a tag that breaks the CHECK");
    test:assertEquals(check count(db, `SELECT count(*)::int FROM campaign.campaign WHERE id = CAST(${bad.id} AS uuid)`), 0);
    string key = "CampaignRegistered:" + bad.id;
    test:assertEquals(check count(db, `SELECT count(*)::int FROM messaging.outbox WHERE idempotency_key = ${key}`), 0);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit.audit_log WHERE entity_id = ${bad.id}`), 0);
    check db.close();
}

// ---- connection + token --------------------------------------------------------------------------

@test:Config {groups: ["integration"], enable: itEnabled}
function testConnectionWithEncryptedTokenAndReconnect() returns error? {
    postgresql:Client db = check api();
    byte[] key = [];
    foreach int i in 0 ..< 32 {
        key.push(<byte>(i + 3));
    }
    crypto:TokenCipher cipher = check new ([{keyId: "it-1", key}], "it-1");
    string emp = check newEmployee(db, "conn");
    connection:PgConnectionRepository repo = new (db, {actorId: emp});
    connection:PgTokenRepository tokens = new (db);
    time:Utc now = time:utcNow();

    connection:StoredToken first = check connection:sealToken(cipher, "plain-token-1", emp,
            time:utcAddSeconds(now, 5184000), now);
    check tokens.insert(first);
    string member = "urn:li:person:" + uniq();
    connection:LinkedInConnection c = check connection:completeConnection(repo, {employeeId: emp, memberUrn: member,
        scopes: ["openid", "w_member_social"], token: connection:tokenRef(first), expiresInSeconds: 5184000}, now);
    test:assertEquals(check connection:statusFromView(db, emp), connection:ACTIVE);

    connection:StoredToken? loaded = check tokens.find(connection:tokenRef(first));
    if loaded is () {
        test:assertFail("token row missing");
    }
    test:assertEquals(check connection:openToken(cipher, loaded), "plain-token-1");
    // A ciphertext moved onto another owner fails to decrypt.
    connection:StoredToken moved = loaded.clone();
    moved.ownerId = "someone-else";
    test:assertTrue(connection:openToken(cipher, moved) is error);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM connection.provider_token
                                       WHERE ciphertext = convert_to('plain-token-1', 'UTF8')`), 0, "never plaintext");

    // Reconnect: new token, old row deleted in the same transaction.
    connection:StoredToken second = check connection:sealToken(cipher, "plain-token-2", emp,
            time:utcAddSeconds(now, 5184000), time:utcNow());
    check tokens.insert(second);
    _ = check connection:completeConnection(repo, {employeeId: emp, memberUrn: member,
        scopes: ["openid", "w_member_social"], token: connection:tokenRef(second), expiresInSeconds: 5184000},
        time:utcNow());
    test:assertTrue(check tokens.find(connection:tokenRef(first)) is (), "old token deleted on reconnect");

    // One member, one employee (B13).
    string other = check newEmployee(db, "conn2");
    connection:LinkedInConnection|error taken = connection:completeConnection(repo, {employeeId: other,
        memberUrn: member, scopes: ["w_member_social"], token: connection:tokenRef(second), expiresInSeconds: 60}, now);
    assertCode(taken, types:ERR_MEMBER_ALREADY_LINKED);

    // Remove: token gone, status REMOVED, ConnectionRemoved queued.
    _ = check connection:removeConnection(repo, emp, time:utcNow());
    test:assertEquals(check connection:statusFromView(db, emp), connection:REMOVED);
    test:assertTrue(check tokens.find(connection:tokenRef(second)) is ());
    test:assertEquals(check count(db, `SELECT count(*)::int FROM messaging.outbox
                                       WHERE event_type = 'ConnectionRemoved' AND aggregate_id = ${emp}`), 1);
    test:assertEquals(c.version, 1);
    check db.close();
}

// ---- sharing -------------------------------------------------------------------------------------

@test:Config {groups: ["integration"], enable: itEnabled}
function testShareRequestRetryAndPublishByJobs() returns error? {
    postgresql:Client apiDb = check api();
    postgresql:Client jobsDb = check jobs();
    string po = check newEmployee(apiDb, "po");
    string emp = check newEmployee(apiDb, "share");
    campaign:Campaign c = check registerCampaign(apiDb, po);
    sharing:CampaignSnapshot snap = {id: c.id, provider: c.provider, resourceUrn: c.resourceUrn, open: true};
    sharing:ConnectionSnapshot conn = {memberUrn: "urn:li:person:" + uniq(), usable: true};
    sharing:PgShareRepository apiRepo = new (apiDb, {actorId: emp});

    sharing:ShareRequest req = check sharing:requestShare(apiRepo, snap, conn,
            {employeeId: emp, kind: types:REPOST_COMMENTARY, commentary: "Great release"}, time:utcNow());
    sharing:ShareRequest|error dup = sharing:requestShare(apiRepo, snap, conn, {employeeId: emp, kind: types:REPOST},
            time:utcNow());
    assertCode(dup, types:ERR_SHARE_ALREADY_QUEUED);
    // The insert path (the race `requestShare` reads first) reports the stored state too: a QUEUED row now,
    // a PUBLISHED one after the publish below, never a blanket "already queued".
    sharing:ShareRequest raced = check sharing:newShareRequest(snap, conn, {employeeId: emp, kind: types:REPOST},
            types:newUuidV7(), time:utcNow());
    assertCode(apiRepo.insert(raced, []), types:ERR_SHARE_ALREADY_QUEUED);

    // Jobs: fail, then the employee retries on the same row (ADR-015).
    sharing:PgShareRepository jobsRepo = new (jobsDb);
    sharing:ShareRequest failed = check sharing:markFailed(req, types:NEEDS_RECONNECT, (), time:utcNow());
    check jobsRepo.update(failed, req.version, [sharing:repostFailedEvent(failed)]);
    // Backdate the first request as if it were 40 days old: the row can only be in this week's tile 7
    // window because the retry below queued it again now, not because of `requested_at`.
    _ = check apiDb->execute(`UPDATE sharing.share_request SET requested_at = now() - interval '40 days'
                              WHERE id = CAST(${req.id} AS uuid)`);
    time:Utc weekAgo = time:utcAddSeconds(time:utcNow(), -7d * 86400d);
    sharing:ShareHealth beforeRetry = check sharing:shareHealth(apiDb, weekAgo);
    sharing:ShareRequest retried = check sharing:requestShare(apiRepo, snap, conn,
            {employeeId: emp, kind: types:REPOST}, time:utcNow());
    test:assertEquals(retried.id, req.id);
    test:assertEquals(retried.attempts, 2);
    test:assertEquals((check sharing:shareHealth(apiDb, weekAgo)).queued, beforeRetry.queued + 1,
            "tile 7 counts the retry when it happened, not the 40-day-old first request");

    // Jobs publishes: engagement + request + EngagementRecorded together; commentary cleared.
    sharing:PublishResult published = check sharing:markPublished(retried, "urn:li:share:" + uniq(), conn.memberUrn,
            types:newUuidV7(), time:utcNow());
    check jobsRepo.recordPublish(published, retried.version);
    string status = check jobsDb->queryRow(`SELECT status FROM sharing.share_request_v WHERE id = CAST(${req.id} AS uuid)`);
    test:assertEquals(status, "PUBLISHED");
    sharing:ShareRequest racedAfterPublish = check sharing:newShareRequest(snap, conn, {employeeId: emp, kind: types:REPOST},
            types:newUuidV7(), time:utcNow());
    assertCode(apiRepo.insert(racedAfterPublish, []), types:ERR_SHARE_ALREADY_PUBLISHED);
    test:assertEquals(check count(jobsDb, `SELECT count(*)::int FROM sharing.share_request
                                           WHERE id = CAST(${req.id} AS uuid) AND commentary IS NULL`), 1);
    string key = "EngagementRecorded:" + published.engagement.id;
    test:assertEquals(check count(jobsDb, `SELECT count(*)::int FROM messaging.outbox WHERE idempotency_key = ${key}`), 1);
    // Publishing twice is refused by the domain guard and the engagement keys.
    error? twice = jobsRepo.recordPublish(published, published.request.version);
    test:assertTrue(twice is error && store:isUniqueViolation(twice), "the engagement key refuses a second publish");
    test:assertEquals(check count(jobsDb, `SELECT count(*)::int FROM messaging.outbox WHERE idempotency_key = ${key}`), 1,
            "the refused second publish recorded nothing");
    check apiDb.close();
    check jobsDb.close();
}

// ---- external sharing ----------------------------------------------------------------------------

@test:Config {groups: ["integration"], enable: itEnabled}
function testExternalShareOneClaimPerUrlAndAmplifiedCheck() returns error? {
    postgresql:Client db = check api();
    string emp = check newEmployee(db, "claim");
    string other = check newEmployee(db, "claim2");
    string po = check newEmployee(db, "po");
    external_sharing:PgExternalShareRepository repo = new (db, poActor(po));
    string url = "https://Medium.com/@wso2/post-" + uniq() + "/?utm_source=x";
    external_sharing:ExternalShare claim = check external_sharing:submitExternalShare(repo,
            {employeeId: emp, evidenceUrl: url, certified: true}, time:utcNow());
    external_sharing:ExternalShare|error second = external_sharing:submitExternalShare(repo,
            {employeeId: other, evidenceUrl: url + "&utm_medium=y", certified: true}, time:utcNow());
    assertCode(second, types:ERR_EVIDENCE_ALREADY_CLAIMED);

    // DB backstop (C4): amplified before approval breaks the CHECK.
    sql:ExecutionResult|error early = db->execute(`UPDATE external_sharing.external_share SET amplified_at = now()
                                                   WHERE id = CAST(${claim.id} AS uuid)`);
    assertCheckViolation(early, "amplified before approval breaks the CHECK");

    external_sharing:ExternalShare approved = check external_sharing:approveExternalShare(repo, claim.id, po, time:utcNow());
    _ = check external_sharing:amplifyExternalShare(repo, approved.id, po, time:utcNow());
    string status = check db->queryRow(`SELECT status FROM external_sharing.external_share_v
                                        WHERE id = CAST(${claim.id} AS uuid)`);
    test:assertEquals(status, "AMPLIFIED");
    check db.close();
}

// ---- scoring + recognition -----------------------------------------------------------------------

@test:Config {groups: ["integration"], enable: itEnabled}
function testLedgerAppendUpdatesRecognitionInOneTransaction() returns error? {
    postgresql:Client jobsDb = check jobs();
    postgresql:Client apiDb = check api();
    string a = check newEmployee(apiDb, "rank-a");
    string b = check newEmployee(apiDb, "rank-b");
    string po = check newEmployee(apiDb, "po");
    scoring:PointRule[] rules = check (new scoring:PgPointRuleRepository(jobsDb)).all();
    test:assertEquals(rules.length(), 16, "seeded rules: S001, the five S005 pilot versions and the five S006 rules");
    scoring:PgLedgerRepository jobsLedger = new (jobsDb);
    string campaignId = types:newUuidV7();
    time:Utc now = time:utcNow();

    scoring:LedgerAppend award = check scoring:awardForEngagement(rules, {engagementId: types:newUuidV7(),
        provider: types:LINKEDIN, targetResourceUrn: "urn:li:share:" + uniq(), employeeId: a,
        action: types:REPOST_COMMENTARY, campaignId}, "run-1", now);
    test:assertTrue(check scoring:appendAward(jobsLedger, award));
    test:assertFalse(check scoring:appendAward(jobsLedger, award), "re-run is a no-op");
    scoring:LedgerAppend small = check scoring:awardForEngagement(rules, {engagementId: types:newUuidV7(),
        provider: types:LINKEDIN, targetResourceUrn: "urn:li:share:" + uniq(), employeeId: b, action: types:REPOST,
        campaignId}, "run-1", now);
    _ = check scoring:appendAward(jobsLedger, small);

    recognition:Standing? sa = check recognition:standingOf(jobsDb, a);
    recognition:Standing? sb = check recognition:standingOf(jobsDb, b);
    if sa is () || sb is () {
        test:assertFail("standings missing");
    }
    // Pilot values in force since 2026-10-19 (seed S005): repost with commentary 5, plain repost 2.
    test:assertEquals(sa.totalPoints, 5);
    test:assertEquals(sb.totalPoints, 2);
    test:assertTrue(sa.rank < sb.rank);
    // The next better total on the shared board (other tests leave standings behind, so it isn't
    // necessarily `a`'s).
    int nextBetter = check count(jobsDb, `SELECT min(total_points)::int FROM recognition.standing
                                          WHERE period_key = 'ALL' AND total_points > ${sb.totalPoints}`);
    test:assertEquals(sb.pointsToNextRank, nextBetter - sb.totalPoints);
    test:assertTrue(sb.pointsToNextRank <= sa.totalPoints - sb.totalPoints);
    int reposters = check count(jobsDb, `SELECT reposters FROM recognition.campaign_participation
                                         WHERE campaign_id = CAST(${campaignId} AS uuid)`);
    test:assertEquals(reposters, 2);

    // PO reversal through amplify_api updates recognition in its own transaction (B12).
    int versionBefore = check recognition:standingVersion(apiDb);
    scoring:PgLedgerRepository apiLedger = new (apiDb, poActor(po));
    types:LedgerEntry rev = check scoring:reverseEntry(apiLedger, award.entry.reference, "Deleted share", po, "req-1",
            time:utcNow());
    test:assertEquals(rev.points, -5);
    types:LedgerEntry|error again = scoring:reverseEntry(apiLedger, award.entry.reference, "Again", po, "req-2",
            time:utcNow());
    assertCode(again, types:ERR_ALREADY_REVERSED);
    // `append` tells an idempotent repeat from a real failure: a second reversal of the same row is stopped
    // by `points_ledger_reverses_uk` and comes back false, not as an error.
    types:LedgerEntry duplicateReversal = rev.clone();
    duplicateReversal.reference = check types:reversalReference(types:newUuidV7());
    test:assertFalse(check apiLedger.append({entry: duplicateReversal,
            event: scoring:pointsChangedEvent(duplicateReversal)}),
            "a second reversal of the same row is a no-op, not an error");
    recognition:Standing? afterRev = check recognition:standingOf(apiDb, a);
    test:assertEquals(afterRev is () ? -1 : afterRev.totalPoints, 0);
    test:assertTrue(check recognition:standingVersion(apiDb) > versionBefore, "standing_version bumped");
    reposters = check count(apiDb, `SELECT reposters FROM recognition.campaign_participation
                                    WHERE campaign_id = CAST(${campaignId} AS uuid)`);
    test:assertEquals(reposters, 1, "reversal takes the reposter back out");

    // Settlement columns only; facts and PAID are refused.
    check apiLedger.updateSettlement(small.entry.reference, (), time:utcNow());
    sql:ExecutionResult|error paid = apiDb->execute(`UPDATE scoring.points_ledger SET status = 'PAID', paid_at = now()
                                                    WHERE reference = ${small.entry.reference}`);
    test:assertTrue(paid is error, "no PAID in phase 1");
    sql:ExecutionResult|error facts = apiDb->execute(`UPDATE scoring.points_ledger SET points = 99
                                                     WHERE reference = ${small.entry.reference}`);
    test:assertTrue(facts is error, "points are immutable (column grants)");

    // A full rebuild from the ledger gives the same totals.
    _ = check recognition:rebuild(jobsDb);
    recognition:Standing? rebuilt = check recognition:standingOf(jobsDb, b);
    test:assertEquals(rebuilt is () ? -1 : rebuilt.totalPoints, 2);
    check apiDb.close();
    check jobsDb.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testPartitionMaintenanceAsJobs() returns error? {
    postgresql:Client db = check jobs();
    // The first run may create partitions (the migration only covered the day it ran); the second
    // run, right after, must be a no-op.
    store:MaintenanceResult _ = check store:runPartitionMaintenance(db);
    store:MaintenanceResult result = check store:runPartitionMaintenance(db);
    test:assertEquals(result.token_partitions_created, 0, "already 7 days ahead");
    postgresql:Client apiDb = check api();
    store:MaintenanceResult|error denied = store:runPartitionMaintenance(apiDb);
    test:assertTrue(denied is error, "only amplify_jobs runs upkeep");
    check db.close();
    check apiDb.close();
}

// A CHECK violation (SQLSTATE 23514) and nothing else: a dropped connection is an error too, and would pass a bare
// `is error`.
function assertCheckViolation(any|error result, string what) {
    if result is sql:DatabaseError {
        test:assertEquals(result.detail().sqlState, store:CHECK_VIOLATION, what);
        return;
    }
    test:assertFail(string `${what}: expected a CHECK violation, got ${result is error ? result.message() : "success"}`);
}

function assertCode(any|error result, string code) {
    if result is types:DomainError {
        test:assertEquals(result.detail().code, code);
        return;
    }
    if result is error {
        test:assertFail(string `expected ${code}, got ${result.message()}`);
    }
    test:assertFail(string `expected ${code}, got success`);
}

// ---- campaign: editing the post link and id ----------------------------------------------------------

@test:Config {groups: ["integration"], enable: itEnabled}
function testPatchPostIdAndLinkInPostgres() returns error? {
    postgresql:Client db = check api();
    string po = check newEmployee(db, "patchpo");
    campaign:PgCampaignRepository repo = new (db, poActor(po));
    time:Utc now = time:utcNow();

    // No activity: the id, type and link change, stored and audited, and the old id is free again.
    campaign:Campaign c = check registerCampaign(db, po);
    string oldUrn = c.resourceUrn;
    string newUrn = "urn:li:ugcPost:" + uniq();
    campaign:Campaign edited = check campaign:updateCampaign(repo, c.id, 1,
            {resourceUrn: newUrn, resourceUrl: "https://www.linkedin.com/feed/update/" + newUrn}, now);
    campaign:Campaign stored = <campaign:Campaign>(check repo.findById(c.id));
    test:assertEquals(stored.resourceUrn, newUrn);
    test:assertEquals(stored.resourceType, types:UGC_POST);
    test:assertEquals(stored.resourceUrl, "https://www.linkedin.com/feed/update/" + newUrn);
    test:assertEquals(stored.version, edited.version);
    test:assertEquals(check count(db, `SELECT count(*)::int FROM audit.audit_log
            WHERE entity_id = ${c.id} AND action = 'CampaignUpdated' AND before->>'resourceUrn' = ${oldUrn}
              AND after->>'resourceUrn' = ${newUrn}`), 1);
    test:assertEquals(check repo.hasActivity(c.id, newUrn), false);

    // A post id another campaign has: the registration conflict, not a 500, and nothing changed.
    campaign:Campaign other = check registerCampaign(db, po);
    campaign:Campaign|error clash = campaign:updateCampaign(repo, other.id, 1, {resourceUrn: newUrn}, now);
    assertCode(clash, types:ERR_CAMPAIGN_ALREADY_REGISTERED);
    // The same through the table's unique key, past the domain's pre-check (the race between two editors).
    campaign:Campaign raced = other.clone();
    raced.resourceUrn = newUrn;
    raced.version = 2;
    assertCode(repo.update(raced, 1), types:ERR_CAMPAIGN_ALREADY_REGISTERED);
    test:assertEquals((<campaign:Campaign>(check repo.findById(other.id))).resourceUrn, other.resourceUrn);
    test:assertEquals((<campaign:Campaign>(check repo.findById(other.id))).version, 1);
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testPatchPostIdFrozenByEachKindOfActivity() returns error? {
    postgresql:Client db = check api();
    string po = check newEmployee(db, "freezepo");
    campaign:PgCampaignRepository repo = new (db, poActor(po));
    time:Utc now = time:utcNow();

    // 1. share request (matched by campaign id)
    campaign:Campaign withShare = check registerCampaign(db, po);
    string emp = check newEmployee(db, "freezeshare");
    _ = check sharing:requestShare(new sharing:PgShareRepository(db, {actorId: emp}),
            {id: withShare.id, provider: withShare.provider, resourceUrn: withShare.resourceUrn, open: true},
            {memberUrn: "urn:li:person:" + uniq(), usable: true}, {employeeId: emp, kind: types:REPOST}, now);
    test:assertTrue(check repo.hasActivity(withShare.id, withShare.resourceUrn));
    assertCode(campaign:updateCampaign(repo, withShare.id, 1, {resourceUrn: "urn:li:share:" + uniq()}, now),
            types:ERR_POST_HAS_ACTIVITY);
    // the link alone still changes
    campaign:Campaign linkOnly = check campaign:updateCampaign(repo, withShare.id, 1,
            {resourceUrl: "https://www.linkedin.com/posts/wso2_it-" + uniq()}, now);
    test:assertEquals(linkOnly.resourceUrn, withShare.resourceUrn);

    // 2. engagement matched by the post id only (no campaign id on the row)
    campaign:Campaign withEngagement = check registerCampaign(db, po);
    string member = "urn:li:person:" + uniq();
    _ = check db->execute(`INSERT INTO sharing.engagement (provider, provider_api, origin, target_resource_urn,
            actor_member_urn, employee_id, action, occurred_at)
            VALUES ('linkedin', 'WEBHOOK', 'WEBHOOK', ${withEngagement.resourceUrn}, ${member}, ${emp}, 'REPOST', now())`);
    test:assertTrue(check repo.hasActivity(withEngagement.id, withEngagement.resourceUrn));
    assertCode(campaign:updateCampaign(repo, withEngagement.id, 1, {resourceUrn: "urn:li:share:" + uniq()}, now),
            types:ERR_POST_HAS_ACTIVITY);

    // 3. external share matched by the post id only
    campaign:Campaign withClaim = check registerCampaign(db, po);
    _ = check db->execute(`INSERT INTO external_sharing.external_share (employee_id, action, evidence_url,
            evidence_url_submitted, evidence_host, provider, resource_urn, certified_at)
            VALUES (${emp}, 'OWN_POST', ${"https://medium.com/@it/" + uniq()}, 'https://medium.com/@it/x', 'medium.com',
                    'linkedin', ${withClaim.resourceUrn}, now())`);
    test:assertTrue(check repo.hasActivity(withClaim.id, withClaim.resourceUrn));
    assertCode(campaign:updateCampaign(repo, withClaim.id, 1, {resourceUrn: "urn:li:share:" + uniq()}, now),
            types:ERR_POST_HAS_ACTIVITY);

    // 4. a points adjustment that names the campaign (nothing matches by post id, only by the campaign id)
    campaign:Campaign withPoints = check registerCampaign(db, po);
    scoring:PgLedgerRepository pointsRepo = new (db, poActor(po), 3);
    _ = check scoring:adjustPoints(pointsRepo, emp, 10, "IT adjustment for a post", po, withPoints.id,
            "it-adj-" + uniq(), time:utcNow());
    test:assertTrue(check repo.hasActivity(withPoints.id, withPoints.resourceUrn));
    assertCode(campaign:updateCampaign(repo, withPoints.id, 1, {resourceUrn: "urn:li:share:" + uniq()}, now),
            types:ERR_POST_HAS_ACTIVITY);

    // The transaction re-checks: activity that lands after the caller's check still stops the change.
    campaign:Campaign late = check registerCampaign(db, po);
    campaign:Campaign wantsNew = late.clone();
    wantsNew.resourceUrn = "urn:li:share:" + uniq();
    wantsNew.version = 2;
    _ = check db->execute(`INSERT INTO sharing.engagement (provider, provider_api, origin, target_resource_urn,
            actor_member_urn, employee_id, action, occurred_at)
            VALUES ('linkedin', 'WEBHOOK', 'WEBHOOK', ${late.resourceUrn}, ${member}, ${emp}, 'SHARE', now())`);
    assertCode(repo.update(wantsNew, 1), types:ERR_POST_HAS_ACTIVITY);
    test:assertEquals((<campaign:Campaign>(check repo.findById(late.id))).resourceUrn, late.resourceUrn);

    // A campaign with nothing recorded is free to change.
    campaign:Campaign quiet = check registerCampaign(db, po);
    test:assertFalse(check repo.hasActivity(quiet.id, quiet.resourceUrn));
}
