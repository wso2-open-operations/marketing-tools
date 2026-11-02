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

// Database breaker in amplify-api (plan M9/M11, ADR-028): transient failures open it, an open breaker
// answers 503 `DEPENDENCY_UNAVAILABLE` without touching the pool and fails `/ready`, a failed half-open
// trial opens it again, and the state shows up in `/ready`. Recovery against a real database (stop and
// start Postgres) is in amplify-jobs' IT.

import amplify_common.linkedin;
import amplify_domain.store;

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

final sql:DatabaseError dbConnectionLost = error sql:DatabaseError("Connection refused", errorCode = 0,
    sqlState = "08006");

@test:Config {groups: ["db-breaker"]}
function testDbBreakerOpenAnswers503AndFailsReady() returns error? {
    dbBreaker.reset();
    setDbUp(true);
    do {
        test:assertFalse(dbBreaker.onFailure(error sql:DatabaseError("dup", errorCode = 0, sqlState = "23505")),
                "a constraint violation says nothing about the database's health");
        foreach int i in 0 ..< 3 {
            recordDbFailure(dbConnectionLost);
        }
        test:assertEquals(dbBreakerState(), "OPEN");

        http:Response res = check send("GET", "/leaderboard", (), check employee("emp-breaker"));
        test:assertEquals(res.statusCode, 503);
        test:assertEquals(check codeIn(res), DEPENDENCY_UNAVAILABLE);

        http:Response ready = check testClient->get("/ready");
        test:assertEquals(ready.statusCode, 503, "an open DB breaker fails readiness");
        json body = check ready.getJsonPayload();
        test:assertEquals(check body.database, "DOWN");
        test:assertEquals(check body.breakers.database, "OPEN");

        runtime:sleep(1.1);
        test:assertEquals(dbBreakerState(), "HALF_OPEN");
        // The trial can't reach a database (none configured in unit tests), so the breaker opens again.
        http:Response trial = check send("GET", "/leaderboard", (), check employee("emp-breaker"));
        test:assertEquals(trial.statusCode, 503);
        test:assertEquals(dbBreakerState(), "OPEN");
    } on fail error e {
        dbBreaker.reset();
        return e;
    }
    dbBreaker.reset();
    http:Response ready = check testClient->get("/ready");
    test:assertEquals(ready.statusCode, 200);
    test:assertEquals(check (check ready.getJsonPayload()).breakers.database, "CLOSED");
}

@test:Config
function testLinkedInOAuthOutageSaysLinkedInIsUnavailable() returns error? {
    linkedin:ProviderError down = error linkedin:ProviderError("LinkedIn unavailable", code = linkedin:UNAVAILABLE,
        httpStatus = 503, serviceErrorCode = (), retryable = true);
    http:StatusCodeResponse res = providerFailure(down, "corr-1");
    test:assertTrue(res is http:ServiceUnavailable);
    if res is http:ServiceUnavailable {
        Problem p = check res?.body.cloneWithType();
        test:assertEquals(p.code, DEPENDENCY_UNAVAILABLE);
        test:assertEquals(p.detail, "LinkedIn is unavailable, try again");
    }
}

// Item 12.5 (R-13): leaked connections show up as HikariCP "Connection is not available"; repeated, they open
// the breaker and `/ready` answers 503 DOWN, so the platform restarts the pod.
@test:Config {groups: ["db-breaker"], dependsOn: [testDbBreakerOpenAnswers503AndFailsReady]}
function testPoolExhaustionFailsReady() returns error? {
    dbBreaker.reset();
    sql:Error exhausted = error sql:ApplicationError(
        "Failed to get a connection: HikariPool-1 - Connection is not available, request timed out after 3000ms.");
    do {
        foreach int i in 0 ..< dbBreakerFailureThreshold {
            recordDbFailure(exhausted);
        }
        test:assertEquals(dbBreakerState(), "OPEN", "pool exhaustion counts as a transient database failure");
        http:Response ready = check testClient->get("/ready");
        test:assertEquals(ready.statusCode, 503);
        test:assertEquals(check (check ready.getJsonPayload()).status, "DOWN");
    } on fail error e {
        dbBreaker.reset();
        return e;
    }
    dbBreaker.reset();
}

// Domain review H-1: VERIFY_FULL by default, the CA file passed through.
@test:Config
function testDbConfigVerifiesTheServerByDefault() {
    store:DbConfig cfg = dbConfig();
    test:assertEquals(cfg.sslMode, postgresql:VERIFY_FULL);
    test:assertEquals(cfg.sslRootCert, "");
}
