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
import amplify_common.types;

import ballerina/http;
import ballerina/test;

final http:Client testClient = check new ("http://localhost:9091");

// Same value as `internalApiKey` in tests/Config.toml.
const string TEST_INTERNAL_KEY = "test-internal-key-0123456789abcdef0123456789";
// Same value as `schedulerApiKey` in tests/Config.toml.
const string TEST_SCHEDULER_KEY = "test-scheduler-key-0123456789abcdef012345";
final map<string> SCHEDULER_KEYED = {[INTERNAL_KEY_HEADER]: TEST_SCHEDULER_KEY};
final map<string> KEYED = {[INTERNAL_KEY_HEADER]: TEST_INTERNAL_KEY};

@test:Config
function testHealthReturnsUp() returns error? {
    types:HealthStatus body = check testClient->get("/health");
    test:assertEquals(body, {component: COMPONENT, status: types:UP});
}

@test:Config
function testRunsWithoutDatabaseIs503() returns error? {
    http:Response res = check testClient->post("/runs", (), KEYED);
    test:assertEquals(res.statusCode, http:STATUS_SERVICE_UNAVAILABLE);
}

@test:Config
function testPartitionMaintenanceWithoutDatabaseIs503() returns error? {
    http:Response res = check testClient->post("/maintenance/partitions", (), KEYED);
    test:assertEquals(res.statusCode, http:STATUS_SERVICE_UNAVAILABLE);
}

@test:Config
function testRebuildRecognitionWithoutDatabaseIs503() returns error? {
    http:Response res = check testClient->post("/maintenance/rebuild-recognition", (), KEYED);
    test:assertEquals(res.statusCode, http:STATUS_SERVICE_UNAVAILABLE);
}

@test:Config
function testEveryMutationRefusesACallWithoutTheKey() returns error? {
    foreach string path in ["/runs", "/maintenance/partitions", "/maintenance/rebuild-recognition"] {
        http:Response none = check testClient->post(path, ());
        test:assertEquals(none.statusCode, http:STATUS_UNAUTHORIZED, path + " without a key");
        http:Response wrong = check testClient->post(path, (), {[INTERNAL_KEY_HEADER]: "not-the-key"});
        test:assertEquals(wrong.statusCode, http:STATUS_UNAUTHORIZED, path + " with the wrong key");
        http:Response prefix = check testClient->post(path, (), {[INTERNAL_KEY_HEADER]: TEST_INTERNAL_KEY.substring(0, 20)});
        test:assertEquals(prefix.statusCode, http:STATUS_UNAUTHORIZED, path + " with part of the key");
    }
}

@test:Config
function testProbesStayOpenButNothingElseDoes() returns error? {
    http:Response ready = check testClient->get("/ready");
    test:assertNotEquals(ready.statusCode, http:STATUS_UNAUTHORIZED, "readiness is a probe");
    // Only GET on the two probe paths is exempt: the same path with another method, and any other path, is not.
    http:Response postReady = check testClient->post("/ready", ());
    test:assertEquals(postReady.statusCode, http:STATUS_UNAUTHORIZED);
    http:Response other = check testClient->get("/nothing-here");
    test:assertEquals(other.statusCode, http:STATUS_UNAUTHORIZED);
}

@test:Config
function testAKeyWithAStrayNewlineStillMatches() {
    test:assertTrue(keyMatches("abc", "abc\n"));
    test:assertTrue(keyMatches(" abc ", "abc"));
    test:assertFalse(keyMatches("abc", "abd\n"));
    test:assertFalse(keyMatches("", "abc"));
}

@test:Config
function testBlankShortOrEqualKeysAreRefusedAtStartUp() {
    test:assertTrue(checkKeys("", TEST_SCHEDULER_KEY) is error);
    test:assertTrue(checkKeys("   ", TEST_SCHEDULER_KEY) is error);
    test:assertTrue(checkKeys("too-short", TEST_SCHEDULER_KEY) is error);
    test:assertTrue(checkKeys(TEST_INTERNAL_KEY, "") is error);
    test:assertTrue(checkKeys(TEST_INTERNAL_KEY, "too-short") is error);
    test:assertTrue(checkKeys(TEST_INTERNAL_KEY, TEST_INTERNAL_KEY) is error, "same value");
    test:assertTrue(checkKeys(TEST_INTERNAL_KEY, TEST_INTERNAL_KEY + "\n") is error, "same value after trim");
    test:assertEquals(checkKeys(TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY), ());
}

// ---- Access matrix over HTTP ------------------------------------------------------------------------

@test:Config
function testTheInternalKeyReachesEveryRoute() returns error? {
    foreach string path in ["/runs", "/maintenance/partitions", "/maintenance/rebuild-recognition", "/maintenance/leavers"] {
        http:Response res = check testClient->post(path, (), KEYED);
        test:assertNotEquals(res.statusCode, http:STATUS_UNAUTHORIZED, path);
        test:assertNotEquals(res.statusCode, http:STATUS_FORBIDDEN, path);
    }
}

@test:Config
function testTheSchedulerKeyReachesOnlyRunsAndPartitionMaintenance() returns error? {
    foreach string path in ["/runs", "/maintenance/partitions"] {
        http:Response res = check testClient->post(path, (), SCHEDULER_KEYED);
        test:assertNotEquals(res.statusCode, http:STATUS_UNAUTHORIZED, path);
        test:assertNotEquals(res.statusCode, http:STATUS_FORBIDDEN, path);
    }
    foreach string path in ["/maintenance/rebuild-recognition", "/maintenance/leavers", "/nothing-here", "/runs/x"] {
        http:Response res = check testClient->post(path, (), SCHEDULER_KEYED);
        test:assertEquals(res.statusCode, http:STATUS_FORBIDDEN, path + " with the scheduler key");
    }
    // Other methods on its own routes, and a GET anywhere but the probes.
    http:Response get = check testClient->get("/runs", SCHEDULER_KEYED);
    test:assertEquals(get.statusCode, http:STATUS_FORBIDDEN);
}

@test:Config
function testWrongMissingAndPrefixKeysAreUnauthorizedOnTheSchedulerRoutes() returns error? {
    foreach string path in ["/runs", "/maintenance/partitions"] {
        http:Response none = check testClient->post(path, ());
        test:assertEquals(none.statusCode, http:STATUS_UNAUTHORIZED, path);
        http:Response wrong = check testClient->post(path, (), {[INTERNAL_KEY_HEADER]: "not-the-key"});
        test:assertEquals(wrong.statusCode, http:STATUS_UNAUTHORIZED, path);
        http:Response prefix = check testClient->post(path, (), {[INTERNAL_KEY_HEADER]: TEST_SCHEDULER_KEY.substring(0, 20)});
        test:assertEquals(prefix.statusCode, http:STATUS_UNAUTHORIZED, path);
        http:Response longer = check testClient->post(path, (), {[INTERNAL_KEY_HEADER]: TEST_SCHEDULER_KEY + "x"});
        test:assertEquals(longer.statusCode, http:STATUS_UNAUTHORIZED, path);
    }
}

@test:Config
function testProbesStayOpenWithTheSchedulerKeyToo() returns error? {
    http:Response ready = check testClient->get("/ready", SCHEDULER_KEYED);
    test:assertNotEquals(ready.statusCode, http:STATUS_UNAUTHORIZED);
    test:assertNotEquals(ready.statusCode, http:STATUS_FORBIDDEN);
}

@test:Config
function testDecideAccessMatrix() {
    string[] runs = ["runs"];
    string[] parts = ["maintenance", "partitions"];
    string[] rebuild = ["maintenance", "rebuild-recognition"];
    test:assertEquals(decideAccess(TEST_INTERNAL_KEY, TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY, "POST", rebuild), FULL);
    test:assertEquals(decideAccess(TEST_INTERNAL_KEY, TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY, "POST", runs), FULL);
    test:assertEquals(decideAccess(TEST_SCHEDULER_KEY, TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY, "POST", runs), SCHEDULER_ROUTE);
    test:assertEquals(decideAccess(TEST_SCHEDULER_KEY + "\n", TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY, "POST", parts), SCHEDULER_ROUTE);
    test:assertEquals(decideAccess(TEST_SCHEDULER_KEY, TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY, "POST", rebuild), FORBIDDEN);
    test:assertEquals(decideAccess(TEST_SCHEDULER_KEY, TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY, "GET", runs), FORBIDDEN);
    test:assertEquals(decideAccess("nope", TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY, "POST", runs), DENIED);
    test:assertEquals(decideAccess("", TEST_INTERNAL_KEY, TEST_SCHEDULER_KEY, "POST", runs), DENIED);
}
