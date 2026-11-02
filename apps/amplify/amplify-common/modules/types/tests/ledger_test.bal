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

@test:Config
function awardReferenceIsDeterministicAnd47Chars() returns error? {
    LedgerReference a = check awardReference(LINKEDIN, "urn:li:share:7123", "emp-1", REPOST);
    LedgerReference b = check awardReference(LINKEDIN, "urn:li:share:7123", "emp-1", REPOST);
    test:assertEquals(a, b);
    test:assertEquals(a.length(), AWARD_REFERENCE_LENGTH);
    test:assertTrue(a.length() <= LEDGER_REFERENCE_MAX_LENGTH, "must fit varchar(66) (C1)");
    test:assertTrue(a.startsWith(AWARD_PREFIX));
    test:assertTrue(re `AMP-[A-Za-z0-9_\-]{43}`.isFullMatch(a), "unpadded base64url");
    test:assertEquals(check parseLedgerReference(a), a);
}

@test:Config
function awardReferenceKnownValue() returns error? {
    // sha256("linkedin\nurn:li:share:7123\nemp-1\nREPOST"), base64url. Pins the encoding (C1).
    LedgerReference ref = check awardReference(LINKEDIN, "urn:li:share:7123", "emp-1", REPOST);
    test:assertEquals(ref, "AMP-Ru5fAN_wZQZFyfk8VGyAu5XemwHRPVar_8y-dOgG3Dg");
}

@test:Config
function awardReferenceDiffersPerPart() returns error? {
    LedgerReference base = check awardReference(LINKEDIN, "urn:li:share:1", "emp-1", REPOST);
    test:assertNotEquals(check awardReference(LINKEDIN, "urn:li:share:2", "emp-1", REPOST), base);
    test:assertNotEquals(check awardReference(LINKEDIN, "urn:li:share:1", "emp-2", REPOST), base);
    test:assertNotEquals(check awardReference(LINKEDIN, "urn:li:share:1", "emp-1", REPOST_COMMENTARY), base);
    test:assertNotEquals(check awardReference("other", "https://x.com/a", "emp-1", OWN_POST),
            check awardReference("other", "https://x.com/a", "emp-1", OWN_POST_AMPLIFIED), "T4 top-up has its own key");
}

@test:Config
function awardReferenceRejectsBlankAndLineFeedParts() {
    test:assertEquals(codeOf(awardReference(LINKEDIN, " ", "emp-1", REPOST)), ERR_INVALID_LEDGER_REFERENCE);
    test:assertEquals(codeOf(awardReference(LINKEDIN, "a\nb", "emp-1", REPOST)), ERR_INVALID_LEDGER_REFERENCE);
}

// Regression (deep review RC-07): ` emp-1` passed the blank check but hashed to a different reference than
// `emp-1`, so one action could earn twice if a caller forgot to trim.
@test:Config
function awardReferenceRejectsUntrimmedParts() {
    foreach [string, string, string] [provider, target, employee] in [[" linkedin", "urn:li:share:1", "emp-1"],
            [LINKEDIN, "urn:li:share:1 ", "emp-1"], [LINKEDIN, "urn:li:share:1", "emp-1\t"]] {
        test:assertEquals(codeOf(awardReference(provider, target, employee, REPOST)), ERR_INVALID_LEDGER_REFERENCE);
    }
}

@test:Config
function adjustmentAndReversalReferencesUseUuidV7() returns error? {
    string id = newUuidV7();
    LedgerReference adj = check adjustmentReference(id);
    LedgerReference rev = check reversalReference(id);
    test:assertEquals(adj, "ADJ-" + id);
    test:assertEquals(rev, "REV-" + id);
    test:assertEquals(adj.length(), 40);
    test:assertEquals(check parseLedgerReference(rev), rev);
    test:assertEquals(codeOf(adjustmentReference("6f1c2a9e-3b4d-4f60-9a2b-0c1d2e3f4a5b")), ERR_INVALID_UUID, "v4 refused");
}

@test:Config
function parseLedgerReferenceRejectsJunk() {
    test:assertEquals(codeOf(parseLedgerReference("AMP-short")), ERR_INVALID_LEDGER_REFERENCE);
    test:assertEquals(codeOf(parseLedgerReference("XYZ-" + newUuidV7())), ERR_INVALID_LEDGER_REFERENCE);
}

@test:Config
function uuidV7IsTimeOrderedAndValid() returns error? {
    string first = newUuidV7();
    string second = newUuidV7();
    test:assertEquals(check parseUuidV7(first), first);
    test:assertTrue(first.substring(0, 13) <= second.substring(0, 13), "timestamp prefix is monotonic");
    test:assertNotEquals(first, second);
}

@test:Config
function base64UrlHasNoPaddingOrUnsafeChars() {
    test:assertEquals(toBase64Url([0xfb, 0xff]), "-_8");
}
