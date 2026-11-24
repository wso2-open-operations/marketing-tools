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

// Who an employee can mention on LinkedIn: colleagues who linked LinkedIn in Amplify (Amplify holds their
// member URN). LinkedIn's own member search (peopleTypeahead) is restricted and only finds followers of an
// organization the caller administers, so it isn't used. Read models: they join the directory name from
// `identity_employee` like the recognition and reporting reads do, and never change a row.

import amplify_common.types;
import amplify_domain.store;

import ballerina/lang.regexp;
import ballerinax/postgresql;

# Most typeahead suggestions returned.
public const int MENTION_SUGGESTION_LIMIT = 10;

# A colleague who can be mentioned.
public type MentionableMember record {|
    # Employee
    types:EmployeeId employeeId;
    # LinkedIn member URN
    types:MemberUrn memberUrn;
    # Name from the directory (`identity_employee.display_name`), for the typeahead
    string displayName;
    # Name from LinkedIn at the last connect, for the mention text; `()` for older connections
    string? memberName;
|};

type MentionableRow record {|
    string employee_id;
    string member_urn;
    string display_name;
    string? member_name;
|};

# Typeahead: linked colleagues whose directory name contains `query` (case-insensitive), the caller excluded.
# Only the directory name is matched, so a search can't be used to probe the LinkedIn names Amplify holds. A
# removed or revoked connection is left out: only a member whose link is still good can be mentioned. Rows whose
# only name is an id are left out (never show an id as a name).
#
# + db - Client
# + query - Text after `@`
# + callerId - Signed-in employee, never suggested
# + 'limit - Most rows
# + return - Members, best match first, or an error
public isolated function searchMentionable(postgresql:Client db, string query, types:EmployeeId callerId,
        int 'limit = MENTION_SUGGESTION_LIMIT) returns MentionableMember[]|error {
    string pattern = "%" + likeEscape(query.trim().toLowerAscii()) + "%";
    string prefix = likeEscape(query.trim().toLowerAscii()) + "%";
    stream<MentionableRow, error?> rows = db->query(`
        SELECT mc.employee_id, mc.member_urn, e.display_name, mc.member_name
        FROM connection_member_connection mc
        JOIN identity_employee e ON e.employee_id = mc.employee_id
        WHERE mc.provider = ${types:LINKEDIN} AND mc.removed_at IS NULL AND mc.revoked_at IS NULL
          AND mc.employee_id <> ${callerId}
          AND e.display_name <> e.employee_id
          AND e.display_name !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          AND lower(e.display_name) LIKE ${pattern} ESCAPE '\'
        ORDER BY (lower(e.display_name) LIKE ${prefix} ESCAPE '\') DESC, e.display_name, mc.employee_id
        LIMIT ${'limit < 1 ? 1 : 'limit}`);
    return from MentionableRow r in rows select toMentionable(r);
}

# The linked colleagues behind mention refs, for writing the post. Removed and revoked connections are left
# out, so their tokens are written as plain text.
#
# + db - Client
# + employeeIds - Employees named in the commentary's mention tokens
# + return - Members found (fewer when some aren't linked), or an error
public isolated function mentionableByIds(postgresql:Client db, types:EmployeeId[] employeeIds)
        returns MentionableMember[]|error {
    if employeeIds.length() == 0 {
        return [];
    }
    string ids = store:arrayLiteral(employeeIds);
    stream<MentionableRow, error?> rows = db->query(`
        SELECT mc.employee_id, mc.member_urn, coalesce(e.display_name, '') AS display_name, mc.member_name
        FROM connection_member_connection mc
        LEFT JOIN identity_employee e ON e.employee_id = mc.employee_id
        WHERE mc.provider = ${types:LINKEDIN} AND mc.removed_at IS NULL AND mc.revoked_at IS NULL
          AND mc.employee_id = ANY (CAST(${ids} AS text[]))`);
    return from MentionableRow r in rows select toMentionable(r);
}

# The text LinkedIn should link for a member: the LinkedIn name when Amplify has it, else the directory name.
# LinkedIn links a member mention when the text matches one of the member's names, else shows plain text.
#
# + member - Member
# + return - Mention text, or `()` when there is no usable name
public isolated function mentionName(MentionableMember member) returns string? =>
    types:trimToNil(member.memberName) ?: types:trimToNil(member.displayName);

isolated function toMentionable(MentionableRow r) returns MentionableMember => {
    employeeId: r.employee_id,
    memberUrn: r.member_urn,
    displayName: r.display_name,
    memberName: r.member_name
};

isolated function likeEscape(string text) returns string =>
    re `[\\%_]`.replaceAll(text, isolated function(regexp:Groups groups) returns string => "\\" + groups[0].substring());
