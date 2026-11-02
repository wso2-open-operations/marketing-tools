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

// Denial audit throttle: a scanner on the project network turns every 401 into a synchronous audit
// INSERT. Identical denials inside the window are counted, and the next written row carries the count,
// so the trail stays honest without a write per request. The window is passed in, so the test is not
// tied to the clock.

import amplify_api.auth;

import ballerina/test;

const string ANON = "anonymous";
const string ME_ROUTE = "GET /me";
const decimal WINDOW = 60d;

@test:Config
function testDenialThrottleCountsRepeatsAndReportsThem() {
    resetDenialAudit();
    // First denial of the window writes (0 repeats before it).
    test:assertEquals(shouldWriteDenialAt(ANON, [], ME_ROUTE, auth:TOKEN_MISSING, 100d, WINDOW), 0);
    // Repeats inside the window are counted, not written.
    test:assertTrue(shouldWriteDenialAt(ANON, [], ME_ROUTE, auth:TOKEN_MISSING, 130d, WINDOW) is ());
    test:assertTrue(shouldWriteDenialAt(ANON, [], ME_ROUTE, auth:TOKEN_MISSING, 159d, WINDOW) is ());
    // The next write after the window reports the two repeats it stands for.
    test:assertEquals(shouldWriteDenialAt(ANON, [], ME_ROUTE, auth:TOKEN_MISSING, 161d, WINDOW), 2);
    resetDenialAudit();
}

@test:Config
function testDenialThrottleKeysByCodeAndRoles() {
    resetDenialAudit();
    test:assertEquals(shouldWriteDenialAt(ANON, [], ME_ROUTE, auth:TOKEN_MISSING, 100d, WINDOW), 0);
    // A different denial code is its own bucket.
    test:assertEquals(shouldWriteDenialAt(ANON, [], ME_ROUTE, auth:TOKEN_EXPIRED, 100d, WINDOW), 0);
    // Same route and code but different roles (a 403 from another caller) is its own bucket too.
    test:assertEquals(shouldWriteDenialAt("emp-0001", ["amplify_po"], "GET /po/dashboard", "ROLE_NOT_PERMITTED",
            100d, WINDOW), 0);
    test:assertEquals(shouldWriteDenialAt("emp-0001", ["amplify_marketing"], "GET /po/dashboard",
            "ROLE_NOT_PERMITTED", 100d, WINDOW), 0);
    resetDenialAudit();
}

@test:Config
function testDenialThrottleDisabledByAZeroWindow() {
    resetDenialAudit();
    // `0` (the test configuration) never suppresses: every denial is written.
    test:assertEquals(shouldWriteDenialAt(ANON, [], ME_ROUTE, auth:TOKEN_MISSING, 100d, 0d), 0);
    test:assertEquals(shouldWriteDenialAt(ANON, [], ME_ROUTE, auth:TOKEN_MISSING, 100d, 0d), 0);
    resetDenialAudit();
}

@test:Config
function testDenialThrottleNeverGrowsPastItsCap() {
    resetDenialAudit();
    foreach int i in 0 ..< DENIAL_THROTTLE_MAX {
        test:assertEquals(shouldWriteDenialAt(ANON, [], string `GET /scan-${i}`, auth:TOKEN_MISSING, 100d, WINDOW), 0);
    }
    // Every key is still live inside the window: a new one is written but not tracked.
    test:assertEquals(shouldWriteDenialAt(ANON, [], "GET /one-more", auth:TOKEN_MISSING, 101d, WINDOW), 0);
    int size = 0;
    lock {
        size = denialBuckets.length();
    }
    test:assertEquals(size, DENIAL_THROTTLE_MAX);
    resetDenialAudit();
}

@test:Config
function testUnmatchedRoutesShareOneThrottleKeyPerMethod() {
    test:assertEquals(unmatchedRoute("GET /wp-login.php"), "GET (unmatched)");
    test:assertEquals(unmatchedRoute("GET /.env"), "GET (unmatched)");
    test:assertEquals(unmatchedRoute("POST /admin"), "POST (unmatched)");
}
