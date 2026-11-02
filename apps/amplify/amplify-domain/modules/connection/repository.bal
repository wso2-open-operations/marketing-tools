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

// PostgreSQL implementations of `ConnectionRepository` and `TokenRepository` (schema `connection` only).
// Token rows hold ciphertext only and are never logged or audited with their content.

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

const string CONNECTION_TABLE = "connection.member_connection";

type ConnectionRow record {|
    string employee_id;
    string provider;
    string member_urn;
    string provider_api;
    string scopes;
    string? current_token_id;
    string? current_token_issued_on;
    time:Utc access_expires_at;
    time:Utc connected_at;
    time:Utc? revoked_at;
    time:Utc? removed_at;
    time:Utc? last_reminded_at;
    int version;
|};

type TokenRow record {|
    string token_id;
    string issued_on;
    string owner_type;
    string owner_id;
    string provider;
    string token_kind;
    byte[] ciphertext;
    byte[] nonce;
    string key_id;
    time:Utc expires_at;
|};

# `ConnectionRepository` over PostgreSQL.
public isolated class PgConnectionRepository {
    *ConnectionRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client (`amplify_api` or `amplify_jobs`)
    # + actor - Who the writes are for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function findByEmployee(types:EmployeeId employeeId, types:Provider provider)
            returns LinkedInConnection|error? {
        ConnectionRow|error row = self.db->queryRow(`
            SELECT employee_id, provider, member_urn, provider_api, array_to_json(scopes)::text AS scopes,
                   current_token_id::text AS current_token_id, current_token_issued_on::text AS current_token_issued_on,
                   access_expires_at, connected_at, revoked_at, removed_at, last_reminded_at, version
            FROM connection.member_connection WHERE employee_id = ${employeeId} AND provider = ${provider}`);
        return toConnection(row);
    }

    public isolated function findByMember(types:Provider provider, types:MemberUrn memberUrn) returns LinkedInConnection|error? {
        ConnectionRow|error row = self.db->queryRow(`
            SELECT employee_id, provider, member_urn, provider_api, array_to_json(scopes)::text AS scopes,
                   current_token_id::text AS current_token_id, current_token_issued_on::text AS current_token_issued_on,
                   access_expires_at, connected_at, revoked_at, removed_at, last_reminded_at, version
            FROM connection.member_connection WHERE provider = ${provider} AND member_urn = ${memberUrn}`);
        return toConnection(row);
    }

    public isolated function save(ConnectionChange change, int? expectedVersion) returns error? {
        final readonly & ConnectionChange c = change.cloneReadOnly();
        error? result = store:inTransaction(isolated function () returns error? => self.saveTx(c, expectedVersion));
        if result is error {
            if store:isUniqueViolation(result, "member_connection_member_uk") {
                return types:domainError(types:ERR_MEMBER_ALREADY_LINKED,
                        "This LinkedIn account is already connected to another employee");
            }
            if store:isUniqueViolation(result, "member_connection_pkey") {
                return store:versionConflict("connection");
            }
        }
        return result;
    }

    private isolated function saveTx(ConnectionChange change, int? expectedVersion) returns error? {
        LinkedInConnection c = change.connection;
        TokenRef? token = c.currentToken;
        string? tokenId = token is () ? () : token.tokenId;
        string? issuedOn = token is () ? () : token.issuedOn;
        string scopes = store:arrayLiteral(c.scopes);
        json before = ();
        StoredToken? fresh = change.tokenToInsert;
        transaction {
            // The new token row goes in first and rolls back with the connection write (api review H3).
            if fresh is StoredToken {
                check insertToken(self.db, fresh);
            }
            if expectedVersion is () {
                _ = check self.db->execute(`
                    INSERT INTO connection.member_connection (employee_id, provider, member_urn, provider_api, scopes,
                        current_token_id, current_token_issued_on, access_expires_at, connected_at, revoked_at,
                        removed_at, last_reminded_at, version)
                    VALUES (${c.employeeId}, ${c.provider}, ${c.memberUrn}, ${c.providerApi}, CAST(${scopes} AS text[]),
                        CAST(${tokenId} AS uuid), CAST(${issuedOn} AS date), CAST(${store:ts(c.accessExpiresAt)} AS timestamptz), CAST(${store:ts(c.connectedAt)} AS timestamptz),
                        CAST(${store:ts(c.revokedAt)} AS timestamptz), CAST(${store:ts(c.removedAt)} AS timestamptz), CAST(${store:ts(c.lastRemindedAt)} AS timestamptz), ${c.version})`);
            } else {
                record {|string member_urn; int version; boolean revoked; boolean removed;|}|error old = self.db->queryRow(`
                    UPDATE connection.member_connection
                    SET member_urn = ${c.memberUrn}, provider_api = ${c.providerApi}, scopes = CAST(${scopes} AS text[]),
                        current_token_id = CAST(${tokenId} AS uuid), current_token_issued_on = CAST(${issuedOn} AS date),
                        access_expires_at = CAST(${store:ts(c.accessExpiresAt)} AS timestamptz), connected_at = CAST(${store:ts(c.connectedAt)} AS timestamptz),
                        revoked_at = CAST(${store:ts(c.revokedAt)} AS timestamptz), removed_at = CAST(${store:ts(c.removedAt)} AS timestamptz),
                        last_reminded_at = CAST(${store:ts(c.lastRemindedAt)} AS timestamptz), version = ${c.version}
                    WHERE employee_id = ${c.employeeId} AND provider = ${c.provider} AND version = ${expectedVersion}
                    RETURNING old.member_urn, old.version, old.revoked_at IS NOT NULL AS revoked,
                              old.removed_at IS NOT NULL AS removed`);
                if old is error {
                    fail store:isNoRows(old) ? store:versionConflict("connection") : old;
                }
                before = {memberUrn: old.member_urn, version: old.version, revoked: old.revoked, removed: old.removed};
            }
            // Reconnect and Remove delete the old token row right away; the partition drop is the backstop.
            TokenRef? old = change.tokenToDelete;
            if old is TokenRef {
                _ = check self.db->execute(`
                    DELETE FROM connection.provider_token
                    WHERE token_id = CAST(${old.tokenId} AS uuid) AND issued_on = CAST(${old.issuedOn} AS date)`);
            }
            _ = check store:writeOutbox(self.db, change.outbox, self.actor.correlationId);
            foreach var event in change.outbox {
                check store:writeAudit(self.db, store:auditOf(self.actor, event.eventType, CONNECTION_TABLE,
                        c.employeeId, {memberUrn: c.memberUrn, version: c.version, revoked: c.revokedAt !is (),
                        removed: c.removedAt !is ()}, (), before));
            }
            check commit;
        }
    }
}

# `TokenRepository` over PostgreSQL.
public isolated class PgTokenRepository {
    *TokenRepository;

    private final postgresql:Client db;

    # + db - Shared client (`amplify_api` writes, `amplify_jobs` reads)
    public isolated function init(postgresql:Client db) {
        self.db = db;
    }

    public isolated function insert(StoredToken token) returns error? => insertToken(self.db, token);

    # Rows sealed under a key other than `activeKeyId`, oldest first, keyset-paged on `(issued_on, token_id)`
    # (the key-rotation pass, `resealStaleTokens`).
    #
    # + activeKeyId - the cipher's active key id
    # + after - Last row of the previous page, `()` for the first page
    # + 'limit - Page size
    # + return - The rows, or an error
    public isolated function sealedWithOtherKey(string activeKeyId, TokenRef? after, int 'limit)
            returns StoredToken[]|error {
        string? afterDay = after is () ? () : after.issuedOn;
        string? afterId = after is () ? () : after.tokenId;
        stream<TokenRow, error?> rows = self.db->query(`
            SELECT token_id::text AS token_id, issued_on::text AS issued_on, owner_type, owner_id, provider, token_kind,
                   ciphertext, nonce, key_id, expires_at
            FROM connection.provider_token
            WHERE key_id <> ${activeKeyId}
              AND (CAST(${afterDay} AS date) IS NULL
                   OR (issued_on, token_id) > (CAST(${afterDay} AS date), CAST(${afterId} AS uuid)))
            ORDER BY issued_on, token_id
            LIMIT ${'limit < 1 ? 1 : 'limit}`);
        TokenRow[] page = check from TokenRow r in rows select r;
        StoredToken[] result = [];
        foreach TokenRow r in page {
            result.push(check toStoredToken(r));
        }
        return result;
    }

    # Replaces a token row's ciphertext, nonce and key id after a re-seal under the current key (token key
    # rotation). Same row, same `token_id` / `issued_on` / owner, so the AAD and the partition don't move.
    # Guarded by the old `key_id`: a concurrent re-seal (or a reconnect that deleted the row) makes this a
    # no-op instead of overwriting newer ciphertext.
    #
    # + old - Row as read (its `keyId` is the guard)
    # + resealed - Ciphertext, nonce and key id from the cipher
    # + return - True when the row was updated, false when it changed or vanished meanwhile, or an error
    public isolated function updateSeal(StoredToken old, crypto:SealedToken resealed) returns boolean|error {
        var result = check self.db->execute(`
            UPDATE connection.provider_token
            SET ciphertext = ${resealed.ciphertext}, nonce = ${resealed.nonce}, key_id = ${resealed.keyId}
            WHERE token_id = CAST(${old.tokenId} AS uuid) AND issued_on = CAST(${old.issuedOn} AS date)
              AND key_id = ${old.keyId}`);
        return result.affectedRowCount == 1;
    }

    public isolated function find(TokenRef ref) returns StoredToken|error? {
        TokenRow|error row = self.db->queryRow(`
            SELECT token_id::text AS token_id, issued_on::text AS issued_on, owner_type, owner_id, provider, token_kind,
                   ciphertext, nonce, key_id, expires_at
            FROM connection.provider_token
            WHERE token_id = CAST(${ref.tokenId} AS uuid) AND issued_on = CAST(${ref.issuedOn} AS date)`);
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        return toStoredToken(row);
    }
}

isolated function insertToken(postgresql:Client db, StoredToken token) returns error? {
    _ = check db->execute(`
        INSERT INTO connection.provider_token (token_id, issued_on, owner_type, owner_id, provider, token_kind,
                                               ciphertext, nonce, key_id, expires_at)
        VALUES (CAST(${token.tokenId} AS uuid), CAST(${token.issuedOn} AS date), ${token.ownerType},
                ${token.ownerId}, ${token.provider}, ${token.tokenKind}, ${token.ciphertext}, ${token.nonce},
                ${token.keyId}, CAST(${store:ts(token.expiresAt)} AS timestamptz))`);
}

isolated function toStoredToken(TokenRow row) returns StoredToken|error => {
    tokenId: row.token_id,
    issuedOn: row.issued_on,
    ownerType: check row.owner_type.ensureType(),
    ownerId: row.owner_id,
    provider: check row.provider.ensureType(),
    tokenKind: check row.token_kind.ensureType(),
    ciphertext: row.ciphertext,
    nonce: row.nonce,
    keyId: row.key_id,
    expiresAt: row.expires_at
};

# Derived status as `connection.member_connection_v` computes it (the view also checks the token row).
#
# + db - Client
# + employeeId - Employee
# + return - `ACTIVE`, `EXPIRING`, `NEEDS_RECONNECT`, `REMOVED`, `()` if never connected, or an error
public isolated function statusFromView(postgresql:Client db, types:EmployeeId employeeId) returns ConnectionStatus|error? {
    string|error status = db->queryRow(`
        SELECT status FROM connection.member_connection_v WHERE employee_id = ${employeeId} AND provider = ${types:LINKEDIN}`);
    if status is error {
        return store:isNoRows(status) ? () : status;
    }
    return check status.ensureType();
}

isolated function toConnection(ConnectionRow|error row) returns LinkedInConnection|error? {
    if row is error {
        return store:isNoRows(row) ? () : row;
    }
    string? tokenId = row.current_token_id;
    string? issuedOn = row.current_token_issued_on;
    return {
        employeeId: row.employee_id,
        provider: check row.provider.ensureType(),
        memberUrn: row.member_urn,
        providerApi: check row.provider_api.ensureType(),
        scopes: check row.scopes.fromJsonStringWithType(),
        currentToken: tokenId is string && issuedOn is string ? {tokenId, issuedOn} : (),
        accessExpiresAt: row.access_expires_at,
        connectedAt: row.connected_at,
        revokedAt: row.revoked_at,
        removedAt: row.removed_at,
        lastRemindedAt: row.last_reminded_at,
        version: row.version
    };
}
