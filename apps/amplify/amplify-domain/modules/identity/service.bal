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

import amplify_common.types;

import ballerina/time;

# Decides which employee a verified sign-in is. The employee id is the key of the ledger, standings, connection
# and audit rows, and those are history that is never rewritten, so a person whose Asgardeo account was
# re-created (new `sub`, same email) keeps their first id and the new `sub` becomes an alias of it.
#
# * `sub` is already an alias: its employee, unless the token's email now belongs to a different employee.
# * `sub` has its own row: itself, unless the token's email belongs to a different employee.
# * `sub` is new and the email belongs to an employee: alias that employee (the re-created account).
# * Otherwise: `sub` itself (a new person).
#
# The clash cases are `EMAIL_CONFLICT`: two employee records that both claim one email cannot be merged by
# guessing, and the answer carries nothing about the other record.
#
# + repo - Employee repository
# + sub - Token `sub`
# + email - Token email
# + return - What to act as, `EMAIL_CONFLICT` for a genuine clash, or an error
public isolated function resolveEmployee(EmployeeRepository repo, string sub, string email)
        returns ResolvedEmployee|types:DomainError|error {
    types:EmployeeId subId = check types:parseEmployeeId(sub);
    string address = check types:parseEmail(email);
    Employee? holder = check repo.findByEmail(address);
    types:EmployeeId? alias = check repo.findAlias(subId);
    if alias is types:EmployeeId {
        return holder is Employee && holder.employeeId != alias ? emailConflict() : {employeeId: alias, aliased: true};
    }
    Employee? own = check repo.findById(subId);
    if own is Employee {
        return holder is Employee && holder.employeeId != subId ? emailConflict() : {employeeId: subId, aliased: false};
    }
    if holder is Employee {
        types:EmployeeId mapped = check repo.addAlias(subId, holder.employeeId);
        return {employeeId: mapped, aliased: mapped != subId};
    }
    return {employeeId: subId, aliased: false};
}

isolated function emailConflict() returns types:DomainError =>
    types:domainError(types:ERR_EMAIL_CONFLICT, "This sign-in can't be matched to an Amplify profile");

# Records an authenticated call: creates the employee on first sight, then refreshes name, email and
# `lastSeenAt`. `firstSeenAt` never moves.
#
# + existing - Stored employee, if any
# + claims - Token claims
# + now - Current time
# + return - The employee to upsert, or a value-object error
public isolated function recordSeen(Employee? existing, TokenClaims claims, time:Utc now) returns Employee|types:DomainError {
    types:EmployeeId employeeId = check types:parseEmployeeId(claims.sub);
    string email = check types:parseEmail(claims.email);
    string displayName = types:trimToNil(claims.name) ?: re `@`.split(email)[0];
    return {
        employeeId,
        email,
        displayName,
        firstSeenAt: existing is () ? now : existing.firstSeenAt,
        lastSeenAt: now
    };
}
