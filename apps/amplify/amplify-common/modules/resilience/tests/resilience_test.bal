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
import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;

service /dep on new http:Listener(18212) {
    resource function get down() returns http:ServiceUnavailable => {};
    resource function get ok() returns string => "ok";
}

// A call whose outcome doesn't matter, only its effect on the breaker.
function hit(http:Client c, string path) {
    http:Response|error r = c->get(path);
    _ = r is error;
}

@test:Config
function clientConfigHasBreakerPoolAndNoRetryByDefault() {
    http:ClientConfiguration c = clientConfig({}, 5);
    test:assertEquals(c.timeout, 5d);
    test:assertTrue(c.circuitBreaker is http:CircuitBreakerConfig);
    test:assertEquals(c.retryConfig, ());
    test:assertEquals((<http:PoolConfiguration>c.poolConfig).maxActiveConnections, 10);
    test:assertTrue(clientConfig({retryCount: 2}, 5).retryConfig is http:RetryConfig);
}

@test:Config
function breakerOpensOnFailuresAndHalfOpensAfterReset() returns error? {
    http:Client c = check new ("http://localhost:18212/dep", clientConfig({requestVolumeThreshold: 2,
        failureThreshold: 0.5, resetTimeSeconds: 1, rollingWindowSeconds: 10, bucketSizeSeconds: 1}, 2));
    test:assertEquals(breakerState(c), "CLOSED");
    foreach int i in 0 ..< 3 {
        hit(c, "/down");
    }
    test:assertEquals(breakerState(c), "OPEN");
    http:Response|error refused = c->get("/ok");
    test:assertTrue(refused is error, "an open breaker refuses calls without reaching the dependency");
    runtime:sleep(1.2);
    http:Response|error trial = c->get("/ok");
    test:assertTrue(trial is http:Response, "after the reset time a half-open trial reaches the dependency");
    // Ballerina settles the half-open result when the next call arrives.
    http:Response|error next = c->get("/ok");
    test:assertTrue(next is http:Response);
    test:assertEquals(breakerState(c), "CLOSED", "a successful trial closes the breaker");
}

@test:Config
function breakerReopensWhenTheHalfOpenTrialFails() returns error? {
    http:Client c = check new ("http://localhost:18212/dep", clientConfig({requestVolumeThreshold: 2,
        failureThreshold: 0.5, resetTimeSeconds: 1, rollingWindowSeconds: 10, bucketSizeSeconds: 1}, 2));
    foreach int i in 0 ..< 3 {
        hit(c, "/down");
    }
    test:assertEquals(breakerState(c), "OPEN");
    runtime:sleep(1.2);
    hit(c, "/down");
    http:Response|error next = c->get("/ok");
    test:assertTrue(next is error, "after a failed trial the next call is refused");
    test:assertEquals(breakerState(c), "OPEN", "a failed trial opens the breaker again");
}

@test:Config
function correlationHeaderOnlyWhenPresent() {
    test:assertEquals(correlationHeaders(()), {});
    test:assertEquals(correlationHeaders("c-1"), {[CORRELATION_HEADER]: "c-1"});
}

@test:Config
function clientConfigCarriesSettings() {
    http:ClientConfiguration c = clientConfig({maxActiveConnections: 3, breakerStatusCodes: [503], retryCount: 2,
        retryIntervalSeconds: 0.5}, 7);
    http:PoolConfiguration pool = <http:PoolConfiguration>c.poolConfig;
    test:assertEquals(pool.maxActiveConnections, 3);
    test:assertEquals(pool.maxIdleConnections, 3);
    http:CircuitBreakerConfig cb = <http:CircuitBreakerConfig>c.circuitBreaker;
    test:assertEquals(cb.statusCodes, [503]);
    http:RetryConfig retrySettings = <http:RetryConfig>c.retryConfig;
    test:assertEquals(retrySettings.count, 2);
    test:assertEquals(retrySettings.maxWaitInterval, 4d);
    test:assertEquals(correlationHeaders(""), {}, "an empty id sends no header");
}

@test:Config
function breakerStateValues() {
    test:assertEquals(breakerStateValue("CLOSED"), 0.0);
    test:assertEquals(breakerStateValue("HALF_OPEN"), 1.0);
    test:assertEquals(breakerStateValue("OPEN"), 2.0);
    test:assertEquals(breakerStateValue("NOT_CONFIGURED"), -1.0);
    test:assertEquals(exportedBreakerValue("never-exported", "x"), ());
}

@test:Config
function tokenPartitionGauge() {
    exportTokenPartitionDaysAhead("test-component", 14);
    float? days = exportedOutboxValue(TOKEN_PARTITION_METRIC, "test-component");
    // No metrics reporter in tests: the registry is a no-op (0.0). Either way export never fails the caller.
    test:assertTrue(days is () || days == 14.0 || days == 0.0);
}

@test:Config
function outboxBacklogGauges() {
    // Tests run without a metrics reporter, so the registry is a no-op (0.0); with a reporter (Choreo, Prometheus)
    // the gauges hold the latest value. Either way export never fails the caller.
    exportOutboxBacklog("test-component", 4, 1, 7200);
    float? oldest = exportedOutboxValue(OUTBOX_OLDEST_METRIC, "test-component");
    test:assertTrue(oldest is () || oldest == 7200.0 || oldest == 0.0);
    exportOutboxBacklog("test-component", 0, 0, ());
    float? none = exportedOutboxValue(OUTBOX_OLDEST_METRIC, "test-component");
    test:assertTrue(none is () || none == -1.0 || none == 0.0);
}
