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

// The company page connection (`connection_org_connection`, phases 2-4): an admin's Community Management token
// for the page, sealed into `connection_provider_token` as owner ORG. One row per page; connect, refresh and revoke
// replace or delete the token rows in the same transaction as the pointers, and each change is audited (never the
// tokens).

import amplify_common.crypto;
import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

const string ORG_CONNECTION_TABLE = "connection_org_connection";

# Audit action for a page connect or reconnect.
public const string ORG_CONNECTED = "OrgConnectionConnected";
# Audit action for a token refresh.
public const string ORG_TOKEN_REFRESHED = "OrgTokenRefreshed";
# Audit action for a page disconnect.
public const string ORG_CONNECTION_REVOKED = "OrgConnectionRevoked";

# Refresh the access token when it expires within this many seconds (7 days): LinkedIn's programmatic refresh
# works any time before the refresh token expires.
public const int ORG_REFRESH_LEAD_SECONDS = 604800;

# Derived page connection status. Never stored.
public enum OrgConnectionStatus {
    # Access token usable
    PAGE_CONNECTED = "CONNECTED",
    # Access token expired and no usable refresh token: an admin must connect again
    PAGE_EXPIRED = "EXPIRED",
    # Disconnected by an admin
    PAGE_REVOKED = "REVOKED"
}

# The company page connection aggregate.
public type OrgConnection record {|
    # Provider
    types:Provider provider;
    # `urn:li:organization:{id}`
    string orgUrn;
    # Always `COMMUNITY_MANAGEMENT`
    types:ProviderApi providerApi;
    # Granted scopes
    string[] scopes;
    # Admin who connected it (employee id)
    types:EmployeeId connectedBy;
    # Current access token row
    TokenRef? accessToken;
    # Current refresh token row, when LinkedIn gave one
    TokenRef? refreshToken;
    # Access token expiry
    time:Utc accessExpiresAt;
    # Refresh token expiry
    time:Utc? refreshExpiresAt;
    # Last connect
    time:Utc connectedAt;
    # Disconnected
    time:Utc? revokedAt;
    # Optimistic lock
    int version;
|};

# A completed page OAuth flow, with the freshly sealed rows.
public type OrgConnectCommand record {|
    # The page
    string orgUrn;
    # Admin (from the token, never the request)
    types:EmployeeId connectedBy;
    # Granted scopes
    string[] scopes;
    # Sealed access token
    StoredToken access;
    # Sealed refresh token, if any
    StoredToken? refresh = ();
|};

# A change to the page connection: the new state, the token rows to insert and delete, and the audit action.
public type OrgConnectionChange record {|
    # Connection after the change
    OrgConnection connection;
    # Rows to insert in the same transaction
    StoredToken[] tokensToInsert;
    # Rows to delete in the same transaction
    TokenRef[] tokensToDelete;
    # `ORG_CONNECTED`, `ORG_TOKEN_REFRESHED` or `ORG_CONNECTION_REVOKED`
    string auditAction;
|};

# Persistence port for `connection_org_connection`.
public type OrgConnectionRepository isolated object {
    # Finds the page connection.
    #
    # + provider - Provider
    # + orgUrn - The page
    # + return - The connection, `()` if never connected, or an error
    public isolated function find(types:Provider provider, string orgUrn) returns OrgConnection|error?;

    # Finds the page connection that is not revoked, whichever page it is (the sync's page).
    #
    # + provider - Provider
    # + return - The connection, `()` when none, or an error
    public isolated function findActive(types:Provider provider) returns OrgConnection|error?;

    # Inserts or updates the connection, inserts and deletes the token rows and audits, in one transaction.
    #
    # + change - The change
    # + expectedVersion - Version read before the change; `()` for an insert
    # + return - `VERSION_CONFLICT`, or another error
    public isolated function save(OrgConnectionChange change, int? expectedVersion) returns error?;
};

// ---- Rules (pure) ---------------------------------------------------------------------------------

# Status of the page connection.
#
# + c - Connection
# + now - Current time
# + return - `CONNECTED`, `EXPIRED` or `REVOKED`
public isolated function orgStatus(OrgConnection c, time:Utc now) returns OrgConnectionStatus {
    if c.revokedAt !is () || c.accessToken is () {
        return PAGE_REVOKED;
    }
    if time:utcDiffSeconds(c.accessExpiresAt, now) > 0d || canRefresh(c, now) {
        return PAGE_CONNECTED;
    }
    return PAGE_EXPIRED;
}

# Whether the refresh token can still be used.
#
# + c - Connection
# + now - Current time
# + return - True with an unexpired refresh token
public isolated function canRefresh(OrgConnection c, time:Utc now) returns boolean {
    time:Utc? until = c.refreshExpiresAt;
    return c.revokedAt is () && c.refreshToken !is () && until is time:Utc && time:utcDiffSeconds(until, now) > 0d;
}

# Whether the sync should refresh the access token before using it.
#
# + c - Connection
# + now - Current time
# + leadSeconds - How long before expiry
# + return - True when it expires within the lead time and a refresh token can replace it
public isolated function needsRefresh(OrgConnection c, time:Utc now, int leadSeconds = ORG_REFRESH_LEAD_SECONDS)
        returns boolean =>
    canRefresh(c, now) && time:utcDiffSeconds(c.accessExpiresAt, now) <= <decimal>leadSeconds;

# Connects (or reconnects) the page: new token rows in, the old ones out, `revokedAt` cleared.
#
# + existing - The row already stored for the page, if any
# + command - The completed flow
# + now - Current time
# + return - The change
public isolated function connectOrg(OrgConnection? existing, OrgConnectCommand command, time:Utc now)
        returns OrgConnectionChange {
    StoredToken? refresh = command.refresh;
    StoredToken[] inserts = [command.access];
    if refresh is StoredToken {
        inserts.push(refresh);
    }
    return {
        connection: {
            provider: types:LINKEDIN,
            orgUrn: command.orgUrn,
            providerApi: types:COMMUNITY_MANAGEMENT,
            scopes: command.scopes,
            connectedBy: command.connectedBy,
            accessToken: tokenRef(command.access),
            refreshToken: refresh is StoredToken ? tokenRef(refresh) : (),
            accessExpiresAt: command.access.expiresAt,
            refreshExpiresAt: refresh is StoredToken ? refresh.expiresAt : (),
            connectedAt: now,
            revokedAt: (),
            version: existing is OrgConnection ? existing.version + 1 : 1
        },
        tokensToInsert: inserts,
        tokensToDelete: existing is OrgConnection ? tokenRefsOf(existing) : [],
        auditAction: ORG_CONNECTED
    };
}

# Replaces the tokens after a refresh grant. LinkedIn may return the same refresh token or a new one; either way it
# is sealed again so the old rows go.
#
# + existing - Connection
# + access - New sealed access token
# + refresh - Sealed refresh token (the same or a new one); `()` keeps the current refresh row
# + return - The change, or `NOT_FOUND` when the page was disconnected meanwhile
public isolated function refreshOrg(OrgConnection existing, StoredToken access, StoredToken? refresh)
        returns OrgConnectionChange|types:DomainError {
    if existing.revokedAt !is () {
        return types:domainError(types:ERR_NOT_FOUND, "The page was disconnected");
    }
    OrgConnection next = existing.clone();
    next.accessToken = tokenRef(access);
    next.accessExpiresAt = access.expiresAt;
    TokenRef[] old = [];
    TokenRef? oldAccess = existing.accessToken;
    if oldAccess is TokenRef {
        old.push(oldAccess);
    }
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
    return {connection: next, tokensToInsert: inserts, tokensToDelete: old, auditAction: ORG_TOKEN_REFRESHED};
}

# Disconnects the page: both token rows deleted, `revokedAt` set.
#
# + existing - Connection
# + now - Current time
# + return - The change
public isolated function revokeOrg(OrgConnection existing, time:Utc now) returns OrgConnectionChange {
    OrgConnection next = existing.clone();
    next.accessToken = ();
    next.refreshToken = ();
    next.revokedAt = now;
    next.version = existing.version + 1;
    return {connection: next, tokensToInsert: [], tokensToDelete: tokenRefsOf(existing),
        auditAction: ORG_CONNECTION_REVOKED};
}

isolated function tokenRefsOf(OrgConnection c) returns TokenRef[] {
    TokenRef[] refs = [];
    TokenRef? access = c.accessToken;
    if access is TokenRef {
        refs.push(access);
    }
    TokenRef? refresh = c.refreshToken;
    if refresh is TokenRef {
        refs.push(refresh);
    }
    return refs;
}

# Seals a page token (owner ORG, AAD `token_id|org_urn|provider`) for today's partition.
#
# + cipher - Token cipher (current key)
# + plaintext - Token from LinkedIn
# + orgUrn - The page
# + kind - `ACCESS` or `REFRESH`
# + expiresAt - Provider expiry
# + now - Current time (sets the partition day)
# + return - The row to insert, or an error
public isolated function sealOrgToken(crypto:TokenCipher cipher, string plaintext, string orgUrn, TokenKind kind,
        time:Utc expiresAt, time:Utc now) returns StoredToken|error {
    string tokenId = types:newUuidV7();
    crypto:SealedToken sealed = check cipher.seal(plaintext, {tokenId, ownerId: orgUrn, provider: types:LINKEDIN});
    return {
        tokenId,
        issuedOn: time:utcToString(now).substring(0, 10),
        ownerType: "ORG",
        ownerId: orgUrn,
        provider: types:LINKEDIN,
        tokenKind: kind,
        ciphertext: sealed.ciphertext,
        nonce: sealed.nonce,
        keyId: sealed.keyId,
        expiresAt
    };
}

// ---- PostgreSQL -----------------------------------------------------------------------------------

type OrgConnectionRow record {|
    string provider;
    string org_urn;
    string provider_api;
    string scopes;
    string connected_by;
    string? access_token_id;
    string? access_token_issued_on;
    string? refresh_token_id;
    string? refresh_token_issued_on;
    time:Utc access_expires_at;
    time:Utc? refresh_expires_at;
    time:Utc connected_at;
    time:Utc? revoked_at;
    int version;
|};

# `OrgConnectionRepository` over PostgreSQL (`connection_` tables only).
public isolated class PgOrgConnectionRepository {
    *OrgConnectionRepository;

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client
    # + actor - Who the writes are for (audit)
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    public isolated function find(types:Provider provider, string orgUrn) returns OrgConnection|error? {
        OrgConnectionRow|error row = self.db->queryRow(`
            SELECT provider, org_urn, provider_api, array_to_json(scopes)::text AS scopes, connected_by,
                   access_token_id::text AS access_token_id, access_token_issued_on::text AS access_token_issued_on,
                   refresh_token_id::text AS refresh_token_id, refresh_token_issued_on::text AS refresh_token_issued_on,
                   access_expires_at, refresh_expires_at, connected_at, revoked_at, version
            FROM connection_org_connection
            WHERE provider = ${provider} AND org_urn = ${orgUrn}`);
        return toOrgConnection(row);
    }

    public isolated function findActive(types:Provider provider) returns OrgConnection|error? {
        OrgConnectionRow|error row = self.db->queryRow(`
            SELECT provider, org_urn, provider_api, array_to_json(scopes)::text AS scopes, connected_by,
                   access_token_id::text AS access_token_id, access_token_issued_on::text AS access_token_issued_on,
                   refresh_token_id::text AS refresh_token_id, refresh_token_issued_on::text AS refresh_token_issued_on,
                   access_expires_at, refresh_expires_at, connected_at, revoked_at, version
            FROM connection_org_connection
            WHERE provider = ${provider} AND revoked_at IS NULL
            ORDER BY connected_at DESC
            LIMIT 1`);
        return toOrgConnection(row);
    }

    public isolated function save(OrgConnectionChange change, int? expectedVersion) returns error? {
        final readonly & OrgConnectionChange c = change.cloneReadOnly();
        error? result = store:inTransaction(isolated function () returns error? => self.saveTx(c, expectedVersion));
        if result is error && store:isUniqueViolation(result, "connection_org_connection_pkey") {
            return store:versionConflict("page connection");
        }
        return result;
    }

    private isolated function saveTx(OrgConnectionChange change, int? expectedVersion) returns error? {
        OrgConnection c = change.connection;
        TokenRef? access = c.accessToken;
        TokenRef? refresh = c.refreshToken;
        string? accessId = access is () ? () : access.tokenId;
        string? accessDay = access is () ? () : access.issuedOn;
        string? refreshId = refresh is () ? () : refresh.tokenId;
        string? refreshDay = refresh is () ? () : refresh.issuedOn;
        string scopes = store:arrayLiteral(c.scopes);
        json before = ();
        transaction {
            foreach StoredToken fresh in change.tokensToInsert {
                check insertToken(self.db, fresh);
            }
            if expectedVersion is () {
                _ = check self.db->execute(`
                    INSERT INTO connection_org_connection (provider, org_urn, provider_api, scopes, connected_by,
                        access_token_id, access_token_issued_on, refresh_token_id, refresh_token_issued_on,
                        access_expires_at, refresh_expires_at, connected_at, revoked_at, version)
                    VALUES (${c.provider}, ${c.orgUrn}, ${c.providerApi}, CAST(${scopes} AS text[]), ${c.connectedBy},
                        CAST(${accessId} AS uuid), CAST(${accessDay} AS date), CAST(${refreshId} AS uuid),
                        CAST(${refreshDay} AS date), CAST(${store:ts(c.accessExpiresAt)} AS timestamptz),
                        CAST(${store:ts(c.refreshExpiresAt)} AS timestamptz), CAST(${store:ts(c.connectedAt)} AS timestamptz),
                        CAST(${store:ts(c.revokedAt)} AS timestamptz), ${c.version})`);
            } else {
                record {|string connected_by; boolean revoked; int version;|}|error old = self.db->queryRow(`
                    WITH prev AS (
                        SELECT provider, org_urn, connected_by AS old_connected_by, revoked_at IS NOT NULL AS old_revoked,
                               version AS old_version
                        FROM connection_org_connection
                        WHERE provider = ${c.provider} AND org_urn = ${c.orgUrn} AND version = ${expectedVersion}
                        FOR UPDATE)
                    UPDATE connection_org_connection
                    SET scopes = CAST(${scopes} AS text[]), connected_by = ${c.connectedBy},
                        access_token_id = CAST(${accessId} AS uuid), access_token_issued_on = CAST(${accessDay} AS date),
                        refresh_token_id = CAST(${refreshId} AS uuid), refresh_token_issued_on = CAST(${refreshDay} AS date),
                        access_expires_at = CAST(${store:ts(c.accessExpiresAt)} AS timestamptz),
                        refresh_expires_at = CAST(${store:ts(c.refreshExpiresAt)} AS timestamptz),
                        connected_at = CAST(${store:ts(c.connectedAt)} AS timestamptz),
                        revoked_at = CAST(${store:ts(c.revokedAt)} AS timestamptz), version = ${c.version}
                    FROM prev
                    WHERE connection_org_connection.provider = prev.provider
                      AND connection_org_connection.org_urn = prev.org_urn
                    RETURNING prev.old_connected_by AS connected_by, prev.old_revoked AS revoked, prev.old_version AS version`);
                if old is error {
                    fail store:isNoRows(old) ? store:versionConflict("page connection") : old;
                }
                before = {connectedBy: old.connected_by, revoked: old.revoked, version: old.version};
            }
            foreach TokenRef gone in change.tokensToDelete {
                _ = check self.db->execute(`
                    DELETE FROM connection_provider_token
                    WHERE token_id = CAST(${gone.tokenId} AS uuid) AND issued_on = CAST(${gone.issuedOn} AS date)
                      AND owner_type = 'ORG'`);
            }
            check store:writeAudit(self.db, store:auditOf(self.actor, change.auditAction, ORG_CONNECTION_TABLE, c.orgUrn,
                    {connectedBy: c.connectedBy, scopes: c.scopes, accessExpiresAt: store:ts(c.accessExpiresAt),
                    revoked: c.revokedAt !is (), version: c.version}, (), before));
            check commit;
        }
    }
}

isolated function toOrgConnection(OrgConnectionRow|error row) returns OrgConnection|error? {
    if row is error {
        return store:isNoRows(row) ? () : row;
    }
    string? accessId = row.access_token_id;
    string? accessDay = row.access_token_issued_on;
    string? refreshId = row.refresh_token_id;
    string? refreshDay = row.refresh_token_issued_on;
    return {
        provider: check row.provider.ensureType(),
        orgUrn: row.org_urn,
        providerApi: check row.provider_api.ensureType(),
        scopes: check row.scopes.fromJsonStringWithType(),
        connectedBy: row.connected_by,
        accessToken: accessId is string && accessDay is string ? {tokenId: accessId, issuedOn: accessDay} : (),
        refreshToken: refreshId is string && refreshDay is string ? {tokenId: refreshId, issuedOn: refreshDay} : (),
        accessExpiresAt: row.access_expires_at,
        refreshExpiresAt: row.refresh_expires_at,
        connectedAt: row.connected_at,
        revokedAt: row.revoked_at,
        version: row.version
    };
}

# Employees whose LinkedIn connection holds these member URNs (removed connections left out: the member took
# Amplify off their account). For the engagement sync, which drops every actor it can't match.
#
# + db - Client
# + memberUrns - `urn:li:person:{id}` values
# + return - Member URN -> employee id, or an error
public isolated function employeesOfMembers(postgresql:Client db, string[] memberUrns) returns map<types:EmployeeId>|error {
    map<types:EmployeeId> found = {};
    if memberUrns.length() == 0 {
        return found;
    }
    string urns = store:arrayLiteral(memberUrns);
    stream<record {|string member_urn; string employee_id;|}, error?> rows = db->query(`
        SELECT member_urn, employee_id FROM connection_member_connection
        WHERE provider = ${types:LINKEDIN} AND removed_at IS NULL AND member_urn = ANY(CAST(${urns} AS text[]))`);
    check from var r in rows
        do {
            found[r.member_urn] = r.employee_id;
        };
    return found;
}
