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

// Chat webhook transport on the JDK's own `java.net.http` client, through Ballerina's Java interop
// (no custom Java, no extra jar).
//
// Why not `ballerina/http`: the webhook URL carries the space `key` and the secret `token` as query
// parameters (Google offers no other way, see docs/security-review-actions.md). With observability on, the
// Ballerina HTTP client stamps the request URL on its client spans as `http.url`, so the token would reach
// every trace backend (reproduced against the chat-stub with an OTLP collector). Ballerina 2201.13.x has no
// per-client switch to turn that off, and a package compiled without observability inside an instrumented
// service makes the http client fail with a NullPointerException once tracing is on. External functions are
// not instrumented, so a call made here opens no span, adds no metric label and logs nothing.
//
// Nothing here may put the URL, the query or a Java exception message into a returned error or a log line:
// callers get the Java exception's class name only.

import ballerina/jballerina.java;
import ballerina/lang.runtime;
import ballerina/lang.value;
import ballerina/time;

// ---- JDK bindings (instance methods take the receiver as the first parameter; Java strings are `handle`s) ----

isolated function jdkClientBuilder() returns handle = @java:Method {'class: "java.net.http.HttpClient", name: "newBuilder"} external;

isolated function jdkDurationOfMillis(int millis) returns handle = @java:Method {'class: "java.time.Duration", name: "ofMillis"} external;

isolated function jdkClientConnectTimeout(handle builder, handle duration) returns handle = @java:Method {
    'class: "java.net.http.HttpClient$Builder",
    name: "connectTimeout"
} external;

isolated function jdkHttp11() returns handle = @java:FieldGet {'class: "java.net.http.HttpClient$Version", name: "HTTP_1_1"} external;

isolated function jdkClientVersion(handle builder, handle version) returns handle = @java:Method {
    'class: "java.net.http.HttpClient$Builder",
    name: "version"
} external;

isolated function jdkClientBuild(handle builder) returns handle = @java:Method {'class: "java.net.http.HttpClient$Builder", name: "build"} external;

isolated function jdkUri(handle uri) returns handle = @java:Method {'class: "java.net.URI", name: "create"} external;

isolated function jdkRequestBuilder() returns handle = @java:Method {'class: "java.net.http.HttpRequest", name: "newBuilder"} external;

isolated function jdkRequestUri(handle builder, handle uri) returns handle = @java:Method {'class: "java.net.http.HttpRequest$Builder", name: "uri"} external;

isolated function jdkRequestHeader(handle builder, handle name, handle value) returns handle = @java:Method {
    'class: "java.net.http.HttpRequest$Builder",
    name: "header"
} external;

isolated function jdkRequestTimeout(handle builder, handle duration) returns handle = @java:Method {
    'class: "java.net.http.HttpRequest$Builder",
    name: "timeout"
} external;

isolated function jdkBodyOfString(handle body) returns handle = @java:Method {
    'class: "java.net.http.HttpRequest$BodyPublishers",
    name: "ofString",
    paramTypes: ["java.lang.String"]
} external;

isolated function jdkRequestPost(handle builder, handle publisher) returns handle = @java:Method {
    'class: "java.net.http.HttpRequest$Builder",
    name: "POST"
} external;

isolated function jdkRequestBuild(handle builder) returns handle = @java:Method {'class: "java.net.http.HttpRequest$Builder", name: "build"} external;

isolated function jdkStringHandler() returns handle = @java:Method {
    'class: "java.net.http.HttpResponse$BodyHandlers",
    name: "ofString"
} external;

isolated function jdkSendAsync(handle httpClient, handle request, handle bodyHandler) returns handle = @java:Method {
    'class: "java.net.http.HttpClient",
    name: "sendAsync",
    paramTypes: ["java.net.http.HttpRequest", "java.net.http.HttpResponse$BodyHandler"]
} external;

isolated function jdkIsDone(handle pending) returns boolean = @java:Method {'class: "java.util.concurrent.CompletableFuture", name: "isDone"} external;

isolated function jdkCancel(handle pending, boolean interrupt) returns boolean = @java:Method {
    'class: "java.util.concurrent.CompletableFuture",
    name: "cancel"
} external;

isolated function jdkGet(handle pending) returns handle|error = @java:Method {'class: "java.util.concurrent.CompletableFuture", name: "get", paramTypes: []} external;

isolated function jdkStatusCode(handle response) returns int = @java:Method {'class: "java.net.http.HttpResponse", name: "statusCode"} external;

isolated function jdkBody(handle response) returns handle = @java:Method {'class: "java.net.http.HttpResponse", name: "body"} external;

// ---- Transport ----

// How a call without a response ended. The class is all we keep of the Java exception.
type NoResponse "TIMEOUT"|"CONNECT_TIMEOUT"|"FAILED";

type RawResponse record {|
    int status;
    string body;
|};

isolated function millis(decimal seconds) returns int => <int>(seconds * 1000d);

isolated function newJdkClient(decimal timeoutSeconds) returns handle {
    handle builder = jdkClientConnectTimeout(jdkClientBuilder(), jdkDurationOfMillis(millis(timeoutSeconds)));
    // HTTP/1.1 only: no cleartext `Upgrade: h2c` handshake on the local stub, one request per post
    return jdkClientBuild(jdkClientVersion(builder, jdkHttp11()));
}

// POSTs `payload` as JSON. `url` is built here and goes nowhere but into the JDK request.
isolated function jdkPost(handle httpClient, string url, string payload, map<string> headers, decimal timeoutSeconds)
        returns RawResponse|NoResponse {
    handle builder = jdkRequestBuilder();
    builder = jdkRequestUri(builder, jdkUri(java:fromString(url)));
    builder = jdkRequestTimeout(builder, jdkDurationOfMillis(millis(timeoutSeconds)));
    builder = jdkRequestHeader(builder, java:fromString("Content-Type"), java:fromString("application/json; charset=UTF-8"));
    foreach [string, string] [name, value] in headers.entries() {
        builder = jdkRequestHeader(builder, java:fromString(name), java:fromString(value));
    }
    builder = jdkRequestPost(builder, jdkBodyOfString(java:fromString(payload)));
    // Async send, polled with a yielding sleep: a blocking `send` would hold a scheduler thread for up to
    // the timeout (and starves a listener living in the same process, as in the jobs tests).
    handle pending = jdkSendAsync(httpClient, jdkRequestBuild(builder), jdkStringHandler());
    decimal waited = 0;
    while !jdkIsDone(pending) {
        if waited > timeoutSeconds + 5d {
            _ = jdkCancel(pending, true);
            return "TIMEOUT";
        }
        runtime:sleep(0.01);
        waited += 0.01d;
    }
    handle|error response = jdkGet(pending);
    if response is error {
        // Only the class names inside the Java exception text are looked at; the text itself is dropped.
        string kind = response.toString();
        if kind.includes("HttpConnectTimeoutException") {
            return "CONNECT_TIMEOUT";
        }
        return kind.includes("HttpTimeoutException") ? "TIMEOUT" : "FAILED";
    }
    return {status: jdkStatusCode(response), body: java:toString(jdkBody(response)) ?: ""};
}

isolated function parseJson(string body) returns json? {
    json|error parsed = value:fromJsonString(body);
    return parsed is json ? parsed : ();
}

// ---- Breaker (the `ballerina/http` one went with the client) ----

# Rolling-window circuit breaker for the webhook, same knobs as `resilience:HttpResilience`.
isolated class Breaker {
    private final decimal windowSeconds;
    private final int volume;
    private final float ratio;
    private final decimal resetSeconds;
    private final readonly & int[] failStatuses;
    // [time, failed] per call inside the window
    private [decimal, boolean][] calls = [];
    private BreakerKind kind = "CLOSED";
    private decimal openedAt = 0;
    private boolean trialOut = false;

    isolated function init(decimal windowSeconds, int volume, float ratio, decimal resetSeconds, int[] failStatuses) {
        self.windowSeconds = windowSeconds;
        self.volume = volume;
        self.ratio = ratio;
        self.resetSeconds = resetSeconds;
        self.failStatuses = failStatuses.cloneReadOnly();
    }

    // False when the breaker is open (or the half-open trial is already out): do not call Chat.
    isolated function admit() returns boolean {
        decimal now = time:monotonicNow();
        lock {
            if self.kind == "OPEN" && now - self.openedAt >= self.resetSeconds {
                self.kind = "HALF_OPEN";
                self.trialOut = false;
            }
            if self.kind == "OPEN" {
                return false;
            }
            if self.kind == "HALF_OPEN" {
                if self.trialOut && now - self.openedAt < self.resetSeconds * 2d {
                    return false;
                }
                self.trialOut = true;
                self.openedAt = now;
            }
            return true;
        }
    }

    isolated function note(boolean failed) {
        decimal now = time:monotonicNow();
        lock {
            if self.kind == "HALF_OPEN" {
                if failed {
                    self.kind = "OPEN";
                    self.openedAt = now;
                } else {
                    self.kind = "CLOSED";
                    self.calls = [];
                }
                self.trialOut = false;
                return;
            }
            [decimal, boolean][] recent = from [decimal, boolean] c in self.calls where now - c[0] < self.windowSeconds select c;
            recent.push([now, failed]);
            self.calls = recent;
            int failures = (from [decimal, boolean] c in recent where c[1] select c).length();
            if recent.length() >= self.volume && <float>failures / <float>recent.length() >= self.ratio {
                self.kind = "OPEN";
                self.openedAt = now;
                self.calls = [];
            }
        }
    }

    isolated function failsBreaker(int status) returns boolean => self.failStatuses.indexOf(status) is int;

    isolated function state() returns BreakerKind {
        decimal now = time:monotonicNow();
        lock {
            if self.kind == "OPEN" && now - self.openedAt >= self.resetSeconds {
                return "HALF_OPEN";
            }
            return self.kind;
        }
    }
}

type BreakerKind "CLOSED"|"HALF_OPEN"|"OPEN";
