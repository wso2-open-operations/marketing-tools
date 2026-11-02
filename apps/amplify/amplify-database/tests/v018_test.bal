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

// V017 and V018: the narrowed token grants, and the one audited erase function (security review). The erase test
// seeds two people with data in every place personal data lives, erases one and checks the other is untouched.

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

isolated function seedEmployee(postgresql:Client db, string id) returns error? {
    _ = check db->execute(`INSERT INTO identity.employee (employee_id, email, display_name)
        VALUES (${id}, ${id + "@example.com"}, ${"Name of " + id})`);
    _ = check db->execute(`INSERT INTO recognition.standing (period_key, employee_id, display_name, email, total_points)
        VALUES ('ALL', ${id}, ${"Name of " + id}, ${id + "@example.com"}, 10)`);
    _ = check db->execute(`INSERT INTO connection.member_connection (employee_id, provider, member_urn, provider_api,
            access_expires_at, connected_at)
        VALUES (${id}, 'linkedin', ${"urn:li:person:" + id}, 'SHARE_ON_LINKEDIN', now() + interval '30 days', now())`);
    _ = check db->execute(`INSERT INTO connection.provider_token (owner_type, owner_id, provider, token_kind, ciphertext,
            nonce, key_id, expires_at)
        VALUES ('MEMBER', ${id}, 'linkedin', 'ACCESS', decode('00ff', 'hex'), decode('000000000000000000000000', 'hex'),
            'k1', now() + interval '1 day')`);
    _ = check db->execute(`INSERT INTO connection.oauth_state (state, employee_id, provider, provider_api, nonce, expires_at)
        VALUES (${id + "-state-0123456789abcdef0123456789"}, ${id}, 'linkedin', 'SHARE_ON_LINKEDIN', 'n',
            now() + interval '10 minutes')`);
    _ = check db->execute(`INSERT INTO connection.linkedin_consent (employee_id, decision, profile_url)
        VALUES (${id}, 'DECLINED', ${"https://www.linkedin.com/in/" + id})`);
    _ = check db->execute(`INSERT INTO messaging.idempotency_key (employee_id, key, request_hash, expires_at)
        VALUES (${id}, 'k', 'h', now() + interval '1 day')`);
    _ = check db->execute(`INSERT INTO sharing.engagement (provider, provider_api, origin, target_resource_urn,
            actor_member_urn, employee_id, action, activity_urn, occurred_at)
        VALUES ('linkedin', 'SHARE_ON_LINKEDIN', 'IN_APP', 'urn:li:share:1', ${"urn:li:person:" + id}, ${id}, 'REPOST',
            ${"urn:li:activity:" + id}, now())`);
    _ = check db->execute(`INSERT INTO sharing.share_request (campaign_id, employee_id, provider, provider_api,
            target_resource_urn, kind, commentary)
        VALUES (gen_random_uuid(), ${id}, 'linkedin', 'SHARE_ON_LINKEDIN', 'urn:li:share:1', 'REPOST_COMMENTARY',
            'my own words')`);
}

isolated function remaining(postgresql:Client db, string id) returns int|error {
    int total = check db->queryRow(`
    SELECT ((SELECT count(*) FROM connection.provider_token WHERE owner_id = ${id})
         + (SELECT count(*) FROM connection.member_connection WHERE employee_id = ${id})
         + (SELECT count(*) FROM connection.oauth_state WHERE employee_id = ${id})
         + (SELECT count(*) FROM connection.linkedin_consent WHERE employee_id = ${id})
         + (SELECT count(*) FROM messaging.idempotency_key WHERE employee_id = ${id})
         + (SELECT count(*) FROM sharing.share_request WHERE employee_id = ${id} AND commentary IS NOT NULL)
         + (SELECT count(*) FROM sharing.engagement WHERE employee_id = ${id} AND actor_member_urn LIKE 'urn:li:person:%'
                                                      AND actor_member_urn <> 'urn:li:person:erased'))::int`);
    return total;
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testEraseEmployeeRemovesPersonalDataAndKeepsTheLedger() returns error? {
    postgresql:Client admin = check adminClient(itDbName);
    postgresql:Client jobs = check jobsClient();
    postgresql:Client api = check apiClient();
    check seedEmployee(admin, "erase-gone");
    check seedEmployee(admin, "erase-stays");
    test:assertEquals(check remaining(admin, "erase-gone"), 7, "seeded: one row in each place personal data lives");

    // The worker may erase; the API may not.
    sql:ExecutionResult|sql:Error byApi = api->execute(`SELECT identity.erase_employee('erase-stays', 'api', 'no')`);
    test:assertTrue(byApi is error, "amplify_api cannot call the erase function");
    test:assertEquals(check remaining(admin, "erase-stays"), 7, "and nothing changed");

    string result = check jobs->queryRow(`SELECT identity.erase_employee('erase-gone', 'system', 'leaver sweep')::text`);
    test:assertTrue(result.includes("\"tokens\": 1") && result.includes("\"connections\": 1")
        && result.includes("\"consents\": 1") && result.includes("\"engagements\": 1"), result);

    test:assertEquals(check remaining(admin, "erase-gone"), 0, "no token, URN, profile URL, commentary or key is left");
    string email = check admin->queryRow(`SELECT email::text FROM identity.employee WHERE employee_id = 'erase-gone'`);
    test:assertTrue(email.startsWith("erased-") && email.endsWith("@amplify.invalid"), email);
    string name = check admin->queryRow(`SELECT display_name FROM identity.employee WHERE employee_id = 'erase-gone'`);
    test:assertEquals(name, "Former participant");
    int namedStandings = check admin->queryRow(`SELECT count(*)::int FROM recognition.standing
        WHERE employee_id = 'erase-gone' AND (email IS NOT NULL OR display_name <> 'Former participant')`);
    test:assertEquals(namedStandings, 0);
    // The pseudonymous record stays: the standing row (points) and one audit row for the erase.
    int points = check admin->queryRow(`SELECT total_points FROM recognition.standing WHERE employee_id = 'erase-gone'`);
    test:assertEquals(points, 10, "points stay, so the leaderboard arithmetic holds");
    int audited = check admin->queryRow(`SELECT count(*)::int FROM audit.audit_log
        WHERE entity_id = 'erase-gone' AND action = 'EMPLOYEE_DATA_ERASED' AND actor_id = 'system'
          AND reason = 'leaver sweep'`);
    test:assertEquals(audited, 1);
    // The database user that really called it is recorded next to the actor the caller named.
    string calledBy = check admin->queryRow(`SELECT after->>'calledBy' FROM audit.audit_log
        WHERE entity_id = 'erase-gone' AND action = 'EMPLOYEE_DATA_ERASED' AND reason = 'leaver sweep'`);
    test:assertEquals(calledBy, "amplify_jobs");
    // Someone else is untouched.
    test:assertEquals(check remaining(admin, "erase-stays"), 7, "another employee keeps everything");
    string keptEmail = check admin->queryRow(`SELECT email::text FROM identity.employee WHERE employee_id = 'erase-stays'`);
    test:assertEquals(keptEmail, "erase-stays@example.com");

    // A second erase changes nothing and says so.
    string again = check jobs->queryRow(`SELECT identity.erase_employee('erase-gone', 'system', 'again')::text`);
    test:assertTrue(again.includes("\"tokens\": 0") && again.includes("\"employee\": 0")
        && again.includes("\"standings\": 0"), again);
    sql:ExecutionResult|sql:Error blank = jobs->execute(`SELECT identity.erase_employee('', 'system', 'x')`);
    test:assertTrue(blank is error, "an empty employee id is refused");

    check api.close();
    check jobs.close();
    check admin.close();
}

@test:Config {groups: ["integration"], dependsOn: [testFreshRunThenIdempotentRerun], enable: itEnabled}
function testTokenGrantsAreNarrowedPerComponent() returns error? {
    postgresql:Client jobs = check jobsClient();
    postgresql:Client api = check apiClient();
    // Privileges are checked before any row is touched, so these fail even with WHERE false.
    sql:ExecutionResult|sql:Error apiUpdate = api->execute(`UPDATE connection.provider_token SET key_id = key_id WHERE false`);
    test:assertTrue(apiUpdate is error, "amplify_api no longer rewrites token rows");
    sql:ExecutionResult|sql:Error jobsInsert = jobs->execute(`INSERT INTO connection.provider_token (owner_type, owner_id,
            provider, token_kind, ciphertext, nonce, key_id, expires_at)
        SELECT 'MEMBER', 'x', 'linkedin', 'ACCESS', ''::bytea, decode('000000000000000000000000', 'hex'), 'k', now() WHERE false`);
    test:assertTrue(jobsInsert is error, "amplify_jobs no longer creates token rows");
    // What each still needs.
    int _ = check api->queryRow(`SELECT count(*)::int FROM connection.provider_token`);
    int _ = check jobs->queryRow(`SELECT count(*)::int FROM connection.provider_token`);
    sql:ExecutionResult|sql:Error apiDelete = api->execute(`DELETE FROM connection.provider_token WHERE false`);
    test:assertFalse(apiDelete is error, "amplify_api still removes a connection's token");
    sql:ExecutionResult|sql:Error jobsUpdate = jobs->execute(`UPDATE connection.provider_token SET key_id = key_id WHERE false`);
    test:assertFalse(jobsUpdate is error, "amplify_jobs still re-seals tokens");
    check api.close();
    check jobs.close();
}
