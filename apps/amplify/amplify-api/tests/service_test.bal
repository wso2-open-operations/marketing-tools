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

final http:Client testClient = check new (string `http://localhost:${port}`, {cache: {enabled: false}});

@test:Config
function testHealthReturnsUp() returns error? {
    types:HealthStatus body = check testClient->get("/health");
    test:assertEquals(body, {component: COMPONENT, status: types:UP});
}

@test:Config
function testReadyFollowsTheDatabase() returns error? {
    setDbUp(true);
    http:Response up = check testClient->get("/ready");
    test:assertEquals(up.statusCode, 200);
    json body = check up.getJsonPayload();
    test:assertEquals(check body.status, "UP");
    test:assertEquals(check body.breakers.jwks, "CLOSED");
    setDbUp(false);
    http:Response down = check testClient->get("/ready");
    test:assertEquals(down.statusCode, 503);
    test:assertEquals(check (check down.getJsonPayload()).database, "DOWN");
    setDbUp(true);
}

@test:Config
function testSecurityHeadersAndCorrelationOnEveryResponse() returns error? {
    http:Response probe = check testClient->get("/health", {"X-Correlation-ID": "corr-abc"});
    test:assertEquals(probe.getHeader("X-Content-Type-Options"), "nosniff");
    test:assertEquals(probe.getHeader("Content-Security-Policy"), "upgrade-insecure-requests");
    test:assertEquals(probe.getHeader("Strict-Transport-Security"), "max-age=31536000; includeSubDomains");
    test:assertEquals(probe.getHeader("X-Correlation-ID"), "corr-abc");
    http:Response denied = check testClient->get("/po/dashboard");
    test:assertEquals(denied.statusCode, 401);
    test:assertEquals(denied.getHeader("X-Content-Type-Options"), "nosniff");
    string generated = check denied.getHeader("X-Correlation-ID");
    test:assertTrue(generated.length() > 0, "a correlation id is generated when none is sent");
}
