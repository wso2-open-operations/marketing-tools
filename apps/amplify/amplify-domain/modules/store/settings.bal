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


// `config.app_setting` reads and the admin update (M5), and `messaging.idempotency_key` for the API's
// `Idempotency-Key` header. Infrastructure only; the API validates setting values before calling here.

import amplify_common.types;

import ballerina/time;
import ballerinax/postgresql;

const string SETTING_TABLE = "config.app_setting";

# One setting row.
public type Setting record {|
    # Dotted key, for example `leaderboard.top_n`
    string key;
    # JSON value
    json value;
    # Who changed it last
    string updatedBy;
    # When
    time:Utc updatedAt;
    # Optimistic lock
    int version;
|};

# One change to a setting.
public type SettingChange record {|
    # Key
    string key;
    # New value
    json value;
    # Version read before the change
    int expectedVersion;
|};

type SettingRow record {|
    string key;
    string value;
    string updated_by;
    time:Utc updated_at;
    int version;
|};

# Every setting, by key.
#
# + db - Client
# + return - Settings, or an error
public isolated function readSettings(postgresql:Client db) returns Setting[]|error {
    stream<SettingRow, error?> rows = db->query(`
        SELECT key, value::text AS value, updated_by, updated_at, version FROM config.app_setting ORDER BY key`);
    return from SettingRow r in rows
        select {key: r.key, value: check r.value.fromJsonString(), updatedBy: r.updated_by, updatedAt: r.updated_at,
            version: r.version};
}

# Applies setting changes in one transaction, each guarded by its version, with one audit row per key.
#
# + db - Client (`amplify_api`)
# + actor - Admin
# + changes - Changes
# + now - Current time
# + return - `VERSION_CONFLICT` / `NOT_FOUND`, or another error
public isolated function updateSettings(postgresql:Client db, Actor actor, SettingChange[] changes, time:Utc now)
        returns error? {
    final readonly & Actor who = actor.cloneReadOnly();
    final readonly & SettingChange[] all = changes.cloneReadOnly();
    final readonly & time:Utc at = now.cloneReadOnly();
    return inTransaction(isolated function () returns error? => updateSettingsTx(db, who, all, at));
}

isolated function updateSettingsTx(postgresql:Client db, Actor actor, SettingChange[] changes, time:Utc now)
        returns error? {
    transaction {
        foreach SettingChange c in changes {
            string value = c.value.toJsonString();
            // PostgreSQL 18 `RETURNING old.*`: the audit row gets the value before the change.
            string|error before = db->queryRow(`
                UPDATE config.app_setting
                SET value = CAST(${value} AS jsonb), updated_by = ${actor.actorId},
                    updated_at = CAST(${ts(now)} AS timestamptz), version = version + 1
                WHERE key = ${c.key} AND version = ${c.expectedVersion}
                RETURNING old.value::text`);
            if before is error {
                if !isNoRows(before) {
                    fail before;
                }
                boolean exists = check db->queryRow(`SELECT EXISTS (SELECT 1 FROM config.app_setting WHERE key = ${c.key})`);
                fail exists ? versionConflict(string `setting ${c.key}`)
                    : types:domainError(types:ERR_NOT_FOUND, string `Unknown setting ${c.key}`);
            }
            check writeAudit(db, auditOf(actor, "SettingChanged", SETTING_TABLE, c.key, {value: c.value}, (),
                    {value: check before.fromJsonString()}));
        }
        check commit;
    }
}

// ---- Idempotency keys (`messaging.idempotency_key`) ---------------------------------------------

# A key seen before.
public type IdempotencyRecord record {|
    # SHA-256 of method, route and body of the first request
    string requestHash;
    # Stored status; `()` while the first request is still running
    int? responseStatus;
    # Stored body
    json responseBody;
|};

# Claims an idempotency key for a request. An expired row is replaced.
#
# + db - Client
# + employeeId - Caller (keys are per caller)
# + key - Header value
# + requestHash - Request fingerprint
# + ttlSeconds - How long the key is remembered
# + now - Current time
# + return - `()` when this request owns the key now, the earlier record otherwise, or an error
public isolated function claimIdempotencyKey(postgresql:Client db, types:EmployeeId employeeId, string key,
        string requestHash, int ttlSeconds, time:Utc now) returns IdempotencyRecord|error? {
    string nowText = time:utcToString(now);
    string expires = time:utcToString(time:utcAddSeconds(now, <decimal>ttlSeconds));
    _ = check db->execute(`
        DELETE FROM messaging.idempotency_key
        WHERE employee_id = ${employeeId} AND key = ${key} AND expires_at <= CAST(${nowText} AS timestamptz)`);
    var inserted = check db->execute(`
        INSERT INTO messaging.idempotency_key (employee_id, key, request_hash, created_at, expires_at)
        VALUES (${employeeId}, ${key}, ${requestHash}, CAST(${nowText} AS timestamptz), CAST(${expires} AS timestamptz))
        ON CONFLICT (employee_id, key) DO NOTHING`);
    if inserted.affectedRowCount == 1 {
        return ();
    }
    record {|string request_hash; int? response_status; string? response_body;|}|error row = db->queryRow(`
        SELECT request_hash, response_status, response_body::text AS response_body
        FROM messaging.idempotency_key WHERE employee_id = ${employeeId} AND key = ${key}`);
    if row is error {
        if !isNoRows(row) {
            return row;
        }
        // The holder released the key between our insert and this read (its request failed): claim it
        // now. A second loss of the race reports the key as still running.
        var retried = check db->execute(`
            INSERT INTO messaging.idempotency_key (employee_id, key, request_hash, created_at, expires_at)
            VALUES (${employeeId}, ${key}, ${requestHash}, CAST(${nowText} AS timestamptz),
                    CAST(${expires} AS timestamptz))
            ON CONFLICT (employee_id, key) DO NOTHING`);
        return retried.affectedRowCount == 1 ? () : {requestHash, responseStatus: (), responseBody: ()};
    }
    string? body = row.response_body;
    return {
        requestHash: row.request_hash,
        responseStatus: row.response_status,
        responseBody: body is string ? check body.fromJsonString() : ()
    };
}

# Stores the response for a claimed key so a replay returns it.
#
# + db - Client
# + employeeId - Caller
# + key - Header value
# + status - HTTP status
# + body - Response body
# + return - An error on failure
public isolated function completeIdempotencyKey(postgresql:Client db, types:EmployeeId employeeId, string key, int status,
        json body) returns error? {
    string text = body.toJsonString();
    _ = check db->execute(`
        UPDATE messaging.idempotency_key SET response_status = ${status}, response_body = CAST(${text} AS jsonb)
        WHERE employee_id = ${employeeId} AND key = ${key}`);
}

# Forgets a claimed key (the request failed in a way the caller may retry).
#
# + db - Client
# + employeeId - Caller
# + key - Header value
# + return - An error on failure
public isolated function releaseIdempotencyKey(postgresql:Client db, types:EmployeeId employeeId, string key)
        returns error? {
    _ = check db->execute(`
        DELETE FROM messaging.idempotency_key
        WHERE employee_id = ${employeeId} AND key = ${key} AND response_status IS NULL`);
}
