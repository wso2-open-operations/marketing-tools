// Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
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

// The Link Me pop-up's consent decision (`connection.linkedin_consent`). "I consent" is recorded when the
// LinkedIn link completes. "I don't consent" stores the LinkedIn profile URL the person typed.

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Longest profile URL stored.
public const int PROFILE_URL_MAX_LENGTH = 255;

# Consent decision values stored in `connection.linkedin_consent.decision`.
public enum ConsentDecision {
    CONSENTED,
    DECLINED
}

# Pattern for a LinkedIn member profile URL: `https://[www.]linkedin.com/in/<slug>[/]`. The slug may hold
# letters, digits, `-`, `_`, `.` and percent-encoded characters (`%` followed by two hex digits, each escape
# counting once toward the 3-100 limit); no query or fragment.
final readonly & string:RegExp PROFILE_URL_PATTERN =
    re `https://(www\.)?linkedin\.com/in/(?:[\p{L}\p{N}_.\-]|%[0-9A-Fa-f]{2}){3,100}/?`;

# Checks a LinkedIn profile URL.
#
# + url - URL as typed (already trimmed)
# + return - True when it is a LinkedIn `/in/` profile URL within the length limit
public isolated function isProfileUrl(string url) returns boolean =>
    url.length() <= PROFILE_URL_MAX_LENGTH && PROFILE_URL_PATTERN.isFullMatch(url);

# Persistence port for `connection.linkedin_consent`.
public type ConsentRepository isolated object {
    # Records the decision, replacing any earlier one for the employee.
    #
    # + employeeId - Signed-in employee
    # + decision - `CONSENTED` or `DECLINED`
    # + profileUrl - Profile URL the person typed, `()` when left blank
    # + now - Current time
    # + return - An error on failure
    public isolated function save(types:EmployeeId employeeId, ConsentDecision decision, string? profileUrl,
            time:Utc now) returns error?;
};

# `ConsentRepository` over PostgreSQL.
public isolated class PgConsentRepository {
    *ConsentRepository;

    private final postgresql:Client db;

    # + db - Shared client (`amplify_api`)
    public isolated function init(postgresql:Client db) {
        self.db = db;
    }

    public isolated function save(types:EmployeeId employeeId, ConsentDecision decision, string? profileUrl,
            time:Utc now) returns error? {
        // Consenting keeps a URL given earlier; declining replaces it.
        _ = check self.db->execute(`
            INSERT INTO connection.linkedin_consent (employee_id, decision, profile_url, decided_at)
            VALUES (${employeeId}, ${decision}, ${profileUrl}, CAST(${store:ts(now)} AS timestamptz))
            ON CONFLICT (employee_id) DO UPDATE
            SET decision = EXCLUDED.decision,
                profile_url = CASE WHEN EXCLUDED.decision = 'DECLINED' THEN EXCLUDED.profile_url
                                   ELSE connection.linkedin_consent.profile_url END,
                decided_at = EXCLUDED.decided_at,
                version = connection.linkedin_consent.version + 1`);
    }
}
