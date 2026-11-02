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
import amplify_common.linkedin;
import amplify_common.types;

import ballerina/time;

// ---- Derived status -------------------------------------------------------------------------------

# Connection status from its facts and the clock, as `member_connection_v` computes it.
#
# + connection - Connection
# + now - Current time
# + reminderDays - `connection.reminder_days`
# + return - `REMOVED` if removed; `NEEDS_RECONNECT` if revoked after the last connect, expired, or without
# a token; `EXPIRING` inside the reminder window; else `ACTIVE`
public isolated function connectionStatus(LinkedInConnection connection, time:Utc now,
        int reminderDays = DEFAULT_REMINDER_DAYS) returns ConnectionStatus {
    if connection.removedAt !is () {
        return REMOVED;
    }
    time:Utc? revokedAt = connection.revokedAt;
    if revokedAt is time:Utc && types:isBefore(connection.connectedAt, revokedAt) {
        return NEEDS_RECONNECT;
    }
    if connection.currentToken is () || !types:isBefore(now, connection.accessExpiresAt) {
        return NEEDS_RECONNECT;
    }
    if !types:isBefore(now, types:addDays(connection.accessExpiresAt, -reminderDays)) {
        return EXPIRING;
    }
    return ACTIVE;
}

# Whether Amplify may post with this connection: `ACTIVE`, or `EXPIRING` (the token still works).
#
# + connection - Connection, or `()` when the employee never connected
# + now - Current time
# + reminderDays - `connection.reminder_days`
# + return - True when a share can be queued
public isolated function canShare(LinkedInConnection? connection, time:Utc now,
        int reminderDays = DEFAULT_REMINDER_DAYS) returns boolean {
    if connection is () {
        return false;
    }
    ConnectionStatus status = connectionStatus(connection, now, reminderDays);
    return status == ACTIVE || status == EXPIRING;
}

// ---- Aggregate rules (pure) -----------------------------------------------------------------------

# Connects or reconnects. A reconnect sets `connectedAt`, the expiry and the new token pointer, clears
# `revokedAt` and `removedAt`, and hands back the old token row to delete.
#
# + existing - The employee's current connection, if any
# + command - Completed OAuth result
# + now - Current time
# + return - The change with `ConnectionReady`, `MISSING_SCOPE`, `CONNECTION_NEEDS_RECONNECT` (an
# already expired token) or a value-object error
public isolated function connect(LinkedInConnection? existing, ConnectCommand command, time:Utc now)
        returns ConnectionChange|types:DomainError {
    types:EmployeeId employeeId = check types:parseEmployeeId(command.employeeId);
    types:MemberUrn memberUrn = check types:parseMemberUrn(command.memberUrn);
    if command.scopes.indexOf(linkedin:SCOPE_W_MEMBER_SOCIAL) is () {
        return types:domainError(types:ERR_MISSING_SCOPE, "LinkedIn didn't grant permission to share for you");
    }
    if command.expiresInSeconds <= 0 {
        // Not a scope problem: the token is unusable, so the caller has to connect again.
        return types:domainError(types:ERR_CONNECTION_NEEDS_RECONNECT, "LinkedIn returned an already expired token");
    }
    LinkedInConnection connection = {
        employeeId,
        provider: types:LINKEDIN,
        memberUrn,
        providerApi: types:SHARE_ON_LINKEDIN,
        scopes: command.scopes.clone(),
        currentToken: command.token.clone(),
        accessExpiresAt: time:utcAddSeconds(now, <decimal>command.expiresInSeconds),
        connectedAt: now,
        revokedAt: (),
        removedAt: (),
        lastRemindedAt: (),
        version: existing is () ? 1 : existing.version + 1
    };
    TokenRef? old = existing is () ? () : existing.currentToken;
    return {
        connection,
        tokenToDelete: old is TokenRef && old != command.token ? old : (),
        outbox: [connectionReadyEvent(connection)]
    };
}

# Marks a connection revoked (LinkedIn 401, or consent withdrawn). Unpublished shares then fail with
# `NEEDS_RECONNECT` through `ConnectionRevoked`.
#
# + connection - Connection
# + now - Current time
# + return - The change, or `CONNECTION_REMOVED`
public isolated function revoke(LinkedInConnection connection, time:Utc now) returns ConnectionChange|types:DomainError {
    if connection.removedAt !is () {
        return types:domainError(types:ERR_CONNECTION_REMOVED, "The connection was removed");
    }
    LinkedInConnection revoked = connection.clone();
    revoked.revokedAt = now;
    revoked.version = connection.version + 1;
    return {connection: revoked, tokenToDelete: (), outbox: [connectionRevokedEvent(revoked, now)]};
}

# Removes the connection (Remove Connection): sets `removedAt`, drops the token pointer and returns the
# token row to delete now. Sharing stops.
#
# + connection - Connection
# + now - Current time
# + return - The change, or `CONNECTION_REMOVED` if already removed
public isolated function remove(LinkedInConnection connection, time:Utc now) returns ConnectionChange|types:DomainError {
    if connection.removedAt !is () {
        return types:domainError(types:ERR_CONNECTION_REMOVED, "The connection is already removed");
    }
    LinkedInConnection removed = connection.clone();
    removed.removedAt = now;
    removed.currentToken = ();
    removed.version = connection.version + 1;
    return {connection: removed, tokenToDelete: connection.currentToken, outbox: [connectionRemovedEvent(removed, now)]};
}

// ---- Use cases ------------------------------------------------------------------------------------

# Completes a LinkedIn connection after OAuth. One member can belong to only one employee (B13).
#
# + repo - Connection repository
# + command - Completed OAuth result
# + now - Current time
# + token - The sealed token row `command.token` points at. When given, `repo.save` inserts it in the
# connection's transaction, so a connection write that fails (`MEMBER_ALREADY_LINKED`, a version conflict,
# a database error) leaves no token row behind
# + return - The connection, `MEMBER_ALREADY_LINKED`, another domain error, or a repository error
public isolated function completeConnection(ConnectionRepository repo, ConnectCommand command, time:Utc now,
        StoredToken? token = ()) returns LinkedInConnection|error {
    types:EmployeeId employeeId = check types:parseEmployeeId(command.employeeId);
    types:MemberUrn memberUrn = check types:parseMemberUrn(command.memberUrn);
    if token is StoredToken && (tokenRef(token) != command.token || token.ownerId != employeeId) {
        return error("The sealed token doesn't match the connect command");
    }
    LinkedInConnection? holder = check repo.findByMember(types:LINKEDIN, memberUrn);
    if holder is LinkedInConnection && holder.employeeId != employeeId {
        return types:domainError(types:ERR_MEMBER_ALREADY_LINKED,
                "This LinkedIn account is already connected to another employee");
    }
    LinkedInConnection? existing = check repo.findByEmployee(employeeId, types:LINKEDIN);
    ConnectionChange change = check connect(existing, command, now);
    change.tokenToInsert = token.clone();
    check repo.save(change, existing is () ? () : existing.version);
    return change.connection;
}

# Removes the employee's connection.
#
# + repo - Connection repository
# + employeeId - Signed-in employee
# + now - Current time
# + return - The removed connection, `NOT_FOUND`, `CONNECTION_REMOVED`, or a repository error
public isolated function removeConnection(ConnectionRepository repo, types:EmployeeId employeeId, time:Utc now)
        returns LinkedInConnection|error {
    LinkedInConnection? existing = check repo.findByEmployee(employeeId, types:LINKEDIN);
    if existing is () {
        return types:domainError(types:ERR_NOT_FOUND, "No LinkedIn connection");
    }
    ConnectionChange change = check remove(existing, now);
    check repo.save(change, existing.version);
    return change.connection;
}

// ---- Token sealing (M3) ---------------------------------------------------------------------------

# Encrypts a fresh provider token into a row for today's partition (UTC). AAD = `token_id|owner_id|provider`.
#
# + cipher - Token cipher (current key)
# + plaintext - Bearer token from the provider
# + ownerId - Employee id
# + expiresAt - Provider expiry
# + now - Current time (sets the partition day)
# + return - The row to insert, or an error
public isolated function sealToken(crypto:TokenCipher cipher, string plaintext, types:EmployeeId ownerId,
        time:Utc expiresAt, time:Utc now) returns StoredToken|error {
    string tokenId = types:newUuidV7();
    crypto:SealedToken sealed = check cipher.seal(plaintext, {tokenId, ownerId, provider: types:LINKEDIN});
    return {
        tokenId,
        issuedOn: time:utcToString(now).substring(0, 10),
        ownerType: "MEMBER",
        ownerId,
        provider: types:LINKEDIN,
        tokenKind: "ACCESS",
        ciphertext: sealed.ciphertext,
        nonce: sealed.nonce,
        keyId: sealed.keyId,
        expiresAt
    };
}

# Decrypts a stored token right before a provider call. Never log the result.
#
# + cipher - Token cipher (key ring)
# + token - Stored row
# + return - The bearer token, or an error if the row was tampered with or moved
public isolated function openToken(crypto:TokenCipher cipher, StoredToken token) returns string|error =>
    cipher.open({ciphertext: token.ciphertext, nonce: token.nonce, keyId: token.keyId},
        {tokenId: token.tokenId, ownerId: token.ownerId, provider: token.provider});

# Re-encrypts a row written under an older key with the cipher's active key (key rotation). Same AAD as
# `openToken`; `tokenId`, `issuedOn`, owner and expiry stay, so the row is updated in place
# (`PgTokenRepository.updateSeal`). The plaintext never leaves the cipher.
#
# + cipher - Token cipher (key ring, active key)
# + token - Stored row
# + return - The new ciphertext, nonce and key id; `()` when the row already uses the active key; or an
# error (never containing token material) when the row doesn't open
public isolated function resealToken(crypto:TokenCipher cipher, StoredToken token) returns crypto:SealedToken|error? =>
    cipher.reseal({ciphertext: token.ciphertext, nonce: token.nonce, keyId: token.keyId},
        {tokenId: token.tokenId, ownerId: token.ownerId, provider: token.provider});

# Moves every token row sealed under an older key to the active key, page by page (key rotation, so an
# old key can leave the ring before its last partition drops). A row that doesn't open is counted and
# left alone; a row that changed meanwhile is skipped (the update is guarded by the old key id).
#
# + cipher - Token cipher
# + repo - Token rows (`PgTokenRepository`)
# + batchSize - Page size
# + maxRows - Most rows looked at in one pass; the next pass carries on
# + return - Counts, or an error from the repository
public isolated function resealStaleTokens(crypto:TokenCipher cipher, TokenResealStore repo, int batchSize = 100,
        int maxRows = 10000) returns ResealReport|error {
    ResealReport report = {resealed: 0, skipped: 0, failed: 0, truncated: false};
    int size = batchSize < 1 ? 1 : batchSize;
    int seen = 0;
    TokenRef? after = ();
    while true {
        if seen >= maxRows {
            report.truncated = true;
            break;
        }
        int 'limit = maxRows - seen < size ? maxRows - seen : size;
        StoredToken[] page = check repo.sealedWithOtherKey(cipher.activeKeyId(), after, 'limit);
        foreach StoredToken row in page {
            crypto:SealedToken|error? resealed = resealToken(cipher, row);
            if resealed is error {
                report.failed += 1;
            } else if resealed is () {
                report.skipped += 1;
            } else if check repo.updateSeal(row, resealed) {
                report.resealed += 1;
            } else {
                report.skipped += 1;
            }
        }
        seen += page.length();
        if page.length() < 'limit {
            break;
        }
        after = tokenRef(page[page.length() - 1]);
    }
    return report;
}

# Pointer to a stored token, for `ConnectCommand.token`.
#
# + token - Stored row
# + return - The pointer
public isolated function tokenRef(StoredToken token) returns TokenRef => {tokenId: token.tokenId, issuedOn: token.issuedOn};
