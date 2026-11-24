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

// LinkedIn mentions and re-link (group `integration`, `AMPLIFY_IT=true`): a removed connection no longer holds
// its member URN, a revoke deletes the token row, the mention read models, and the queued shares a lost
// connection fails.

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.sharing;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

function linkMember(postgresql:Client db, crypto:TokenCipher cipher, string emp, string member, string? name = ())
        returns connection:LinkedInConnection|error {
    time:Utc now = time:utcNow();
    connection:StoredToken token = check connection:sealToken(cipher, "bearer-" + emp, emp, time:utcAddSeconds(now, 3600), now);
    return connection:completeConnection(new connection:PgConnectionRepository(db, {actorId: emp}), {employeeId: emp,
        memberUrn: member, scopes: ["openid", "w_member_social"], token: connection:tokenRef(token),
        expiresInSeconds: 3600, memberName: name}, now, token);
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testRemovedConnectionReleasesTheMember() returns error? {
    postgresql:Client db = check api();
    crypto:TokenCipher cipher = check new ([{keyId: "mx-a", key: keyBytes(9)}], "mx-a");
    string first = check newEmployee(db, "relink1");
    string second = check newEmployee(db, "relink2");
    string member = "urn:li:person:" + uniq();
    _ = check linkMember(db, cipher, first, member);
    // Held by a live connection: a second employee is refused.
    assertCode(linkMember(db, cipher, second, member), types:ERR_MEMBER_ALREADY_LINKED);
    _ = check connection:removeConnection(new connection:PgConnectionRepository(db, {actorId: first}), first,
            time:utcNow());
    // Removed: the member can be linked from the other employee row (it answered 409 before).
    connection:LinkedInConnection relinked = check linkMember(db, cipher, second, member);
    test:assertEquals(relinked.employeeId, second);
    connection:LinkedInConnection? holder = check (new connection:PgConnectionRepository(db)).findByMember(
            types:LINKEDIN, member);
    test:assertTrue(holder is connection:LinkedInConnection && holder.employeeId == second, "the live holder wins");
    // And while the second holds it, the first can't take it back.
    assertCode(linkMember(db, cipher, first, member), types:ERR_MEMBER_ALREADY_LINKED);
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testRevokeDeletesTheTokenRow() returns error? {
    postgresql:Client db = check api();
    crypto:TokenCipher cipher = check new ([{keyId: "mx-b", key: keyBytes(10)}], "mx-b");
    string emp = check newEmployee(db, "revoke");
    connection:LinkedInConnection c = check linkMember(db, cipher, emp, "urn:li:person:" + uniq(), "Jane Revoke");
    test:assertEquals(c.memberName, "Jane Revoke");
    string tokenId = (<connection:TokenRef>c.currentToken).tokenId;
    connection:PgConnectionRepository repo = new (db, {actorId: emp});
    check repo.save(check connection:revoke(c, time:utcNow()), c.version);
    test:assertEquals(check tokenRows(db, tokenId), 0, "the refused token is gone");
    test:assertEquals(check connection:statusFromView(db, emp), connection:NEEDS_RECONNECT);
    connection:LinkedInConnection? after = check repo.findByEmployee(emp, types:LINKEDIN);
    test:assertTrue(after is connection:LinkedInConnection && after.memberName == "Jane Revoke", "name kept");
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testMentionReadModels() returns error? {
    postgresql:Client db = check api();
    crypto:TokenCipher cipher = check new ([{keyId: "mx-c", key: keyBytes(11)}], "mx-c");
    string label = "mention" + uniq();
    string caller = check newEmployee(db, label + "a");
    string linked = check newEmployee(db, label + "b");
    string removed = check newEmployee(db, label + "c");
    string unlinked = check newEmployee(db, label + "d");
    _ = check linkMember(db, cipher, caller, "urn:li:person:" + uniq());
    _ = check linkMember(db, cipher, linked, "urn:li:person:" + uniq(), "Bee LinkedIn");
    _ = check linkMember(db, cipher, removed, "urn:li:person:" + uniq());
    _ = check connection:removeConnection(new connection:PgConnectionRepository(db, {actorId: removed}), removed,
            time:utcNow());
    connection:MentionableMember[] found = check connection:searchMentionable(db, "Name " + label, caller);
    test:assertEquals(found.map(m => m.employeeId), [linked], "linked only: not the caller, removed or unlinked");
    test:assertEquals(found[0].displayName, "Name " + label + "b");
    test:assertEquals(connection:mentionName(found[0]), "Bee LinkedIn", "LinkedIn's name is the mention text");
    // `%` and `_` in the query are literal.
    test:assertEquals((check connection:searchMentionable(db, "%", caller)).filter(m => m.employeeId == linked).length(), 0);
    connection:MentionableMember[] byIds = check connection:mentionableByIds(db, [linked, removed, unlinked]);
    test:assertEquals(byIds.map(m => m.employeeId), [linked]);
    check db.close();
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testQueuedByEmployee() returns error? {
    postgresql:Client db = check api();
    string po = check newEmployee(db, "queuedpo");
    string emp = check newEmployee(db, "queued");
    time:Utc now = time:utcNow();
    sharing:PgShareRepository repo = new (db, {actorId: emp});
    string[] ids = [];
    foreach int i in 0 ..< 2 {
        campaign:Campaign c = check registerCampaign(db, po);
        sharing:ShareRequest r = check sharing:requestShare(repo, {id: c.id, provider: c.provider,
            resourceUrn: c.resourceUrn, open: true}, {memberUrn: "urn:li:person:" + uniq(), usable: true},
            {employeeId: emp, kind: types:REPOST_COMMENTARY, commentary: "Hi @[A](amplify:person:a) #tag"}, now);
        ids.push(r.id);
    }
    sharing:ShareRequest[] queued = check repo.queuedByEmployee(emp);
    test:assertEquals(queued.map(r => r.id), ids);
    sharing:ShareRequest failed = <sharing:ShareRequest>sharing:failForLostConnection(queued[0], now);
    check repo.update(failed, queued[0].version, []);
    test:assertEquals((check repo.queuedByEmployee(emp)).map(r => r.id), [ids[1]]);
    check db.close();
}
