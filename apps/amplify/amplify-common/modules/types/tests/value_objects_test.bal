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

import ballerina/test;
import ballerina/time;

isolated function codeOf(any|error result) returns string {
    if result is DomainError {
        return result.detail().code;
    }
    return "OK";
}

// ---- EmployeeId ----

@test:Config
function employeeIdAcceptsAsgardeoSub() returns error? {
    test:assertEquals(check parseEmployeeId(" 6f1c2a9e-3b4d-4f60-9a2b-0c1d2e3f4a5b "), "6f1c2a9e-3b4d-4f60-9a2b-0c1d2e3f4a5b");
}

@test:Config
function employeeIdRejectsBlankSpacesAndTooLong() {
    test:assertEquals(codeOf(parseEmployeeId("   ")), ERR_INVALID_EMPLOYEE_ID);
    test:assertEquals(codeOf(parseEmployeeId("a b")), ERR_INVALID_EMPLOYEE_ID);
    string long = "";
    foreach int i in 0 ..< 256 {
        long += "a";
    }
    test:assertEquals(codeOf(parseEmployeeId(long)), ERR_INVALID_EMPLOYEE_ID);
}

@test:Config
function emailIsLowercasedAndChecked() returns error? {
    test:assertEquals(check parseEmail(" Avery.Mock@WSO2.com "), "avery.mock@wso2.com");
    test:assertEquals(codeOf(parseEmail("not-an-email")), ERR_INVALID_EMAIL);
}

// ---- MemberUrn ----

@test:Config
function memberUrnFromSubBuildsPersonUrn() returns error? {
    test:assertEquals(check memberUrnFromSub("782bbtaQ"), "urn:li:person:782bbtaQ");
}

@test:Config
function memberUrnRejectsOtherShapes() {
    test:assertEquals(codeOf(parseMemberUrn("urn:li:organization:1477")), ERR_INVALID_MEMBER_URN);
    test:assertEquals(codeOf(parseMemberUrn("urn:li:person:")), ERR_INVALID_MEMBER_URN);
    test:assertEquals(codeOf(parseMemberUrn("urn:li:person:a b")), ERR_INVALID_MEMBER_URN);
    test:assertEquals(codeOf(memberUrnFromSub("x/y")), ERR_INVALID_MEMBER_URN);
}

// ---- PostUrn ----

@test:Config
function postUrnAcceptsResourceTypes() returns error? {
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:share:7123456789")), SHARE);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:ugcPost:7123456789")), UGC_POST);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:article:99")), ARTICLE);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:video:99")), VIDEO);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:document:99")), DOCUMENT);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:event:99")), EVENT);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:activity:99")), OTHER);
}

@test:Config
function postUrnRejectsPersonAndJunk() {
    test:assertEquals(codeOf(parsePostUrn("urn:li:person:abc")), ERR_INVALID_POST_URN);
    test:assertEquals(codeOf(parsePostUrn("https://www.linkedin.com/feed/update/urn:li:share:1")), ERR_INVALID_POST_URN);
    test:assertEquals(codeOf(parsePostUrn("")), ERR_INVALID_POST_URN);
}

@test:Config
function organizationUrnIsChecked() returns error? {
    test:assertEquals(check parseOrganizationUrn("urn:li:organization:1477"), "urn:li:organization:1477");
    test:assertEquals(codeOf(parseOrganizationUrn("urn:li:person:1477")), ERR_INVALID_POST_URN);
}

// ---- Host literals ----

// One predicate for both callers (evidence URLs, card image hosts): every IP literal form ends in a
// numeric label, and no DNS name does.
@test:Config
function ipLiteralHostsAreDetectedInEveryForm() {
    foreach string host in ["127.0.0.1", "8.8.8.8", "2130706433", "0x7f000001", "0177.0.0.1", "10.1.2.3"] {
        test:assertTrue(isIpLiteralHost(host), host);
    }
    foreach string host in ["example.com", "media.licdn.com", "10.cdn.example.com", "x0x7f.example.com",
            "example.co1", "localhost", ""] {
        test:assertFalse(isIpLiteralHost(host), host);
    }
}

// ---- Time helpers ----

@test:Config
function addDaysAndIsBefore() {
    time:Utc t = [1790000000, 0];
    test:assertEquals(addDays(t, 30)[0], 1790000000 + 30 * 86400);
    test:assertTrue(isBefore(t, addDays(t, 1)));
    test:assertFalse(isBefore(t, t));
}

@test:Config
function sharedKernelHelpers() returns error? {
    test:assertTrue(hasCommentary(REPOST_COMMENTARY));
    test:assertTrue(hasCommentary(SHARE_COMMENTARY));
    test:assertFalse(hasCommentary(REPOST));
    test:assertFalse(hasCommentary(SHARE));
    test:assertEquals(trimToNil(()), ());
    test:assertEquals(trimToNil("  "), ());
    test:assertEquals(trimToNil(" a "), "a");
    DomainError e = domainError(ERR_NOT_FOUND, "Not found");
    test:assertEquals(e.detail().code, ERR_NOT_FOUND);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:video:1")), VIDEO);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:document:1")), DOCUMENT);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:event:1")), EVENT);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:article:1")), ARTICLE);
    test:assertEquals(resourceTypeOf(check parsePostUrn("urn:li:activity:1")), OTHER);
    HealthStatus h = {component: "amplify-api", status: UP};
    test:assertEquals(h.toJson(), {component: "amplify-api", status: "UP"});
}
