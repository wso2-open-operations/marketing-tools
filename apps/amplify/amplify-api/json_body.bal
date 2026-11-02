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

// JSON response bodies for every read and POST response that can run past the 512-char writer window (M11b:
// first `/team`, then `/leaderboard` (~700 B), the lists, the dashboard and the POST responses; see
// docs/testing/load-test-2026-10.md).
//
// A `json` returned straight from a resource is serialized by the http module with
// `JsonUtils.serialize(value, OutputStream)`, and that constructor wraps the stream in a
// `java.io.BufferedWriter`. On JDK 21 that writer starts at 512 chars when the thread is virtual
// (`BufferedWriter.initialBufferSize()`, which is how Ballerina runs strands) and grows exact-fit — never
// doubling — up to 8192, so every write past 512 reallocates and copies the whole buffer: a ~6 KB page
// (`/team`, 25 rows) is a few thousand copies of a growing array per request. JFR on the M11 run put
// ~half the api's samples in `Arrays.copyOf` under `growIfNeeded`.
//
// `java.io.StringWriter` is a `Writer`, so `JsonUtils.serialize(value, Writer)` skips the wrapper while
// still using the runtime's own generator and escaping: the bytes are the same (pinned by
// tests/json_body_test.bal), the buffer grows by doubling, and the http module writes the
// `application/json` body unchanged.

import ballerina/http;
import ballerina/jballerina.java;

# A `200 OK` response whose body is `value` as JSON.
#
# + value - Body
# + cacheControl - `Cache-Control` to send, `()` for none (the security interceptor then sets `no-store`)
# + return - The response, or an error when `value` can't be encoded (a cyclic value)
isolated function jsonBody(json value, string? cacheControl = ()) returns http:Response|error {
    http:Response res = new;
    res.setPayload(check jsonText(value), "application/json");
    if cacheControl is string {
        cacheable(res, cacheControl);
    }
    return res;
}

# Marks a per-caller response cacheable by the caller's browser only: `Cache-Control` as given plus
# `Vary: Authorization`, so a second user signing in on the same browser never gets the first one's copy.
#
# + res - Response
# + cacheControl - For example `private, max-age=30`
isolated function cacheable(http:Response res, string cacheControl) {
    res.setHeader("Cache-Control", cacheControl);
    res.setHeader("Vary", "Authorization");
}

# A read's result as the response: problem details pass through untouched, a body goes through `jsonBody`.
# Every read that returns a body of more than a few hundred bytes uses this (M11b).
#
# + result - Body or problem details
# + return - The response
isolated function okJson(json|ProblemResponse result) returns http:Response|ProblemResponse|error =>
    result is ProblemResponse ? result : jsonBody(<json>result);

# `value` as JSON text, through the runtime's generator and a `StringWriter`.
#
# + value - Value to encode
# + return - JSON text, or an error when `value` can't be encoded or the writer returned nothing
isolated function jsonText(json value) returns string|error {
    handle writer = newStringWriter();
    check jsonSerialize(value, writer);
    return java:toString(writerText(writer)) ?: error("the JSON encoder returned no text");
}

isolated function newStringWriter() returns handle = @java:Constructor {
    'class: "java.io.StringWriter"
} external;

# Java `String` handles cross back as `java:toString`, as in `amplify_common.crypto.gcm`.
#
# + writer - The `StringWriter`
# + return - Its text, as a Java `String` handle
isolated function writerText(handle writer) returns handle = @java:Method {
    'class: "java.io.StringWriter",
    name: "toString"
} external;

isolated function jsonSerialize(json value, handle writer) returns error? = @java:Method {
    'class: "io.ballerina.runtime.api.utils.JsonUtils",
    name: "serialize",
    paramTypes: ["java.lang.Object", "java.io.Writer"]
} external;
