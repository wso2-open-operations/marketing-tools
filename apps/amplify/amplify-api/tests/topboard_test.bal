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

// The Celebrate top board: the monthly totals are read once and shared, and the scope setting.

import amplify_domain.recognition;

import ballerina/test;
import ballerina/time;

final time:Utc THURSDAY = checkpanic time:utcFromString("2026-10-22T16:00:00Z");

function seedMonth(time:Utc now, decimal ageSeconds) {
    lock {
        monthlyCache = {
            monthStart: recognition:monthStartOf(now),
            totals: [{employeeId: "e1", displayName: "Avery", email: "a@wso2.com", totalPoints: 9, lastActivityAt: ()}],
            loadedAt: now,
            readAt: time:monotonicNow() - ageSeconds
        };
    }
}

@test:Config
function testFreshMonthlyTotalsAreReusedWithoutAnotherRead() returns error? {
    seedMonth(THURSDAY, 60);
    MonthlyTotals first = check monthlyTotals(THURSDAY);
    MonthlyTotals second = check monthlyTotals(THURSDAY);
    test:assertEquals(first.loadedAt, THURSDAY);
    test:assertEquals(second.totals, first.totals);
    test:assertEquals(monthlyCacheSize(), 1);
    dropMonthlyCache();
}

@test:Config
function testExpiredTotalsOfTheSameMonthAreServedWhenTheReloadFails() returns error? {
    // Older than the 2 hour lifetime, and no database in this test: the previous totals carry on.
    seedMonth(THURSDAY, topBoardCacheSeconds + 1d);
    MonthlyTotals served = check monthlyTotals(THURSDAY);
    test:assertEquals(served.totals.length(), 1);
    dropMonthlyCache();
}

@test:Config
function testANewMonthNeverServesLastMonthsTotals() {
    seedMonth(THURSDAY, 60);
    time:Utc nextMonth = checkpanic time:utcFromString("2026-11-01T00:00:01Z");
    MonthlyTotals|error month = monthlyTotals(nextMonth);
    test:assertTrue(month is error, "last month's cache must not answer for the new month");
    dropMonthlyCache();
}

@test:Config
function testOnlyPeopleWithTheMinimumQualifyForTheTopThree() {
    recognition:EmployeeTotal[] totals = [
        {employeeId: "a", displayName: "A", email: "a@wso2.com", totalPoints: 100, lastActivityAt: ()},
        {employeeId: "b", displayName: "B", email: "b@wso2.com", totalPoints: 99, lastActivityAt: ()},
        {employeeId: "c", displayName: "C", email: "c@wso2.com", totalPoints: 250, lastActivityAt: ()}
    ];
    test:assertEquals(qualifying(totals, 100).map(t => t.employeeId), ["a", "c"], "100 qualifies, 99 does not");
    test:assertEquals(qualifying(totals, 0).length(), 3, "a minimum of 0 lets everyone in");
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
