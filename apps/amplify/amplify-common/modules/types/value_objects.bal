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

// Value objects. Each is a string alias plus a `parse*` function; build them only through the parser
// so every value in an aggregate has passed validation.

# Employee identifier: the Asgardeo `sub` claim.
public type EmployeeId string;

# LinkedIn member URN, `urn:li:person:{sub}` (B13).
public type MemberUrn string;

# LinkedIn post or other resource URN, for example `urn:li:share:7123` or `urn:li:ugcPost:7123`.
public type PostUrn string;

# LinkedIn organization URN, for example `urn:li:organization:1477`.
public type OrganizationUrn string;

# Longest employee id accepted.
public const int EMPLOYEE_ID_MAX_LENGTH = 255;
# Longest URN accepted.
public const int URN_MAX_LENGTH = 255;
# Longest email accepted.
public const int EMAIL_MAX_LENGTH = 320;

const string MEMBER_URN_PREFIX = "urn:li:person:";

# Parses an employee id (IdP `sub`).
#
# + raw - Value from the access token
# + return - The id, or `INVALID_EMPLOYEE_ID`
public isolated function parseEmployeeId(string raw) returns EmployeeId|DomainError {
    string value = raw.trim();
    if value.length() == 0 || value.length() > EMPLOYEE_ID_MAX_LENGTH
            || !re `[A-Za-z0-9._@:|+\-]+`.isFullMatch(value) {
        return domainError(ERR_INVALID_EMPLOYEE_ID, "Employee id must be 1-255 characters with no spaces");
    }
    return value;
}

# Parses an email address (light check; the IdP owns the real validation).
#
# + raw - Email from the token
# + return - Lowercased email, or `INVALID_EMAIL`
public isolated function parseEmail(string raw) returns string|DomainError {
    string value = raw.trim().toLowerAscii();
    if value.length() > EMAIL_MAX_LENGTH || !re `[^@\s]+@[^@\s]+\.[^@\s]+`.isFullMatch(value) {
        return domainError(ERR_INVALID_EMAIL, "Email address is not valid");
    }
    return value;
}

# Parses a LinkedIn member URN.
#
# + raw - URN, `urn:li:person:{id}`
# + return - The URN, or `INVALID_MEMBER_URN`
public isolated function parseMemberUrn(string raw) returns MemberUrn|DomainError {
    string value = raw.trim();
    if value.length() > URN_MAX_LENGTH || !re `urn:li:person:[A-Za-z0-9_\-]{1,100}`.isFullMatch(value) {
        return domainError(ERR_INVALID_MEMBER_URN, "Member URN must look like urn:li:person:{id}");
    }
    return value;
}

# Builds the member URN from the OIDC `sub` claim (B13).
#
# + sub - LinkedIn `sub` claim
# + return - `urn:li:person:{sub}`, or `INVALID_MEMBER_URN`
public isolated function memberUrnFromSub(string sub) returns MemberUrn|DomainError =>
    parseMemberUrn(MEMBER_URN_PREFIX + sub.trim());

# Parses a LinkedIn resource URN a campaign or engagement points at.
#
# + raw - URN such as `urn:li:share:7123`
# + return - The URN, or `INVALID_POST_URN`
public isolated function parsePostUrn(string raw) returns PostUrn|DomainError {
    string value = raw.trim();
    if value.length() > URN_MAX_LENGTH
            || !re `urn:li:(share|ugcPost|article|video|document|event|activity):[A-Za-z0-9_\-]{1,100}`.isFullMatch(value) {
        return domainError(ERR_INVALID_POST_URN,
                "Post URN must look like urn:li:share:{id} or urn:li:ugcPost:{id}");
    }
    return value;
}

# Parses a LinkedIn organization URN.
#
# + raw - URN, `urn:li:organization:{id}`
# + return - The URN, or `INVALID_POST_URN`
public isolated function parseOrganizationUrn(string raw) returns OrganizationUrn|DomainError {
    string value = raw.trim();
    if !re `urn:li:organization:[0-9A-Za-z_\-]{1,100}`.isFullMatch(value) {
        return domainError(ERR_INVALID_POST_URN, "Organization URN must look like urn:li:organization:{id}");
    }
    return value;
}

# Resource type named by a post URN.
#
# + urn - A parsed post URN
# + return - The resource type (`OTHER` for activity URNs)
public isolated function resourceTypeOf(PostUrn urn) returns ResourceType {
    string kind = re `:`.split(urn)[2];
    match kind {
        "share" => {
            return SHARE;
        }
        "ugcPost" => {
            return UGC_POST;
        }
        "article" => {
            return ARTICLE;
        }
        "video" => {
            return VIDEO;
        }
        "document" => {
            return DOCUMENT;
        }
        "event" => {
            return EVENT;
        }
    }
    return OTHER;
}

# Whether a URL is absolute HTTPS (for image and resource links on a campaign, never fetched by Amplify).
#
# + url - URL to check
# + return - True when it starts with `https://` and has no whitespace
public isolated function isHttpsUrl(string url) returns boolean =>
    url.toLowerAscii().startsWith("https://") && url.length() <= EVIDENCE_URL_MAX_LENGTH
        && re `\S+`.isFullMatch(url) && url.length() > 8;

# Whether a host is an IP literal in any numeric form: dotted, decimal (`2130706433`), hex
# (`0x7f000001`) or octal (`0177.0.0.1`). Every such form ends in an all-numeric label, which a DNS
# name never does. Shared so evidence URLs and card image hosts reject the same set (one regex, no drift).
#
# + host - Lowercased host, without user info, port or trailing dot
# + return - True when the host is an IP literal
public isolated function isIpLiteralHost(string host) returns boolean {
    string[] labels = re `\.`.split(host);
    return re `[0-9]+|0x[0-9a-f]+`.isFullMatch(labels[labels.length() - 1]);
}
