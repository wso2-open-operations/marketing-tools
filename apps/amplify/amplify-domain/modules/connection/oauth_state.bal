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


// OAuth `state` for the S2 connect flow (`connection.oauth_state`, M5). A state is random, bound to one
// employee, valid for `oauthStateTtlSeconds` and usable once: `consume` deletes it in the same statement
// that reads it, so a replayed callback finds nothing.

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerina/uuid;
import ballerinax/postgresql;

# State lifetime in seconds (10 minutes by default). `configurable` so a deployment can widen or narrow
# the window without a code change; `consume` enforces it.
configurable int oauthStateTtlSeconds = 600;

# One pending connect (`connection.oauth_state`).
public type OAuthState record {|
    # Random, 64 hex characters
    string state;
    # Employee who started the flow
    types:EmployeeId employeeId;
    # Random nonce (OIDC)
    string nonce;
    # One WSO2 path to return to, if any
    string? returnTo;
    # Campaign the employee wanted to share before connecting, if any
    string? pendingCampaignId;
    # Issue time
    time:Utc createdAt;
    # Expiry (`createdAt` + 10 minutes)
    time:Utc expiresAt;
|};

# Persistence port for `connection.oauth_state`.
public type OAuthStateRepository isolated object {
    # Stores a new state.
    #
    # + state - New state
    # + return - An error on failure
    public isolated function issue(OAuthState state) returns error?;

    # Reads and deletes a state in one step. Only the same employee's unexpired state is returned.
    #
    # + state - State from the callback
    # + employeeId - Signed-in employee
    # + now - Current time
    # + return - The state, `()` when unknown, used, expired or someone else's, or an error
    public isolated function consume(string state, types:EmployeeId employeeId, time:Utc now) returns OAuthState|error?;
};

# Builds a fresh state for the employee.
#
# + employeeId - Signed-in employee
# + returnTo - One WSO2 path to return to (relative, starts with `/`)
# + pendingCampaignId - Campaign to share after connecting
# + now - Current time
# + return - The state, or an error when the random source fails
public isolated function newOAuthState(types:EmployeeId employeeId, string? returnTo, string? pendingCampaignId,
        time:Utc now) returns OAuthState|error => {
    state: check randomToken(),
    employeeId,
    nonce: check randomToken(),
    returnTo,
    pendingCampaignId,
    createdAt: now,
    expiresAt: time:utcAddSeconds(now, <decimal>oauthStateTtlSeconds)
};

# Checks the `nonce` claim of the ID token a connect returns against the one Amplify sent on the
# authorization request (OpenID Connect Core §3.1.3.7). A token minted for another request carries a
# different, or no, nonce and must not complete this one.
#
# + state - The consumed state
# + idTokenNonce - The ID token's `nonce` claim, `()` when it has none
# + return - True when the nonce matches; false when it is missing or different
public isolated function nonceMatches(OAuthState state, string? idTokenNonce) returns boolean =>
    idTokenNonce is string && constantTimeEquals(idTokenNonce, state.nonce);

# Compares two strings in time that depends only on their lengths, so a nonce check leaks nothing about
# how many leading characters matched.
#
# + a - First value
# + b - Second value
# + return - True when equal
isolated function constantTimeEquals(string a, string b) returns boolean {
    byte[] x = a.toBytes();
    byte[] y = b.toBytes();
    int diff = x.length() ^ y.length();
    int n = x.length() < y.length() ? x.length() : y.length();
    foreach int i in 0 ..< n {
        diff = diff | (x[i] ^ y[i]);
    }
    return diff == 0;
}

# 64 hex characters from two random UUIDv4s (`java.util.UUID.randomUUID`, backed by SecureRandom):
# 244 random bits.
#
# + return - The token, or an error
isolated function randomToken() returns string|error =>
    re `-`.replaceAll(uuid:createType4AsString() + uuid:createType4AsString(), "");

type OAuthStateRow record {|
    string state;
    string employee_id;
    string nonce;
    string? return_to;
    string? pending_campaign_id;
    time:Utc created_at;
    time:Utc expires_at;
|};

# `OAuthStateRepository` over PostgreSQL.
public isolated class PgOAuthStateRepository {
    *OAuthStateRepository;

    private final postgresql:Client db;

    # + db - Shared client (`amplify_api`)
    public isolated function init(postgresql:Client db) {
        self.db = db;
    }

    public isolated function issue(OAuthState s) returns error? {
        _ = check self.db->execute(`
            INSERT INTO connection.oauth_state (state, employee_id, provider, provider_api, nonce, return_to,
                                                pending_campaign_id, created_at, expires_at)
            VALUES (${s.state}, ${s.employeeId}, ${types:LINKEDIN}, ${types:SHARE_ON_LINKEDIN}, ${s.nonce},
                    ${s.returnTo}, CAST(${s.pendingCampaignId} AS uuid), CAST(${store:ts(s.createdAt)} AS timestamptz),
                    CAST(${store:ts(s.expiresAt)} AS timestamptz))`);
    }

    public isolated function consume(string state, types:EmployeeId employeeId, time:Utc now) returns OAuthState|error? {
        // DELETE … RETURNING through queryRow: one statement reads and burns the state (single use).
        OAuthStateRow|error row = self.db->queryRow(`
            DELETE FROM connection.oauth_state
            WHERE state = ${state} AND employee_id = ${employeeId}
              AND expires_at > CAST(${store:ts(now)} AS timestamptz)
            RETURNING state, employee_id, nonce, return_to, pending_campaign_id::text AS pending_campaign_id,
                      created_at, expires_at`);
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        return {
            state: row.state,
            employeeId: row.employee_id,
            nonce: row.nonce,
            returnTo: row.return_to,
            pendingCampaignId: row.pending_campaign_id,
            createdAt: row.created_at,
            expiresAt: row.expires_at
        };
    }
}

# Connection counts by derived status for the PO dashboard (tile 5).
public type ConnectionCounts record {|
    # `ACTIVE`
    int active;
    # `EXPIRING`
    int expiring;
    # `NEEDS_RECONNECT`
    int needsReconnect;
|};

# Counts connections by derived status (`member_connection_v`).
#
# + db - Client
# + return - Counts, or an error
public isolated function connectionCounts(postgresql:Client db) returns ConnectionCounts|error {
    ConnectionCounts counts = check db->queryRow(`
        SELECT count(*) FILTER (WHERE status = 'ACTIVE')::int AS active,
               count(*) FILTER (WHERE status = 'EXPIRING')::int AS expiring,
               count(*) FILTER (WHERE status = 'NEEDS_RECONNECT')::int AS "needsReconnect"
        FROM connection.member_connection_v`);
    return counts;
}
