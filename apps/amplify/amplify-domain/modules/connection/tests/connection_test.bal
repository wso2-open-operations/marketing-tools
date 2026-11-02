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

import amplify_common.crypto;
import amplify_common.events;
import amplify_common.types;

import ballerina/test;
import ballerina/time;

final time:Utc T0 = [1790000000, 0];
const int SIXTY_DAYS = 5184000;

isolated class InMemoryConnections {
    *ConnectionRepository;
    private map<LinkedInConnection> rows = {};
    private TokenRef[] deleted = [];
    private StoredToken[] inserted = [];
    private events:OutboxEvent[] outbox = [];

    public isolated function findByEmployee(types:EmployeeId employeeId, types:Provider provider) returns LinkedInConnection|error? {
        lock {
            return self.rows[employeeId].clone();
        }
    }

    public isolated function findByMember(types:Provider provider, types:MemberUrn memberUrn) returns LinkedInConnection|error? {
        lock {
            foreach LinkedInConnection c in self.rows {
                if c.memberUrn == memberUrn {
                    return c.clone();
                }
            }
            return ();
        }
    }

    public isolated function save(ConnectionChange change, int? expectedVersion) returns error? {
        lock {
            LinkedInConnection? stored = self.rows[change.connection.employeeId];
            if (stored is () && expectedVersion !is ()) || (stored is LinkedInConnection && stored.version != expectedVersion) {
                return types:domainError(types:ERR_VERSION_CONFLICT, "stale");
            }
            self.rows[change.connection.employeeId] = change.connection.clone();
            StoredToken? fresh = change.tokenToInsert.clone();
            if fresh is StoredToken {
                self.inserted.push(fresh);
            }
            TokenRef? old = change.tokenToDelete.clone();
            if old is TokenRef {
                self.deleted.push(old);
            }
            self.outbox.push(...change.outbox.clone());
        }
    }

    public isolated function insertedTokens() returns StoredToken[] {
        lock {
            return self.inserted.clone();
        }
    }

    public isolated function deletedTokens() returns TokenRef[] {
        lock {
            return self.deleted.clone();
        }
    }

    public isolated function events() returns events:OutboxEvent[] {
        lock {
            return self.outbox.clone();
        }
    }
}

function command(string employeeId = "emp-1", string member = "urn:li:person:abc", string tokenId = "t1")
        returns ConnectCommand => {
    employeeId,
    memberUrn: member,
    scopes: ["openid", "profile", "w_member_social"],
    token: {tokenId, issuedOn: "2026-10-16"},
    expiresInSeconds: SIXTY_DAYS
};

isolated function code(any|error result) returns string {
    if result is types:DomainError {
        return result.detail().code;
    }
    return result is error ? "ERROR" : "OK";
}

@test:Config
function statusLifecycleFromTimestamps() returns error? {
    LinkedInConnection c = (check connect((), command(), T0)).connection;
    test:assertEquals(c.accessExpiresAt, types:addDays(T0, 60), "~60-day token");
    test:assertEquals(connectionStatus(c, T0), ACTIVE);
    test:assertEquals(connectionStatus(c, types:addDays(T0, 52)), ACTIVE);
    test:assertEquals(connectionStatus(c, types:addDays(T0, 53)), EXPIRING, "inside reminder_days (7)");
    test:assertEquals(connectionStatus(c, types:addDays(T0, 53), 3), ACTIVE, "reminder window is configurable");
    test:assertEquals(connectionStatus(c, types:addDays(T0, 60)), NEEDS_RECONNECT, "expired");
    test:assertTrue(canShare(c, types:addDays(T0, 55)), "EXPIRING still shares");
    test:assertFalse(canShare(c, types:addDays(T0, 61)));
    test:assertFalse(canShare((), T0), "never connected");
}

@test:Config
function revokedAndRemovedStatuses() returns error? {
    LinkedInConnection c = (check connect((), command(), T0)).connection;
    LinkedInConnection revoked = (check revoke(c, types:addDays(T0, 1))).connection;
    test:assertEquals(connectionStatus(revoked, types:addDays(T0, 1)), NEEDS_RECONNECT);
    LinkedInConnection removed = (check remove(c, types:addDays(T0, 1))).connection;
    test:assertEquals(connectionStatus(removed, types:addDays(T0, 1)), REMOVED, "removed wins");
    test:assertEquals(removed.currentToken, (), "points at no token after removal");
    test:assertEquals(code(revoke(removed, T0)), types:ERR_CONNECTION_REMOVED);
    test:assertEquals(code(remove(removed, T0)), types:ERR_CONNECTION_REMOVED);
}

@test:Config
function reconnectClearsRevocationAndReplacesToken() returns error? {
    LinkedInConnection c = (check connect((), command(), T0)).connection;
    LinkedInConnection revoked = (check revoke(c, types:addDays(T0, 1))).connection;
    ConnectionChange again = check connect(revoked, command(tokenId = "t2"), types:addDays(T0, 2));
    test:assertEquals(again.connection.revokedAt, ());
    test:assertEquals(again.connection.connectedAt, types:addDays(T0, 2));
    test:assertEquals(again.connection.currentToken, {tokenId: "t2", issuedOn: "2026-10-16"});
    test:assertEquals(again.tokenToDelete, {tokenId: "t1", issuedOn: "2026-10-16"}, "old token deleted right away");
    test:assertEquals(connectionStatus(again.connection, types:addDays(T0, 2)), ACTIVE);
    test:assertEquals(again.connection.version, revoked.version + 1);
}

@test:Config
function connectNeedsShareScope() {
    ConnectCommand cmd = command();
    cmd.scopes = ["openid", "profile"];
    test:assertEquals(code(connect((), cmd, T0)), types:ERR_MISSING_SCOPE);
    test:assertEquals(code(connect((), command(member = "urn:li:organization:1"), T0)), types:ERR_INVALID_MEMBER_URN);
}

@test:Config
function expiredTokenIsNotReportedAsMissingPermission() {
    ConnectCommand expired = command();
    expired.expiresInSeconds = 0;
    test:assertEquals(code(connect((), expired, T0)), types:ERR_CONNECTION_NEEDS_RECONNECT,
            "an unusable token asks for a reconnect, not a scope the user can't grant");
    expired.expiresInSeconds = -1;
    test:assertEquals(code(connect((), expired, T0)), types:ERR_CONNECTION_NEEDS_RECONNECT);
}

@test:Config
function oauthStateNonceAndTtl() returns error? {
    OAuthState state = check newOAuthState("emp-1", "/amplify/posts", (), T0);
    test:assertEquals(time:utcDiffSeconds(state.expiresAt, state.createdAt), <decimal>oauthStateTtlSeconds,
            "state lifetime comes from the configurable");
    test:assertTrue(nonceMatches(state, state.nonce), "the ID token's nonce is the one we sent");
    test:assertFalse(nonceMatches(state, "0123456789abcdef"), "another request's nonce is refused");
    test:assertFalse(nonceMatches(state, ()), "a token with no nonce is refused");
}

@test:Config
function oneEmployeePerMemberAndOneConnectionPerEmployee() returns error? {
    InMemoryConnections repo = new;
    _ = check completeConnection(repo, command(), T0);
    test:assertEquals(code(completeConnection(repo, command(employeeId = "emp-2"), T0)),
            types:ERR_MEMBER_ALREADY_LINKED, "B13: member_urn unique");
    LinkedInConnection again = check completeConnection(repo, command(tokenId = "t2"), types:addDays(T0, 1));
    test:assertEquals(again.version, 2, "same row reused: one connection per employee");
    test:assertEquals(repo.deletedTokens(), [{tokenId: "t1", issuedOn: "2026-10-16"}]);
}

@test:Config
function connectionEventsUseCatalogueKeys() returns error? {
    InMemoryConnections repo = new;
    _ = check completeConnection(repo, command(), T0);
    _ = check removeConnection(repo, "emp-1", types:addDays(T0, 1));
    events:OutboxEvent[] outbox = repo.events();
    test:assertEquals(outbox.map(e => e.eventType), [events:CONNECTION_READY, events:CONNECTION_REMOVED]);
    test:assertEquals(outbox[0].idempotencyKey, "ConnectionReady:urn:li:person:abc:" + time:utcToString(T0));
    test:assertEquals(repo.deletedTokens().length(), 1, "remove deletes the token row");
    test:assertEquals(code(removeConnection(repo, "nobody", T0)), types:ERR_NOT_FOUND);
}

// ---- Token written with the connection (api review H3) ---------------------------------------------

function keyOf(int seed) returns byte[] {
    byte[] k = [];
    foreach int i in 0 ..< 32 {
        k.push(<byte>((i + seed) % 256));
    }
    return k;
}

@test:Config
function completeConnectionHandsTheSealedTokenToTheSameSave() returns error? {
    crypto:TokenCipher cipher = check new ([{keyId: "k1", key: keyOf(1)}], "k1");
    StoredToken token = check sealToken(cipher, "bearer", "emp-1", types:addDays(T0, 60), T0);
    ConnectCommand cmd = command();
    cmd.token = tokenRef(token);
    InMemoryConnections repo = new;
    _ = check completeConnection(repo, cmd, T0, token);
    test:assertEquals(repo.insertedTokens().map(t => t.tokenId), [token.tokenId], "inserted by save, not separately");

    // A failed connection write (member held by someone else) never reaches save, so no token row.
    StoredToken other = check sealToken(cipher, "bearer-2", "emp-2", types:addDays(T0, 60), T0);
    ConnectCommand taken = command(employeeId = "emp-2");
    taken.token = tokenRef(other);
    test:assertEquals(code(completeConnection(repo, taken, T0, other)), types:ERR_MEMBER_ALREADY_LINKED);
    test:assertEquals(repo.insertedTokens().length(), 1);

    // The row must be the one the command points at, owned by the same employee.
    test:assertEquals(code(completeConnection(repo, command(tokenId = "elsewhere"), T0, token)), "ERROR");
    ConnectCommand wrongOwner = command(employeeId = "emp-3", member = "urn:li:person:zzz");
    wrongOwner.token = tokenRef(token);
    test:assertEquals(code(completeConnection(repo, wrongOwner, T0, token)), "ERROR");
}

// ---- Key rotation (common H4, domain H-2, jobs H2) ---------------------------------------------------

isolated class InMemoryTokens {
    *TokenResealStore;
    private StoredToken[] rows;

    isolated function init(StoredToken[] rows) {
        self.rows = rows.clone();
    }

    public isolated function sealedWithOtherKey(string activeKeyId, TokenRef? after, int 'limit)
            returns StoredToken[]|error {
        lock {
            StoredToken[] sorted = from StoredToken t in self.rows
                where t.keyId != activeKeyId
                    && (after is () || t.issuedOn > after.issuedOn
                        || (t.issuedOn == after.issuedOn && t.tokenId > after.tokenId))
                order by t.issuedOn ascending, t.tokenId ascending
                limit 'limit
                select t;
            return sorted.clone();
        }
    }

    public isolated function updateSeal(StoredToken old, crypto:SealedToken resealed) returns boolean|error {
        lock {
            foreach int i in 0 ..< self.rows.length() {
                StoredToken t = self.rows[i];
                if t.tokenId == old.tokenId && t.keyId == old.keyId {
                    t.ciphertext = resealed.ciphertext.clone();
                    t.nonce = resealed.nonce.clone();
                    t.keyId = resealed.keyId;
                    return true;
                }
            }
            return false;
        }
    }

    isolated function all() returns StoredToken[] {
        lock {
            return self.rows.clone();
        }
    }
}

@test:Config
function resealTokenMovesAnOldKeyRowToTheActiveKey() returns error? {
    crypto:TokenCipher old = check new ([{keyId: "k1", key: keyOf(1)}], "k1");
    crypto:TokenCipher ring = check new ([{keyId: "k1", key: keyOf(1)}, {keyId: "k2", key: keyOf(9)}], "k2");
    StoredToken token = check sealToken(old, "bearer-1", "emp-1", types:addDays(T0, 60), T0);
    crypto:SealedToken? resealed = check resealToken(ring, token);
    if resealed is () {
        test:assertFail("an old-key row must be re-sealed");
    }
    test:assertEquals(resealed.keyId, "k2");
    test:assertNotEquals(resealed.ciphertext, token.ciphertext);
    StoredToken moved = token.clone();
    moved.ciphertext = resealed.ciphertext;
    moved.nonce = resealed.nonce;
    moved.keyId = resealed.keyId;
    test:assertEquals(check openToken(ring, moved), "bearer-1", "same AAD: the row opens in place");
    test:assertTrue(openToken(old, moved) is error, "the retired key alone can't read it");
    test:assertEquals(check resealToken(ring, moved), (), "already on the active key: no-op");

    // A row moved to another owner (AAD mismatch) doesn't open, so it can't be re-sealed either.
    StoredToken moved2 = token.clone();
    moved2.ownerId = "emp-2";
    test:assertTrue(resealToken(ring, moved2) is error);
}

@test:Config
function resealStaleTokensPagesThroughOldKeyRows() returns error? {
    crypto:TokenCipher old = check new ([{keyId: "k1", key: keyOf(1)}], "k1");
    crypto:TokenCipher ring = check new ([{keyId: "k1", key: keyOf(1)}, {keyId: "k2", key: keyOf(9)}], "k2");
    StoredToken[] rows = [];
    foreach int i in 0 ..< 5 {
        rows.push(check sealToken(old, string `bearer-${i}`, string `emp-${i}`, types:addDays(T0, 60), T0));
    }
    rows.push(check sealToken(ring, "bearer-new", "emp-9", types:addDays(T0, 60), T0));
    StoredToken broken = check sealToken(old, "bearer-x", "emp-x", types:addDays(T0, 60), T0);
    broken.ownerId = "emp-y";
    rows.push(broken);
    InMemoryTokens repo = new (rows);

    ResealReport report = check resealStaleTokens(ring, repo, batchSize = 2);
    test:assertEquals(report, {resealed: 5, skipped: 0, failed: 1, truncated: false});
    foreach StoredToken t in repo.all() {
        if t.ownerId == "emp-y" {
            test:assertEquals(t.keyId, "k1", "a row that doesn't open is left alone");
        } else {
            test:assertEquals(t.keyId, "k2");
            test:assertTrue((check openToken(ring, t)).startsWith("bearer-"));
        }
    }
    ResealReport again = check resealStaleTokens(ring, repo);
    test:assertEquals(again, {resealed: 0, skipped: 0, failed: 1, truncated: false}, "second pass is a no-op");

    InMemoryTokens capped = new (from StoredToken t in rows where t.keyId == "k1" && t.ownerId != "emp-y" select t);
    ResealReport partial = check resealStaleTokens(ring, capped, batchSize = 2, maxRows = 3);
    test:assertEquals(partial.resealed, 3);
    test:assertTrue(partial.truncated, "maxRows stops the pass; the next one carries on");
}
