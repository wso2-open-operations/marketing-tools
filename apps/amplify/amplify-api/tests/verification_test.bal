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

// Pre-coin verification (V027) on the published API: the PO settles a row (`POST /po/points/{reference}/settlement`),
// lists what waits for the PO team (`GET /po/points/action-required`), sees the verification on ledger rows, and the two
// new settings.

import amplify_common.types;
import amplify_domain.scoring;
import amplify_domain.store;

import ballerina/http;
import ballerina/test;

@test:Mock {functionName: "actionRequiredRows"}
isolated function mockActionRequiredRows(int page, int size) returns scoring:LedgerPage|error {
    check dbGate();
    types:LedgerEntry flagged = {
        reference: "AMP-unverifiable-1", employeeId: "emp-flag-1", campaignId: "c-1", sourceType: types:ENGAGEMENT,
        sourceId: "0190a1b2-0000-7000-8000-000000000001", action: types:REACTION, points: 1, ruleId: "r-1",
        reversesReference: (), reason: (), actorId: types:SYSTEM_ACTOR, correlationId: (), createdAt: [1796086800, 0],
        status: (), statusChangedAt: [1796086800, 0], paidAt: (), coinReference: (), verification: types:UNVERIFIABLE,
        verifiedAt: [1796086800, 0], verificationReason: "NO_TOKEN"
    };
    return {items: [flagged], total: 1};
}

@test:Config
function testPoSettlesAnActionRequiredRow() returns error? {
    _ = check send("GET", "/me", (), check employee("emp-settle-1"));
    string token = check po();
    http:Response adjusted = check send("POST", "/po/points/adjustments",
            {employeeId: "emp-settle-1", points: 10, reason: "Event bonus"}, token);
    test:assertEquals(adjusted.statusCode, 201);
    string reference = (check (check adjusted.getJsonPayload()).reference).toString();

    http:Response held = check send("POST", string `/po/points/${reference}/settlement`, {status: "ACTION_REQUIRED"},
            token);
    test:assertEquals(held.statusCode, 200);
    check assertShape(held, "LedgerEntry");
    test:assertEquals(check (check held.getJsonPayload()).status, ());

    http:Response cleared = check send("POST", string `/po/points/${reference}/settlement`, {status: "HELD"}, token,
            {"Idempotency-Key": "settle-1"});
    test:assertEquals(cleared.statusCode, 200);
    check assertShape(cleared, "LedgerEntry");
    json body = check cleared.getJsonPayload();
    test:assertEquals(check body.status, "HELD");
    test:assertEquals(check body.verification, "PO_CLEARED", "converts without another LinkedIn check");

    http:Response bad = check send("POST", string `/po/points/${reference}/settlement`, {status: "PAID"}, token);
    test:assertEquals([bad.statusCode, check codeIn(bad)], [422, "VALIDATION_FAILED"]);
    http:Response badRef = check send("POST", "/po/points/not-a-reference/settlement", {status: "HELD"}, token);
    test:assertEquals(check codeIn(badRef), "INVALID_LEDGER_REFERENCE");
    http:Response asEmployee = check send("POST", string `/po/points/${reference}/settlement`, {status: "HELD"},
            check employee("emp-settle-2"));
    test:assertEquals(asEmployee.statusCode, 403);

    // A PO can't clear their own points.
    types:LedgerEntry own = check (check fakeLedger.findByReference(reference)).ensureType();
    own.reference = "ADJ-01900000-0000-7000-8000-00000000abcd";
    own.employeeId = "po-0001";
    _ = check fakeLedger.append({entry: own, event: scoring:pointsChangedEvent(own)});
    http:Response self = check send("POST", "/po/points/ADJ-01900000-0000-7000-8000-00000000abcd/settlement", {status: "HELD"}, token);
    test:assertEquals([self.statusCode, check codeIn(self)], [403, "SELF_REVIEW"]);
}

@test:Config
function testPoListsActionRequiredRows() returns error? {
    string token = check po();
    http:Response res = check send("GET", "/po/points/action-required?page=0&size=10", (), token);
    test:assertEquals(res.statusCode, 200);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.total, 1);
    json item = (<json[]>check body.items)[0];
    test:assertEquals(check item.settlement, "ACTION_REQUIRED");
    test:assertEquals(check item.verification, "UNVERIFIABLE");
    test:assertEquals(check item.verificationReason, "NO_TOKEN");
    test:assertEquals(check item.employeeName, "Name emp-flag-1");
    test:assertEquals(check item.campaignTitle, "Title of c-1");

    http:Response badPage = check send("GET", "/po/points/action-required?size=0", (), token);
    test:assertEquals(badPage.statusCode, 400);
    http:Response asEmployee = check send("GET", "/po/points/action-required", (), check employee("emp-settle-3"));
    test:assertEquals(asEmployee.statusCode, 403);
}

@test:Config
function testVerificationSettings() {
    test:assertEquals(checkSettingChange("coin.verify_max_age_hours", 48), ());
    test:assertTrue(checkSettingChange("coin.verify_max_age_hours", 1) is [string, string],
            "at least 2: the verification runs an hour before the conversion");
    test:assertEquals(checkSettingChange("coin.verify_member_daily_call_budget", 0), ());
    test:assertTrue(checkSettingChange("coin.verify_member_daily_call_budget", -1) is [string, string]);
    test:assertTrue(isVisibleSetting("coin.verify_max_age_hours"));
    test:assertTrue(PO_SETTINGS.indexOf("coin.verify_max_age_hours") is (), "admins change it");
    Settings s = settingsOf([
        {key: "coin.verify_max_age_hours", value: 72, updatedBy: "a", updatedAt: [0, 0], version: 1},
        {key: "coin.verify_member_daily_call_budget", value: "x", updatedBy: "a", updatedAt: [0, 0], version: 1}
    ]);
    test:assertEquals([s.coinVerifyMaxAgeHours, s.coinVerifyMemberBudget], [72, 1000]);
    store:Setting[] none = [];
    test:assertEquals(settingsOf(none).coinVerifyMaxAgeHours, 48);
}
