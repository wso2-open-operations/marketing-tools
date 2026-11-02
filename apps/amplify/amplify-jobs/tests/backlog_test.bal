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
function testBacklogAlertsOnAnOldPendingRowOrAnyFailure() {
    test:assertFalse(isBacklogAlerting({pending: 0, inProgress: 0, failed: 0, oldestPendingSeconds: ()}, 3600));
    test:assertFalse(isBacklogAlerting({pending: 5, inProgress: 1, failed: 0, oldestPendingSeconds: 120}, 3600));
    test:assertFalse(isBacklogAlerting({pending: 1, inProgress: 0, failed: 0, oldestPendingSeconds: 3600}, 3600),
            "exactly at the threshold is not over it");
    test:assertTrue(isBacklogAlerting({pending: 1, inProgress: 0, failed: 0, oldestPendingSeconds: 3601}, 3600));
    test:assertTrue(isBacklogAlerting({pending: 0, inProgress: 0, failed: 1, oldestPendingSeconds: ()}, 3600),
            "a row that used every attempt always needs someone");
}

@test:Config
function testBacklogReportOmitsTheAgeWhenNothingIsPending() {
    OutboxReport idle = toOutboxReport({pending: 0, inProgress: 0, failed: 0, oldestPendingSeconds: ()}, 3600);
    test:assertEquals(idle, {pending: 0, inProgress: 0, failed: 0, alerting: false});
    OutboxReport stuck = toOutboxReport({pending: 2, inProgress: 0, failed: 0, oldestPendingSeconds: 7200}, 3600);
    test:assertEquals(stuck, {pending: 2, inProgress: 0, failed: 0, oldestPendingSeconds: 7200, alerting: true});
}

@test:Config
function testReadinessCarriesTheBacklogOnlyWhenItWasRead() {
    ReadyReport without = readiness(true, {}, false);
    test:assertTrue(without.outbox is ());
    OutboxReport backlog = {pending: 3, inProgress: 0, failed: 0, oldestPendingSeconds: 9000, alerting: true};
    ReadyReport with = readiness(true, {}, false, backlog);
    test:assertEquals(with.outbox, backlog);
    // The backlog never takes the worker out of rotation: only the database does.
    test:assertEquals(with.status, readiness(true, {}, false).status);
}
