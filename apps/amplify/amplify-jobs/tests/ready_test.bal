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

// `GET /ready` and the start-up check of the run tuning (deep review 2026-10-17).

import amplify_common.types;

import ballerina/http;
import ballerina/test;

@test:Config
function readyWithoutDatabaseIs503AndReportsBreakers() returns error? {
    http:Response res = check testClient->get("/ready");
    test:assertEquals(res.statusCode, http:STATUS_SERVICE_UNAVAILABLE);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.component, COMPONENT);
    test:assertEquals(check body.status, types:DOWN);
    test:assertEquals(check body.database, types:DOWN);
    test:assertEquals(check body.runInProgress, false);
    json breakers = check body.breakers;
    test:assertEquals(check breakers.linkedinApi, "NOT_CONFIGURED", "LinkedIn is reported, not fatal");
    test:assertEquals(check breakers.googleChat, "NOT_CONFIGURED", "Chat is reported, not fatal");
    test:assertTrue((check breakers.database) is string);
}

@test:Config
function readinessIsGatedOnlyByTheDatabase() {
    ReadyReport up = readiness(true, {database: "CLOSED", linkedinApi: "OPEN", googleChat: "OPEN"}, true);
    test:assertEquals(up.status, types:UP, "open LinkedIn/Chat breakers don't fail readiness");
    test:assertEquals(up.database, types:UP);
    test:assertTrue(up.runInProgress);
    ReadyReport down = readiness(false, {database: "OPEN"}, false);
    test:assertEquals(down.status, types:DOWN);
    test:assertEquals(down.database, types:DOWN);
}

// Choreo stops routing on any non-2xx readiness response: a database blip must not turn every scheduler call
// into a network failure, and `POST /runs` already answers the scheduler's retryable 503.
@test:Config
function readinessKeepsRoutingUnlessTheDatabaseIsUnconfigured() {
    test:assertTrue(readyKeepsRouting(true), "a database blip keeps the worker in rotation");
    test:assertFalse(readyKeepsRouting(false), "no dbHost: the worker can never do its work");
}

@test:Config
function runConfigDefaultsAreValid() {
    test:assertEquals(validateRunConfig(runConfig(), longestCallSeconds()), ());
    test:assertEquals(validateRunConfig(TEST_CONFIG, 10), ());
}

@test:Config
function runConfigRejectsALeaseShorterThanTheRunBudget() {
    RunConfig cfg = {...TEST_CONFIG};
    cfg.maxSeconds = 295;
    cfg.leaseSeconds = 300;
    error? bad = validateRunConfig(cfg, 10);
    test:assertTrue(bad is error, "295 s budget + 10 s call can outlive a 300 s lease");
    if bad is error {
        test:assertTrue(bad.message().includes("runLockLeaseSeconds"));
    }
    cfg.maxSeconds = 289;
    test:assertEquals(validateRunConfig(cfg, 10), (), "289 + 10 < 300");
}

@test:Config
function runConfigRejectsNonsense() {
    RunConfig cfg = {...TEST_CONFIG};
    cfg.batchSize = 0;
    test:assertTrue(validateRunConfig(cfg, 10) is error);
    cfg = {...TEST_CONFIG};
    cfg.linkedinMaxPostsPerRun = -1;
    test:assertTrue(validateRunConfig(cfg, 10) is error);
    cfg = {...TEST_CONFIG};
    cfg.backoffMaxSeconds = 1;
    test:assertTrue(validateRunConfig(cfg, 10) is error);
}

@test:Config
function longestCallIsTheSlowerDependency() {
    decimal chat = chatTimeoutSeconds + chatMinIntervalSeconds;
    decimal registered = amplifyOnNovera ? 2d * noveraTimeoutSeconds + chat : chat;
    decimal expected = linkedinTimeoutSeconds > registered ? linkedinTimeoutSeconds : registered;
    test:assertEquals(longestCallSeconds(), expected);
}
