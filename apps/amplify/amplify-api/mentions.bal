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

// `GET /mentions`: who the caller can `@` mention in a repost's thoughts. Colleagues who linked LinkedIn in
// Amplify (Amplify holds their member URN) and the company page. LinkedIn's member search (peopleTypeahead) is
// restricted to approved partners and only finds followers of a page the caller administers, and its
// organization lookup needs `rw_organization_admin`, so neither is used. The ref goes back in the commentary
// token `@[label](amplify:<ref>)`; amplify-jobs looks it up again before posting.

import amplify_api.auth;
import amplify_common.types;
import amplify_domain.connection;

# The company page's full LinkedIn name, suggested for `@` mentions as `org:wso2`. LinkedIn links an
# organization mention only when the text is the full name, case sensitive. Empty = not suggested.
configurable string wso2OrganizationName = "WSO2";

# Longest `q` accepted.
const int MENTION_QUERY_MAX_LENGTH = 50;
# Mention ref of the company page; amplify-jobs resolves the same ref from its `linkedinOrgUrn`.
const string ORG_MENTION_REF = "org:wso2";

# One suggestion.
type MentionDto record {|
    # `person:<employeeId>` or `org:<key>`, the ref the commentary token carries
    string ref;
    # `PERSON` or `ORGANIZATION`
    string kind;
    # Name to show and to put after `@`; never an id
    string displayName;
|};

# Suggestions for `@<q>`.
#
# + p - Caller
# + correlationId - Correlation id
# + q - Text typed after `@`
# + return - `{items}`, or problem details
isolated function mentionSuggestions(auth:Principal p, string? correlationId, string? q) returns json|ProblemResponse {
    string query = (q ?: "").trim();
    if query.length() < 1 || query.length() > MENTION_QUERY_MAX_LENGTH {
        return badRequest(string `q must be 1-${MENTION_QUERY_MAX_LENGTH} characters`, correlationId);
    }
    connection:MentionableMember[]|error members = mentionableSearch(query, p.employeeId);
    if members is error {
        return failure(members, correlationId, "Mention suggestions");
    }
    MentionDto[] items = [];
    string orgName = wso2OrganizationName.trim();
    if orgName != "" && wso2OrganizationUrn.trim() != "" && orgName.toLowerAscii().includes(query.toLowerAscii()) {
        items.push({ref: ORG_MENTION_REF, kind: "ORGANIZATION", displayName: orgName});
    }
    foreach connection:MentionableMember m in members {
        if items.length() >= connection:MENTION_SUGGESTION_LIMIT {
            break;
        }
        // The directory name is what colleagues know; the query already left out rows whose name is an id.
        items.push({ref: types:MENTION_PERSON + ":" + m.employeeId, kind: "PERSON", displayName: m.displayName});
    }
    return {items: items.toJson()};
}
