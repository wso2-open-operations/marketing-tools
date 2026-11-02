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

// Outbound HTTP resilience (plan M9): one circuit breaker, optional retry and a private connection pool
// (bulkhead) per dependency, so a slow LinkedIn can't starve Google Chat. Values come from config.

import ballerina/http;

# Breaker state name: `CLOSED`, `HALF_OPEN` or `OPEN`.
public type BreakerState "CLOSED"|"HALF_OPEN"|"OPEN";

# Header that carries the correlation id on every outbound call.
public const string CORRELATION_HEADER = "X-Correlation-ID";

# Resilience settings for one outbound dependency.
public type HttpResilience record {|
    # Rolling window the breaker looks at, seconds
    decimal rollingWindowSeconds = 60;
    # Bucket size inside the window, seconds
    decimal bucketSizeSeconds = 10;
    # Fewest requests in the window before the breaker may trip
    int requestVolumeThreshold = 5;
    # Failure ratio that opens the breaker (0-1)
    float failureThreshold = 0.5;
    # Time an open breaker waits before half-open, seconds
    decimal resetTimeSeconds = 30;
    # Responses counted as failures (connection errors and timeouts always count)
    int[] breakerStatusCodes = [429, 500, 502, 503, 504];
    # HTTP-level retries. Keep 0 for calls that aren't idempotent (`POST /rest/posts`, the Chat webhook):
    # a retry after a lost response would post twice, so those retry through the outbox instead (ADR-025)
    int retryCount = 0;
    # First retry wait, seconds
    decimal retryIntervalSeconds = 1;
    # Most open connections in this dependency's own pool (bulkhead)
    int maxActiveConnections = 10;
|};

# Client settings for one dependency: timeout, breaker, retry and a private pool.
#
# + settings - Resilience settings
# + timeoutSeconds - Per-call timeout
# + return - `http:ClientConfiguration`
public isolated function clientConfig(HttpResilience settings, decimal timeoutSeconds) returns http:ClientConfiguration {
    http:ClientConfiguration config = {
        timeout: timeoutSeconds,
        circuitBreaker: {
            rollingWindow: {
                timeWindow: settings.rollingWindowSeconds,
                bucketSize: settings.bucketSizeSeconds,
                requestVolumeThreshold: settings.requestVolumeThreshold
            },
            failureThreshold: settings.failureThreshold,
            resetTime: settings.resetTimeSeconds,
            statusCodes: settings.breakerStatusCodes
        },
        poolConfig: {maxActiveConnections: settings.maxActiveConnections, maxIdleConnections: settings.maxActiveConnections}
    };
    if settings.retryCount > 0 {
        config.retryConfig = {count: settings.retryCount, interval: settings.retryIntervalSeconds, backOffFactor: 2.0,
            maxWaitInterval: settings.retryIntervalSeconds * 8, statusCodes: [502, 503, 504]};
    }
    return config;
}

# Current state of a client's breaker.
#
# + c - Client built with `clientConfig`
# + return - `CLOSED`, `HALF_OPEN` or `OPEN`
public isolated function breakerState(http:Client c) returns BreakerState {
    http:CircuitState state = c.getCircuitBreakerCurrentState();
    return state == http:CB_OPEN_STATE ? "OPEN" : state == http:CB_HALF_OPEN_STATE ? "HALF_OPEN" : "CLOSED";
}

# Headers that carry a correlation id, or none.
#
# + correlationId - Correlation id, or `()`
# + return - Header map
public isolated function correlationHeaders(string? correlationId) returns map<string> =>
    correlationId is string && correlationId.length() > 0 ? {[CORRELATION_HEADER]: correlationId} : {};
