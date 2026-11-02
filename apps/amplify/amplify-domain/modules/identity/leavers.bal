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

// Leavers: employees Amplify still holds data for who are no longer in the people directory (security review,
// "automated leaver offboarding"). Finding them is a read; erasing one is `identity.erase_employee` (V018).

import amplify_domain.store;

import ballerina/lang.value;
import ballerinax/postgresql;

# Employees who look like leavers: not in the directory, not seen in Amplify for `graceDays`, and not erased already.
# Absent from the directory alone is not enough: a directory that is briefly wrong would otherwise erase active people,
# so the person must also have been away from Amplify for the grace period.
#
# + db - Client
# + directoryEmails - Work emails of everyone the directory lists today (any case)
# + graceDays - Days since the person last used Amplify
# + limit - Most rows returned (callers stop when it is exceeded)
# + return - Employee ids (the pseudonymous `sub`, never emails), oldest activity first, or an error
public isolated function leaverCandidates(postgresql:Client db, string[] directoryEmails, int graceDays, int 'limit)
        returns string[]|error {
    // Compared in lower case on both sides, so a directory that writes `Ada@WSO2.com` still matches.
    string listed = store:arrayLiteral(from string e in directoryEmails select e.trim().toLowerAscii());
    stream<record {|string employee_id;|}, error?> rows = db->query(`
        SELECT employee_id FROM identity.employee
        WHERE last_seen_at < now() - (CAST(${graceDays} AS int) * interval '1 day')
          AND email::text NOT LIKE 'erased-%@amplify.invalid'
          AND lower(email::text) <> ALL (CAST(${listed} AS text[]))
        ORDER BY last_seen_at, employee_id
        LIMIT ${'limit}`);
    return from var r in rows
        select r.employee_id;
}

# How many employees Amplify holds data for (erased ones excluded): the base for the leaver percentage cap.
#
# + db - Client
# + return - Count, or an error
public isolated function countEmployees(postgresql:Client db) returns int|error {
    int total = check db->queryRow(`SELECT count(*)::int FROM identity.employee
        WHERE email::text NOT LIKE 'erased-%@amplify.invalid'`);
    return total;
}

# Erases one employee's personal data with `identity.erase_employee`, which audits the call and keeps the ledger.
#
# + db - Client connected as a role allowed to execute it (`amplify_jobs`)
# + employeeId - Employee id
# + actor - Who is erasing (`system` for the sweep)
# + reason - Audit reason, for example `LEAVER_SWEEP`
# + return - What was removed, as the function returns it, or an error
public isolated function eraseEmployee(postgresql:Client db, string employeeId, string actor, string reason)
        returns json|error {
    string result = check db->queryRow(`SELECT identity.erase_employee(${employeeId}, ${actor}, ${reason})::text`);
    return value:fromJsonString(result);
}
