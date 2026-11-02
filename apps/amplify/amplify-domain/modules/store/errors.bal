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

// SQL error mapping. Repositories turn constraint violations into stable domain errors so callers
// never see SQL text (CLAUDE.md: never return raw errors).

import amplify_common.types;

import ballerina/sql;
import ballerina/time;

# SQLSTATE for a unique violation.
public const string UNIQUE_VIOLATION = "23505";
# SQLSTATE for a check violation.
public const string CHECK_VIOLATION = "23514";

# Whether an error is a unique violation, optionally of one named constraint.
#
# + err - Error from the client
# + constraintName - Constraint to match, or `()` for any unique key
# + return - True on a match
public isolated function isUniqueViolation(error err, string? constraintName = ()) returns boolean {
    if err !is sql:DatabaseError {
        return false;
    }
    if err.detail().sqlState != UNIQUE_VIOLATION {
        return false;
    }
    return constraintName is () || err.message().includes(constraintName);
}

# The optimistic-lock failure.
#
# + entity - What was being updated
# + return - `VERSION_CONFLICT`
public isolated function versionConflict(string entity) returns types:DomainError =>
    types:domainError(types:ERR_VERSION_CONFLICT, string `The ${entity} was changed by someone else; reload and retry`);

# Whether a single-row query found nothing.
#
# + err - Error from `queryRow`
# + return - True for `sql:NoRowsError`
public isolated function isNoRows(error err) returns boolean => err is sql:NoRowsError;

# A time as an RFC 3339 UTC string for a bind parameter, used as `CAST(${store:ts(t)} AS timestamptz)`.
# The driver can't bind `time:Utc` directly (UnsupportedOperationException).
#
# + t - Time, or `()`
# + return - RFC 3339 text, or `()`
public isolated function ts(time:Utc? t) returns string? => t is () ? () : time:utcToString(t);
