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


// An employee's Reach connection (`connection_member_analytics`, #1781): their consent, through the Community
// Management app, to Amplify reading the analytics of their own posts (scope `r_member_postAnalytics` only). Tokens
// are sealed into `connection_provider_token` as owner MEMBER_ANALYTICS (owner id = the employee id). Connect and
// refresh replace the token rows in the same transaction as the pointers; disconnect deletes the row and its tokens.
// Each change is audited, never the tokens.

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

const string REACH_TABLE = "connection_member_analytics";

# Audit action for a Reach connect or reconnect.
public const string REACH_CONNECTED_AUDIT = "ReachConnected";
# Audit action for a Reach token refresh.
public const string REACH_TOKEN_REFRESHED = "ReachTokenRefreshed";
# Audit action for a Reach disconnect (the row and its tokens deleted).
public const string REACH_DISCONNECTED = "ReachDisconnected";

# Derived Reach status. Never stored.
public enum ReachStatus {
    # Access token usable, or a usable refresh token can renew it
    REACH_CONNECTED = "CONNECTED",
    # Access token expired and nothing can renew it: the employee connects again
    REACH_EXPIRED = "EXPIRED"
}

# The Reach connection aggregate.
public type ReachConnection record {|
    # The employee (from the token, never the request)
    types:EmployeeId employeeId;
    # Granted scopes
    string[] scopes;
    # Current access token row
    TokenRef accessToken;
    # Current refresh token row, when LinkedIn gave one
    TokenRef? refreshToken;
    # Access token expiry
    time:Utc accessExpiresAt;
    # Refresh token expiry
    time:Utc? refreshExpiresAt;
    # Last connect
    time:Utc connectedAt;
    # Optimistic lock
    int version;
|};

# A change to a Reach connection: the new state, the token rows to insert and delete, and the audit action.
public type ReachChange record {|
    # Connection after the change
    ReachConnection connection;
    # Rows to insert in the same transaction
    StoredToken[] tokensToInsert;
    # Rows to delete in the same transaction
    TokenRef[] tokensToDelete;
    # `REACH_CONNECTED_AUDIT` or `REACH_TOKEN_REFRESHED`
    string auditAction;
|};

# Persistence port for `connection_member_analytics`.
public type ReachConnectionRepository isolated object {
    # The employee's Reach connection.
    #
    # + employeeId - Employee
    # + return - The connection, `()` when none, or an error
    public isolated function find(types:EmployeeId employeeId) returns ReachConnection|error?;

    # Inserts or updates the connection, inserts and deletes the token rows and audits, in one transaction.
    #
    # + change - The change
    # + expectedVersion - Version read before the change; `()` for an insert
    # + return - `VERSION_CONFLICT`, or another error
    public isolated function save(ReachChange change, int? expectedVersion) returns error?;

    # Deletes the connection and its token rows and audits, in one transaction.
    #
    # + existing - The connection as read
    # + return - True when a row was deleted, false when it was already gone, or an error
    public isolated function delete(ReachConnection existing) returns boolean|error;
};

// ---- Rules (pure) ---------------------------------------------------------------------------------

# Whether the refresh token can still be used.
#
# + c - Connection
# + now - Current time
# + return - True with an unexpired refresh token
public isolated function canRefreshReach(ReachConnection c, time:Utc now) returns boolean {
    time:Utc? until = c.refreshExpiresAt;
    return c.refreshToken !is () && until is time:Utc && time:utcDiffSeconds(until, now) > 0d;
}

# Status of a Reach connection.
#
# + c - Connection
# + now - Current time
# + return - `CONNECTED` or `EXPIRED`
public isolated function reachStatus(ReachConnection c, time:Utc now) returns ReachStatus =>
    time:utcDiffSeconds(c.accessExpiresAt, now) > 0d || canRefreshReach(c, now) ? REACH_CONNECTED : REACH_EXPIRED;

# Whether the refresh job should renew the access token before using it.
#
# + c - Connection
# + now - Current time
# + leadSeconds - How long before expiry
# + return - True when it expires within the lead time and a refresh token can replace it
public isolated function needsReachRefresh(ReachConnection c, time:Utc now, int leadSeconds = ORG_REFRESH_LEAD_SECONDS)
        returns boolean =>
    canRefreshReach(c, now) && time:utcDiffSeconds(c.accessExpiresAt, now) <= <decimal>leadSeconds;

# Connects (or reconnects) Reach: new token rows in, the old ones out.
#
# + existing - The row already stored for the employee, if any
# + employeeId - Employee
# + scopes - Granted scopes
# + access - Sealed access token
# + refresh - Sealed refresh token, if any
# + now - Current time
# + return - The change
public isolated function connectReach(ReachConnection? existing, types:EmployeeId employeeId, string[] scopes,
        StoredToken access, StoredToken? refresh, time:Utc now) returns ReachChange {
    StoredToken[] inserts = [access];
    if refresh is StoredToken {
        inserts.push(refresh);
    }
    return {
        connection: {
            employeeId,
            scopes,
            accessToken: tokenRef(access),
            refreshToken: refresh is StoredToken ? tokenRef(refresh) : (),
            accessExpiresAt: access.expiresAt,
            refreshExpiresAt: refresh is StoredToken ? refresh.expiresAt : (),
            connectedAt: now,
            version: existing is ReachConnection ? existing.version + 1 : 1
        },
        tokensToInsert: inserts,
        tokensToDelete: existing is ReachConnection ? reachTokenRefs(existing) : [],
        auditAction: REACH_CONNECTED_AUDIT
    };
}

# Replaces the tokens after a refresh grant.
#
# + existing - Connection
# + access - New sealed access token
# + refresh - New sealed refresh token; `()` keeps the current refresh row
# + return - The change
public isolated function refreshReach(ReachConnection existing, StoredToken access, StoredToken? refresh)
        returns ReachChange {
    // A new record, so a read-only connection (as the jobs keep them) can be refreshed too.
    ReachConnection next = {...existing};
    next.accessToken = tokenRef(access);
    next.accessExpiresAt = access.expiresAt;
    TokenRef[] old = [existing.accessToken];
    StoredToken[] inserts = [access];
    if refresh is StoredToken {
        inserts.push(refresh);
        next.refreshToken = tokenRef(refresh);
        next.refreshExpiresAt = refresh.expiresAt;
        TokenRef? oldRefresh = existing.refreshToken;
        if oldRefresh is TokenRef {
            old.push(oldRefresh);
        }
    }
    next.version = existing.version + 1;
    return {connection: next, tokensToInsert: inserts, tokensToDelete: old, auditAction: REACH_TOKEN_REFRESHED};
}

# The token rows a connection points at.
#
# + c - Connection
# + return - Access, then refresh when present
public isolated function reachTokenRefs(ReachConnection c) returns TokenRef[] {
    TokenRef[] refs = [c.accessToken];
    TokenRef? refresh = c.refreshToken;
    if refresh is TokenRef {
        refs.push(refresh);
    }
    return refs;
}

# Seals a Reach token (owner MEMBER_ANALYTICS, AAD `token_id|employee_id|provider`) for today's partition.
#
# + cipher - Token cipher (current key)
# + plaintext - Token from LinkedIn
# + employeeId - Employee
# + kind - `ACCESS` or `REFRESH`
# + expiresAt - Provider expiry
# + now - Current time (sets the partition day)
# + return - The row to insert, or an error
public isolated function sealReachToken(crypto:TokenCipher cipher, string plaintext, types:EmployeeId employeeId,
        TokenKind kind, time:Utc expiresAt, time:Utc now) returns StoredToken|error {
    string tokenId = types:newUuidV7();
    crypto:SealedToken sealed = check cipher.seal(plaintext, {tokenId, ownerId: employeeId, provider: types:LINKEDIN});
    return {
        tokenId,
        issuedOn: time:utcToString(now).substring(0, 10),
        ownerType: "MEMBER_ANALYTICS",
        ownerId: employeeId,
        provider: types:LINKEDIN,
        tokenKind: kind,
        ciphertext: sealed.ciphertext,
        nonce: sealed.nonce,
        keyId: sealed.keyId,
        expiresAt
    };
}

// ---- PostgreSQL -----------------------------------------------------------------------------------

type ReachRow record {|
    string employee_id;
    string scopes;
    string access_token_id;
    string access_token_issued_on;
    string? refresh_token_id;
    string? refresh_token_issued_on;
    time:Utc access_expires_at;
    time:Utc? refresh_expires_at;
    time:Utc connected_at;
    int version;
|};

# `ReachConnectionRepository` over PostgreSQL (`connection_` tables only).
public isolated class PgReachConnectionRepository {
    *ReachConnectionRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client
    # + actor - Who the writes are for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function find(types:EmployeeId employeeId) returns ReachConnection|error? {
        ReachRow|error row = self.db->queryRow(`
            SELECT employee_id, array_to_json(scopes)::text AS scopes, access_token_id::text AS access_token_id,
                   access_token_issued_on::text AS access_token_issued_on, refresh_token_id::text AS refresh_token_id,
                   refresh_token_issued_on::text AS refresh_token_issued_on, access_expires_at, refresh_expires_at,
                   connected_at, version
            FROM connection_member_analytics WHERE employee_id = ${employeeId}`);
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        return toReachConnection(row);
    }

    # Every Reach connection (the refresh job's consenting employees), oldest connect first.
    #
    # + return - Connections, or an error
    public isolated function allConnections() returns ReachConnection[]|error {
        stream<ReachRow, error?> rows = self.db->query(`
            SELECT employee_id, array_to_json(scopes)::text AS scopes, access_token_id::text AS access_token_id,
                   access_token_issued_on::text AS access_token_issued_on, refresh_token_id::text AS refresh_token_id,
                   refresh_token_issued_on::text AS refresh_token_issued_on, access_expires_at, refresh_expires_at,
                   connected_at, version
            FROM connection_member_analytics ORDER BY connected_at, employee_id`);
        ReachRow[] list = check from ReachRow r in rows select r;
        ReachConnection[] found = [];
        foreach ReachRow r in list {
            found.push(check toReachConnection(r));
        }
        return found;
    }

    public isolated function save(ReachChange change, int? expectedVersion) returns error? {
        final readonly & ReachChange c = change.cloneReadOnly();
        error? result = store:inTransaction(isolated function () returns error? => self.saveTx(c, expectedVersion));
        if result is error && store:isUniqueViolation(result, "connection_member_analytics_pkey") {
            return store:versionConflict("reach connection");
        }
        return result;
    }

    public isolated function delete(ReachConnection existing) returns boolean|error {
        final readonly & ReachConnection c = existing.cloneReadOnly();
        return (check store:inTransactionValue(isolated function () returns boolean|error => self.deleteTx(c)))
            .ensureType();
    }

    private isolated function saveTx(ReachChange change, int? expectedVersion) returns error? {
        ReachConnection c = change.connection;
        TokenRef? refresh = c.refreshToken;
        string? refreshId = refresh is () ? () : refresh.tokenId;
        string? refreshDay = refresh is () ? () : refresh.issuedOn;
        string scopes = store:arrayLiteral(c.scopes);
        transaction {
            foreach StoredToken fresh in change.tokensToInsert {
                check insertToken(self.db, fresh);
            }
            if expectedVersion is () {
                _ = check self.db->execute(`
                    INSERT INTO connection_member_analytics (employee_id, provider, provider_api, scopes,
                        access_token_id, access_token_issued_on, refresh_token_id, refresh_token_issued_on,
                        access_expires_at, refresh_expires_at, connected_at, version)
                    VALUES (${c.employeeId}, ${types:LINKEDIN}, ${types:COMMUNITY_MANAGEMENT}, CAST(${scopes} AS text[]),
                        CAST(${c.accessToken.tokenId} AS uuid), CAST(${c.accessToken.issuedOn} AS date),
                        CAST(${refreshId} AS uuid), CAST(${refreshDay} AS date),
                        CAST(${store:ts(c.accessExpiresAt)} AS timestamptz),
                        CAST(${store:ts(c.refreshExpiresAt)} AS timestamptz),
                        CAST(${store:ts(c.connectedAt)} AS timestamptz), ${c.version})`);
            } else {
                var updated = check self.db->execute(`
                    UPDATE connection_member_analytics
                    SET scopes = CAST(${scopes} AS text[]), access_token_id = CAST(${c.accessToken.tokenId} AS uuid),
                        access_token_issued_on = CAST(${c.accessToken.issuedOn} AS date),
                        refresh_token_id = CAST(${refreshId} AS uuid), refresh_token_issued_on = CAST(${refreshDay} AS date),
                        access_expires_at = CAST(${store:ts(c.accessExpiresAt)} AS timestamptz),
                        refresh_expires_at = CAST(${store:ts(c.refreshExpiresAt)} AS timestamptz),
                        connected_at = CAST(${store:ts(c.connectedAt)} AS timestamptz), version = ${c.version}
                    WHERE employee_id = ${c.employeeId} AND version = ${expectedVersion}`);
                if updated.affectedRowCount != 1 {
                    fail store:versionConflict("reach connection");
                }
            }
            foreach TokenRef gone in change.tokensToDelete {
                _ = check self.db->execute(`
                    DELETE FROM connection_provider_token
                    WHERE token_id = CAST(${gone.tokenId} AS uuid) AND issued_on = CAST(${gone.issuedOn} AS date)
                      AND owner_type = 'MEMBER_ANALYTICS'`);
            }
            check store:writeAudit(self.db, store:auditOf(self.actor, change.auditAction, REACH_TABLE, c.employeeId,
                    {scopes: c.scopes, accessExpiresAt: store:ts(c.accessExpiresAt), version: c.version}));
            check commit;
        }
    }

    private isolated function deleteTx(ReachConnection c) returns boolean|error {
        boolean deleted = false;
        transaction {
            var gone = check self.db->execute(`
                DELETE FROM connection_member_analytics WHERE employee_id = ${c.employeeId}`);
            deleted = gone.affectedRowCount == 1;
            _ = check self.db->execute(`
                DELETE FROM connection_provider_token
                WHERE owner_type = 'MEMBER_ANALYTICS' AND owner_id = ${c.employeeId}`);
            if deleted {
                check store:writeAudit(self.db, store:auditOf(self.actor, REACH_DISCONNECTED, REACH_TABLE, c.employeeId,
                        (), (), {scopes: c.scopes, version: c.version}));
            }
            check commit;
        }
        return deleted;
    }
}

isolated function toReachConnection(ReachRow row) returns ReachConnection|error {
    string? refreshId = row.refresh_token_id;
    string? refreshDay = row.refresh_token_issued_on;
    return {
        employeeId: row.employee_id,
        scopes: check row.scopes.fromJsonStringWithType(),
        accessToken: {tokenId: row.access_token_id, issuedOn: row.access_token_issued_on},
        refreshToken: refreshId is string && refreshDay is string ? {tokenId: refreshId, issuedOn: refreshDay} : (),
        accessExpiresAt: row.access_expires_at,
        refreshExpiresAt: row.refresh_expires_at,
        connectedAt: row.connected_at,
        version: row.version
    };
}

# How many employees have a Reach connection (the "approximate, from N people" note on the boards).
#
# + db - Client
# + return - Count, or an error
public isolated function reachConsentingCount(postgresql:Client db) returns int|error {
    return db->queryRow(`SELECT count(*)::int FROM connection_member_analytics`);
}
