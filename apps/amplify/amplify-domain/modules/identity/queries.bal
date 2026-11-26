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

// Read models over `identity_employee` (no writes).

import amplify_common.types;

import ballerina/sql;
import ballerinax/postgresql;

# Shortest search text `searchEmployees` accepts.
public const int SEARCH_MIN_LENGTH = 2;
# Most people one search returns.
public const int SEARCH_MAX_RESULTS = 20;

# One person a search found.
public type EmployeeMatch record {|
    # Employee id (pseudonymous)
    types:EmployeeId employeeId;
    # Name from the last sign-in
    string displayName;
    # Work email
    string email;
|};

# People who have used Amplify whose name or work email contains `text` (case-insensitive), for the PO team's
# Points & corrections screen. Erased employees are left out. `%`, `_` and `\` in the text match themselves.
#
# + db - Client
# + text - What to look for; trimmed, at least `SEARCH_MIN_LENGTH` characters
# + 'limit - Most results, 1 to `SEARCH_MAX_RESULTS`
# + return - The matches, by name, or an error
public isolated function searchEmployees(postgresql:Client db, string text, int 'limit = 10) returns EmployeeMatch[]|error {
    string trimmed = text.trim();
    if trimmed.length() < SEARCH_MIN_LENGTH {
        return [];
    }
    int capped = 'limit < 1 ? 1 : 'limit > SEARCH_MAX_RESULTS ? SEARCH_MAX_RESULTS : 'limit;
    string pattern = "%" + likeEscape(trimmed) + "%";
    stream<EmployeeMatch, error?> rows = db->query(`
        SELECT employee_id AS "employeeId", display_name AS "displayName", email::text AS email
        FROM identity_employee
        WHERE email::text NOT LIKE 'erased-%@amplify.invalid'
          AND (email::text ILIKE ${pattern} ESCAPE '\' OR display_name ILIKE ${pattern} ESCAPE '\')
        ORDER BY display_name, employee_id
        LIMIT ${capped}`);
    return from EmployeeMatch m in rows select m;
}

# Escapes the LIKE wildcards so they match literally (escape character `\`).
#
# + text - Raw text
# + return - The escaped text
isolated function likeEscape(string text) returns string {
    string escaped = "";
    foreach string:Char c in text {
        if c == "\\" || c == "%" || c == "_" {
            escaped += "\\";
        }
        escaped += c;
    }
    return escaped;
}

# Names and work emails of these employees (the PO review queue shows who sent each claim). Erased employees come
# back with their placeholder name and email, as stored.
#
# + db - Client
# + ids - Employee ids
# + return - Id -> match, or an error
public isolated function employeesByIds(postgresql:Client db, types:EmployeeId[] ids) returns map<EmployeeMatch>|error {
    map<EmployeeMatch> found = {};
    if ids.length() == 0 {
        return found;
    }
    stream<EmployeeMatch, error?> rows = db->query(sql:queryConcat(`
        SELECT employee_id AS "employeeId", display_name AS "displayName", email::text AS email
        FROM identity_employee WHERE employee_id IN (`, sql:arrayFlattenQuery(ids), `)`));
    check from EmployeeMatch m in rows
        do {
            found[m.employeeId] = m;
        };
    return found;
}
