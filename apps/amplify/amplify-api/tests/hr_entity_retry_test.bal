// Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
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
import ballerina/test;

@test:Config {groups: ["reads"]}
function testHrEntityRetryDefaultsMatchTheOtherApps() {
    http:RetryConfig cfg = hrEntityRetry();
    test:assertEquals(cfg.count, 3);
    // The test Config.toml shortens the interval; the shipped default is 3.0.
    test:assertEquals(cfg.interval, hrEntityRetryInterval);
    test:assertEquals(cfg.backOffFactor, 2.0f);
    test:assertEquals(cfg.maxWaitInterval, 20.0d);
    test:assertEquals(cfg.statusCodes, [500, 502, 503, 504]);
}

// A client of its own, so the breaker this test opens is not the one the other tests read through.
@test:Config {groups: ["reads"]}
function testAnUnavailableHrEntityIsRetriedThenTheBreakerFailsFast() returns error? {
    setDirectory("unavailable");
    http:Client? c = check newBreakerClient("http://localhost:9591/people/graphql", 5, (), hrEntityRetry());
    http:Client own = <http:Client>c;
    _ = takeDirectoryFetches();

    DirectoryRecord[]|error first = fetchDirectoryPage(own, {}, 1000, 0);
    test:assertTrue(first is error, "a 503 is an error in the end");
    test:assertEquals(takeDirectoryFetches(), hrEntityRetryCount + 1, "one try and every retry reached the service");

    DirectoryRecord[]|error second = fetchDirectoryPage(own, {}, 1000, 0);
    test:assertTrue(second is error);
    test:assertEquals(takeDirectoryFetches(), 0, "the breaker is open: nothing reaches the service");
    setDirectory("ok");
}
