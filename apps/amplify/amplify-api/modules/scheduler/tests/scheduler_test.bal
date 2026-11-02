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

// Schedule validation, payload limits and the client's upsert against an in-test scheduler double that
// follows the v1.7.8 handlers (404 / 201 / 409 / ETag + If-Match / 204).

import ballerina/http;
import ballerina/test;

@test:Config
function testValidSchedules() {
    foreach string s in ["*/5 * * * *", "0 2 * * *", "0 9-17/2 * * MON-FRI", "15,45 * 1 JAN,jul ?", "@daily",
            "@hourly", "@every 5m", "@every 1h30m", "@every 90s"] {
        test:assertEquals(checkSchedule(s, 60), (), s);
    }
}

@test:Config
function testInvalidSchedules() {
    foreach string s in ["", "* * * *", "* * * * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *",
            "* * * * 7", "5-1 * * * *", "*/0 * * * *", "@every", "@every 5", "@every 5x", "@every 30s", "@often",
            "CRON_TZ=UTC 0 2 * * *", " 0 2 * * *", "* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *"] {
        test:assertTrue(checkSchedule(s, 60) is string, s);
    }
}

@test:Config
function testGoDurations() returns error? {
    test:assertEquals(check parseGoDuration("300s"), 300d);
    test:assertEquals(check parseGoDuration("5m0s"), 300d);
    test:assertEquals(check parseGoDuration("1h30m"), 5400d);
    test:assertEquals(check parseGoDuration("1.5h"), 5400d);
    test:assertEquals(check parseGoDuration("250ms"), 0.25d);
    test:assertTrue(parseGoDuration("0") is error);
    test:assertTrue(parseGoDuration("5d") is error);
    test:assertEquals(goDuration(300), "300s");
}

function spec() returns JobSpec => {
    id: "amplify-run",
    name: "Amplify Run",
    schedule: "@every 5m",
    uri: "http://amplify-jobs:9091/runs",
    retryCount: 1,
    retryIntervalSeconds: 30,
    deadlineSeconds: 300
};

@test:Config
function testPayloadShape() returns error? {
    map<json> p = check jobPayload("amplify", spec());
    test:assertEquals(p["state"], "enabled");
    test:assertEquals(p["collectionId"], "amplify");
    json action = p["action"];
    test:assertEquals(check action.'type, "HTTP");
    test:assertEquals(check action.request.method, "POST");
    // Empty body and headers are sent so a PATCH clears old values.
    test:assertEquals(check action.request.body, "");
    test:assertEquals(check action.request.headers, []);
    test:assertEquals(check action.retryPolicy.deadline, "300s");
    test:assertEquals(check action.retryPolicy.retryInterval, "30s");
    JobSpec off = spec();
    off.enabled = false;
    test:assertEquals((check jobPayload("amplify", off))["state"], "disabled");
}

@test:Config
function testPayloadLimits() {
    string longPath = "";
    foreach int i in 0 ..< 250 {
        longPath += "a";
    }
    string longBody = "";
    foreach int i in 0 ..< 1025 {
        longBody += "x";
    }
    JobSpec s = spec();
    s.uri = "http://amplify-jobs:9091/" + longPath;
    test:assertTrue(jobPayload("amplify", s) is error, "uri over 256");
    s = spec();
    s.uri = "ftp://jobs/runs";
    test:assertTrue(jobPayload("amplify", s) is error, "scheme");
    s = spec();
    s.body = longBody;
    test:assertTrue(jobPayload("amplify", s) is error, "body over 1024");
    s.body = longBody.substring(0, 1024);
    test:assertTrue(jobPayload("amplify", s) is map<json>, "body of exactly 1024");
    s = spec();
    s.id = "a b";
    test:assertTrue(jobPayload("amplify", s) is error, "id pattern");
    s = spec();
    s.headers = [{name: "X-A", value: "1"}];
    test:assertTrue(jobPayload("amplify", s) is error, "header name under 5");
    s = spec();
    s.retryCount = 11;
    test:assertTrue(jobPayload("amplify", s) is error, "retryCount over 10");
    s = spec();
    s.schedule = "@every 0s";
    test:assertTrue(jobPayload("amplify", s) is error, "schedule");
    test:assertTrue(jobPayload("x", spec()) is error, "collection id under 3");
}

@test:Config
function testSameJobNormalisesDurations() returns error? {
    map<json> desired = check jobPayload("amplify", spec());
    // How the scheduler echoes a stored job: Go duration strings, omitted empty body/headers.
    json stored = {
        id: "amplify-run",
        name: "Amplify Run",
        collectionId: "amplify",
        state: "enabled",
        schedule: "@every 5m",
        updated: "2026-10-16T00:00:00Z",
        action: {
            'type: "HTTP",
            request: {method: "POST", uri: "http://amplify-jobs:9091/runs"},
            retryPolicy: {retryCount: 1, retryInterval: "30s", deadline: "5m0s"}
        }
    };
    test:assertTrue(sameJob(stored, desired));
    JobSpec changed = spec();
    changed.schedule = "@every 10m";
    test:assertFalse(sameJob(stored, check jobPayload("amplify", changed)));
    changed = spec();
    changed.deadlineSeconds = 600;
    test:assertFalse(sameJob(stored, check jobPayload("amplify", changed)));
}

// ---- Client against a scheduler double -------------------------------------------------------------

isolated map<json> storedJobs = {};
isolated string[] calls = [];

isolated function note(string c) {
    lock {
        calls.push(c);
    }
}

service / on new http:Listener(9597) {
    resource function get collections/[string id]() returns http:Ok|http:NotFound {
        note("GET /collections/" + id);
        return http:NOT_FOUND;
    }

    resource function post collections(@http:Payload json body) returns http:Created|error {
        note("POST /collections");
        return {body: check body.id};
    }

    resource function get jobs/[string id]() returns http:Response {
        note("GET /jobs/" + id);
        json? job;
        lock {
            job = storedJobs[id].clone();
        }
        http:Response res = new;
        if job is () {
            res.statusCode = 404;
        } else {
            res.statusCode = 200;
            res.setJsonPayload(job);
            res.setHeader("ETag", "\"v1\"");
        }
        return res;
    }

    resource function post jobs(@http:Payload map<json> body) returns http:Created|http:BadRequest {
        note("POST /jobs");
        if body.toJsonString().length() > 4096 {
            return http:BAD_REQUEST;
        }
        lock {
            storedJobs[<string>body["id"]] = body.clone();
        }
        return <http:Created>{body: body["id"]};
    }

    resource function patch jobs/[string id](@http:Header {name: "If-Match"} string? ifMatch,
            @http:Payload map<json> body) returns http:NoContent|http:PreconditionFailed {
        note("PATCH /jobs/" + id + " If-Match " + (ifMatch ?: "-"));
        if ifMatch != "\"v1\"" {
            return http:PRECONDITION_FAILED;
        }
        lock {
            storedJobs[id] = body.clone();
        }
        return http:NO_CONTENT;
    }
}

function takeCalls() returns string[] {
    lock {
        string[] out = calls;
        calls = [];
        return out.clone();
    }
}

@test:Config
function testClientUpsertFlow() returns error? {
    Client c = check new ("http://localhost:9597", 5);
    check c.ensureCollection("amplify", "Amplify");
    test:assertEquals(takeCalls(), ["GET /collections/amplify", "POST /collections"]);

    test:assertEquals(check c.upsertJob("amplify", spec()), "CREATED");
    test:assertEquals(takeCalls(), ["GET /jobs/amplify-run", "POST /jobs"]);

    test:assertEquals(check c.upsertJob("amplify", spec()), "UNCHANGED");
    test:assertEquals(takeCalls(), ["GET /jobs/amplify-run"]);

    JobSpec changed = spec();
    changed.schedule = "*/10 * * * *";
    test:assertEquals(check c.upsertJob("amplify", changed), "UPDATED");
    test:assertEquals(takeCalls(), ["GET /jobs/amplify-run", "PATCH /jobs/amplify-run If-Match \"v1\""]);
    test:assertEquals(c.breakerState(), "CLOSED");

    // A payload over the limits never leaves the client.
    changed.uri = "notaurl";
    test:assertTrue(c.upsertJob("amplify", changed) is error);
    test:assertEquals(takeCalls(), []);
}

@test:Config
function testClientSchedulerDown() returns error? {
    Client c = check new ("http://localhost:9596", 1);
    test:assertTrue(c.ensureCollection("amplify", "Amplify") is error);
    test:assertTrue(c.upsertJob("amplify", spec()) is error);
}
