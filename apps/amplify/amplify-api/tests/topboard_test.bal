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

// The Celebrate top board: the monthly totals are read once and shared until points change, and the scope setting.

import amplify_domain.recognition;

import ballerina/http;
import ballerina/test;
import ballerina/time;

final time:Utc THURSDAY = checkpanic time:utcFromString("2026-10-22T16:00:00Z");

function total(string employeeId, int points) returns recognition:EmployeeTotal =>
    {employeeId, displayName: "Person " + employeeId, email: employeeId + "@wso2.com", totalPoints: points, lastActivityAt: ()};

# Totals cached `ageSeconds` ago at standing version `version`, with e1 on 9 points.
function seedMonth(time:Utc now, decimal ageSeconds, int? version) {
    lock {
        monthlyCache = {
            monthStart: recognition:monthStartOf(now),
            totals: [{employeeId: "e1", displayName: "Avery", email: "a@wso2.com", totalPoints: 9, lastActivityAt: ()}],
            loadedAt: now,
            readAt: time:monotonicNow() - ageSeconds,
            version: version
        };
    }
}

// The month's ledger as the database would sum it. `()` = no database, so the read fails.
isolated recognition:EmployeeTotal[]? fakeMonthTotals = ();
isolated int monthReads = 0;

function setMonthTotals(recognition:EmployeeTotal[]? totals) {
    lock {
        fakeMonthTotals = totals.clone();
    }
}

# Ledger reads since the last call.
function takeMonthReads() returns int {
    lock {
        int n = monthReads;
        monthReads = 0;
        return n;
    }
}

@test:Mock {functionName: "monthlyTotalsRead"}
isolated function mockMonthlyTotalsRead(time:Utc monthStart) returns recognition:EmployeeTotal[]|error {
    lock {
        monthReads += 1;
    }
    lock {
        recognition:EmployeeTotal[]? totals = fakeMonthTotals;
        if totals is () {
            return error("no database in this test");
        }
        return totals.clone();
    }
}

@test:Config
function testFreshMonthlyTotalsAreReusedWithoutAnotherRead() returns error? {
    _ = takeMonthReads();
    seedMonth(THURSDAY, 60, currentStandingVersion());
    MonthlyTotals first = check monthlyTotals(THURSDAY);
    MonthlyTotals second = check monthlyTotals(THURSDAY);
    test:assertEquals(first.loadedAt, THURSDAY);
    test:assertEquals(second.totals, first.totals);
    test:assertEquals(monthlyCacheSize(), 1);
    test:assertEquals(takeMonthReads(), 0, "no points changed: no ledger read");
    dropMonthlyCache();
}

// Staging, 5 Nov: a repost at 08:41 UTC stayed off the podium (9 points shown, 11 earned) until the 2 hour
// lifetime ran out. A points change now reloads the totals on the next request.
@test:Config
function testAPointsChangeReloadsTheTotalsAtOnce() returns error? {
    _ = takeMonthReads();
    seedMonth(THURSDAY, 60, currentStandingVersion());
    setMonthTotals([total("e1", 11)]);
    bumpStandingVersion();
    MonthlyTotals after = check monthlyTotals(THURSDAY);
    MonthlyTotals again = check monthlyTotals(THURSDAY);
    setMonthTotals(());
    dropMonthlyCache();
    test:assertEquals(after.totals[0].totalPoints, 11, "the new points count at once");
    test:assertEquals(after.version, currentStandingVersion());
    test:assertEquals(again.totals[0].totalPoints, 11);
    test:assertEquals(takeMonthReads(), 1, "one read for the change, then reused");
}

@test:Config
function testAPointsChangeWhoseReloadFailsServesThePreviousTotals() returns error? {
    seedMonth(THURSDAY, 60, currentStandingVersion());
    bumpStandingVersion();
    MonthlyTotals served = check monthlyTotals(THURSDAY);
    dropMonthlyCache();
    test:assertEquals(served.totals[0].totalPoints, 9, "no database: the page keeps the previous totals");
}

@test:Config
function testAnUnreadableVersionFallsBackToTheLifetime() returns error? {
    _ = takeMonthReads();
    setStandingVersionFails(true);
    seedMonth(THURSDAY, 60, currentStandingVersion() - 1);
    _ = check monthlyTotals(THURSDAY);
    int whileYoung = takeMonthReads();
    seedMonth(THURSDAY, topBoardCacheSeconds + 1d, currentStandingVersion() - 1);
    setMonthTotals([total("e1", 11)]);
    MonthlyTotals reloaded = check monthlyTotals(THURSDAY);
    setStandingVersionFails(false);
    setMonthTotals(());
    dropMonthlyCache();
    test:assertEquals(whileYoung, 0, "version unknown and the totals are young: reused, as before");
    test:assertEquals(takeMonthReads(), 1, "past the lifetime: read again");
    test:assertEquals(reloaded.version, (), "stored without a version, so the next readable one reloads");
}

@test:Config
function testExpiredTotalsOfTheSameMonthAreServedWhenTheReloadFails() returns error? {
    // Older than the 2 hour lifetime, and no database in this test: the previous totals carry on.
    seedMonth(THURSDAY, topBoardCacheSeconds + 1d, currentStandingVersion());
    MonthlyTotals served = check monthlyTotals(THURSDAY);
    test:assertEquals(served.totals.length(), 1);
    dropMonthlyCache();
}

// The browser asks every time (`no-cache`), and the answer counts a repost made since the last one.
@test:Config {groups: ["reads"]}
function testTheTopBoardIsAskedForEachTimeAndShowsANewRepostAtOnce() returns error? {
    dropMonthlyCache();
    clearSettings();
    string token = check rvToken("rv-top");
    setMonthTotals([total("rv-top", 9), total("rv-other", 6)]);
    http:Response first = check send("GET", "/leaderboard/top", (), token);
    setMonthTotals([total("rv-top", 11), total("rv-other", 6)]);
    bumpStandingVersion();
    http:Response second = check send("GET", "/leaderboard/top", (), token);
    setMonthTotals(());
    dropMonthlyCache();
    test:assertEquals(first.statusCode, 200);
    test:assertEquals(header(first, "Cache-Control"), "private, no-cache");
    test:assertEquals(check (check first.getJsonPayload()).me.points, 9);
    test:assertEquals(second.statusCode, 200);
    test:assertEquals(check (check second.getJsonPayload()).me.points, 11, "the new points show on the next request");
}

// Three people tied on points: the one who got there first is first. Only dashboard readers see the times.
@test:Config {groups: ["reads"]}
function testTiedTopBoardOrdersByWhoReachedThePointsFirstAndShowsTheTimeOnlyToDashboardReaders() returns error? {
    dropMonthlyCache();
    clearSettings();
    function (string, string, int, string) returns recognition:EmployeeTotal at =
        (id, name, points, when) => {employeeId: id, displayName: name, email: id + "@wso2.com", totalPoints: points,
            lastActivityAt: checkpanic time:utcFromString(when)};
    setMonthTotals([
        at("tie-a", "Avery", 45, "2026-10-20T09:00:00Z"),
        at("tie-b", "Blake", 45, "2026-10-20T08:00:00Z"),
        at("tie-c", "Casey", 45, "2026-10-20T07:00:00Z")
    ]);
    http:Response po = check send("GET", "/leaderboard/top", (), check rvToken("tie-po", groups = ["amplify_po"]));
    http:Response employee = check send("GET", "/leaderboard/top", (), check rvToken("tie-emp"));
    json poBody = check po.getJsonPayload();
    json empBody = check employee.getJsonPayload();
    setMonthTotals(());
    dropMonthlyCache();
    json[] poList = check (check poBody.company).ensureType();
    json[] empList = check (check empBody.company).ensureType();
    test:assertEquals(from json e in poList select (<map<json>>e)["employeeId"].toString(), ["tie-c", "tie-b", "tie-a"]);
    test:assertEquals(from json e in empList select (<map<json>>e)["employeeId"].toString(), ["tie-c", "tie-b", "tie-a"]);
    test:assertEquals((<map<json>>poList[0])["reachedAt"], "2026-10-20T07:00:00Z");
    test:assertEquals((<map<json>>empList[0])["reachedAt"], (), "no time for an ordinary employee");
}

@test:Config
function testANewMonthNeverServesLastMonthsTotals() {
    seedMonth(THURSDAY, 60, currentStandingVersion());
    time:Utc nextMonth = checkpanic time:utcFromString("2026-11-01T00:00:01Z");
    MonthlyTotals|error month = monthlyTotals(nextMonth);
    test:assertTrue(month is error, "last month's cache must not answer for the new month");
    dropMonthlyCache();
}

@test:Config
function testTopMinPointsSettingDefaultsTo100() {
    test:assertEquals(settingsOf([]).topMinPoints, 100);
    test:assertEquals(settingsOf([{key: SETTING_TOP_MIN_POINTS, value: 150, updatedBy: "t", updatedAt: THURSDAY, version: 1}]).topMinPoints, 150);
    test:assertEquals(settingsOf([{key: SETTING_TOP_MIN_POINTS, value: -5, updatedBy: "t", updatedAt: THURSDAY, version: 1}]).topMinPoints, 100);
}

@test:Config
function testTopScopeSettingDefaultsToMonthAndAcceptsAll() {
    test:assertEquals(settingsOf([]).topScope, "MONTH");
    test:assertEquals(settingsOf([{key: SETTING_TOP_SCOPE, value: "ALL", updatedBy: "t", updatedAt: THURSDAY, version: 1}]).topScope, "ALL");
    test:assertEquals(settingsOf([{key: SETTING_TOP_SCOPE, value: "WEEK", updatedBy: "t", updatedAt: THURSDAY, version: 1}]).topScope, "MONTH");
    test:assertEquals(checkSettingChange(SETTING_TOP_SCOPE, "ALL"), ());
    test:assertTrue(checkSettingChange(SETTING_TOP_SCOPE, "WEEK") is [string, string]);
}
