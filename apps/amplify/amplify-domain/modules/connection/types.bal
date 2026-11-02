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

import ballerina/time;

# Derived connection status (`connection.member_connection_v`, B14). Never stored.
public enum ConnectionStatus {
    ACTIVE,
    EXPIRING,
    NEEDS_RECONNECT,
    REMOVED
}

# Default reminder lead time (`connection.reminder_days`).
public const int DEFAULT_REMINDER_DAYS = 7;

# Pointer to the current encrypted token row (`connection.provider_token`, PK `(token_id, issued_on)`).
# The token itself never enters this aggregate.
public type TokenRef record {|
    # `provider_token.token_id` (UUIDv7)
    string tokenId;
    # `provider_token.issued_on`, the daily partition key, `YYYY-MM-DD`
    string issuedOn;
|};

# LinkedIn connection aggregate (`connection.member_connection`): one per employee per provider,
# one employee per LinkedIn member (B13).
public type LinkedInConnection record {|
    # Owner
    types:EmployeeId employeeId;
    # Provider
    types:Provider provider;
    # `urn:li:person:{sub}`, unique per provider
    types:MemberUrn memberUrn;
    # API product the token is for
    types:ProviderApi providerApi;
    # Granted scopes
    string[] scopes;
    # Current token; `()` after removal (a missing token means reconnect)
    TokenRef? currentToken;
    # Access token expiry (about 60 days after connect)
    time:Utc accessExpiresAt;
    # Last connect or reconnect
    time:Utc connectedAt;
    # LinkedIn returned 401 or consent was withdrawn
    time:Utc? revokedAt;
    # Employee removed the connection
    time:Utc? removedAt;
    # Last expiry reminder sent
    time:Utc? lastRemindedAt;
    # Optimistic lock
    int version;
|};

# Result of a completed OAuth flow, ready to become a connection.
public type ConnectCommand record {|
    # Signed-in employee (from the token, never the request)
    string employeeId;
    # Member URN from userinfo
    string memberUrn;
    # Granted scopes
    string[] scopes;
    # The freshly encrypted token row
    TokenRef token;
    # `expires_in` from the token response
    int expiresInSeconds;
|};

# Outcome of a connection change: the new state, the old token row to delete now (reconnect and remove
# delete it right away; partition drop is only the backstop), and the events to write.
public type ConnectionChange record {|
    # Connection after the change
    LinkedInConnection connection;
    # Token row to delete in the same transaction, if any
    TokenRef? tokenToDelete;
    # Outbox events
    events:OutboxEvent[] outbox;
    # Freshly sealed token row to insert in the same transaction (connect / reconnect), so a connection
    # write that fails never leaves an orphan token row behind
    StoredToken? tokenToInsert = ();
|};

# Persistence port for the `connection` schema.
public type ConnectionRepository isolated object {
    # Finds the employee's connection.
    #
    # + employeeId - Employee
    # + provider - Provider
    # + return - The connection, `()` if none, or an error
    public isolated function findByEmployee(types:EmployeeId employeeId, types:Provider provider) returns LinkedInConnection|error?;

    # Finds the connection holding a member URN.
    #
    # + provider - Provider
    # + memberUrn - Member URN
    # + return - The connection, `()` if none, or an error
    public isolated function findByMember(types:Provider provider, types:MemberUrn memberUrn) returns LinkedInConnection|error?;

    # Inserts or updates a connection, inserts `tokenToInsert`, deletes `tokenToDelete` and writes the
    # events, in one transaction.
    #
    # + change - The change
    # + expectedVersion - Version read before the change; `()` for an insert
    # + return - `VERSION_CONFLICT`, or another error
    public isolated function save(ConnectionChange change, int? expectedVersion) returns error?;
};

// ---- Token store (M3) ---------------------------------------------------------------------------

# Owner kind of a token row.
public type TokenOwnerType "MEMBER"|"ORG";

# Kind of a token row.
public type TokenKind "ACCESS"|"REFRESH";

# One encrypted row of `connection.provider_token` (daily partition by `issuedOn`). Holds ciphertext only;
# the plaintext exists in memory just long enough to call LinkedIn.
public type StoredToken record {|
    # UUIDv7, part of the AAD
    string tokenId;
    # UTC day of issue, `YYYY-MM-DD` (partition key)
    string issuedOn;
    # `MEMBER` (phase 1) or `ORG` (future)
    TokenOwnerType ownerType;
    # Employee id or org URN, part of the AAD
    string ownerId;
    # Provider, part of the AAD
    types:Provider provider;
    # `ACCESS` (phase 1) or `REFRESH` (future)
    TokenKind tokenKind;
    # AES-256-GCM ciphertext + tag
    byte[] ciphertext;
    # 96-bit nonce
    byte[] nonce;
    # Encryption key id
    string keyId;
    # Provider expiry
    time:Utc expiresAt;
|};

# Persistence port for `connection.provider_token`.
public type TokenRepository isolated object {
    # Inserts a token row into its day's partition.
    #
    # + token - Encrypted row
    # + return - An error (including a missing partition)
    public isolated function insert(StoredToken token) returns error?;

    # Finds a token row. `()` means the row or its partition is gone: the connection needs a reconnect.
    #
    # + ref - Token pointer
    # + return - The row, `()`, or an error
    public isolated function find(TokenRef ref) returns StoredToken|error?;
};

# Page of token rows sealed under a key other than the active one, for the key-rotation pass.
public type TokenResealStore isolated object {
    # Rows whose `key_id` isn't `activeKeyId`, in `(issued_on, token_id)` order after `after`.
    #
    # + activeKeyId - the cipher's active key id
    # + after - Last row of the previous page, `()` for the first page
    # + 'limit - Page size
    # + return - The rows, or an error
    public isolated function sealedWithOtherKey(string activeKeyId, TokenRef? after, int 'limit)
        returns StoredToken[]|error;

    # Replaces a row's ciphertext, nonce and key id, guarded by the old key id.
    #
    # + old - Row as read
    # + resealed - Values from `TokenCipher.reseal`
    # + return - True when updated, false when the row changed or vanished meanwhile, or an error
    public isolated function updateSeal(StoredToken old, crypto:SealedToken resealed) returns boolean|error;
};

# What a key-rotation pass did.
public type ResealReport record {|
    # Rows moved to the active key
    int resealed;
    # Rows that changed or vanished between the read and the update (a concurrent re-seal or reconnect)
    int skipped;
    # Rows that didn't open (key missing from the ring, or tampered); left as they are
    int failed;
    # True when `maxRows` stopped the pass before the last page
    boolean truncated;
|};
