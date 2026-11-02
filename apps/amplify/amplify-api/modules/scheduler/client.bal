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

// Typed client for the akornatskyy/scheduler REST API (v1.7.8, ADR-026), behind a timeout and a circuit
// breaker. The scheduler API has no authentication: it is reachable on the internal network only and
// amplify-api is its only API caller. Jobs are upserted by stable id, so every call is safe to repeat.

import amplify_common.resilience;

import ballerina/http;

# What an upsert did.
public type UpsertResult "CREATED"|"UPDATED"|"UNCHANGED";

# The scheduler operations amplify-api uses (the test seam: unit tests pass a fake).
public type Api isolated object {
    # Creates the collection when it's missing.
    #
    # + id - Collection id
    # + name - Display name
    # + correlationId - Sent as `X-Correlation-ID`
    # + return - An error when the scheduler can't be reached or refuses
    public isolated function ensureCollection(string id, string name, string? correlationId = ()) returns error?;

    # Creates or updates one job so it matches `spec`.
    #
    # + collectionId - Collection id
    # + spec - Desired job
    # + correlationId - Sent as `X-Correlation-ID`
    # + return - What changed, or an error
    public isolated function upsertJob(string collectionId, JobSpec spec, string? correlationId = ())
            returns UpsertResult|error;

    # Circuit breaker state.
    #
    # + return - `CLOSED`, `HALF_OPEN` or `OPEN`
    public isolated function breakerState() returns resilience:BreakerState;
};

# HTTP client for the scheduler.
public isolated class Client {
    *Api;

    private final http:Client http;

    # Builds the client.
    #
    # + url - Scheduler base URL, for example `http://scheduler:8080`
    # + timeoutSeconds - Per-call timeout
    # + settings - Breaker and pool settings
    # + return - An error when the URL is invalid
    public isolated function init(string url, decimal timeoutSeconds, resilience:HttpResilience settings = {})
            returns error? {
        self.http = check new (url, resilience:clientConfig(settings, timeoutSeconds));
    }

    public isolated function ensureCollection(string id, string name, string? correlationId = ()) returns error? {
        check checkId("collectionId", id);
        map<string> headers = resilience:correlationHeaders(correlationId);
        http:Response found = check self.http->get(string `/collections/${id}`, headers);
        if found.statusCode == http:STATUS_OK {
            return;
        }
        if found.statusCode != http:STATUS_NOT_FOUND {
            return failure("GET /collections", found);
        }
        http:Response created = check self.http->post("/collections", {id, name, state: "enabled"}, headers);
        // 409: another caller created it first.
        if created.statusCode != http:STATUS_CREATED && created.statusCode != http:STATUS_CONFLICT {
            return failure("POST /collections", created);
        }
    }

    public isolated function upsertJob(string collectionId, JobSpec spec, string? correlationId = ())
            returns UpsertResult|error {
        map<json> payload = check jobPayload(collectionId, spec);
        map<string> headers = resilience:correlationHeaders(correlationId);
        string path = string `/jobs/${spec.id}`;
        http:Response found = check self.http->get(path, headers);
        if found.statusCode == http:STATUS_NOT_FOUND {
            http:Response created = check self.http->post("/jobs", payload, headers);
            if created.statusCode == http:STATUS_CREATED {
                return "CREATED";
            }
            if created.statusCode != http:STATUS_CONFLICT {
                return failure("POST /jobs", created);
            }
            // Created concurrently: read it again and patch below.
            found = check self.http->get(path, headers);
        }
        if found.statusCode != http:STATUS_OK {
            return failure("GET " + path, found);
        }
        if sameJob(check found.getJsonPayload(), payload) {
            return "UNCHANGED";
        }
        map<string> patchHeaders = headers.clone();
        string|http:HeaderNotFoundError etag = found.getHeader("ETag");
        if etag is string {
            patchHeaders["If-Match"] = etag;
        }
        http:Response patched = check self.http->patch(path, payload, patchHeaders);
        if patched.statusCode == http:STATUS_PRECONDITION_FAILED {
            return error(string `scheduler job ${spec.id} changed during the update; sync again`);
        }
        if patched.statusCode != http:STATUS_NO_CONTENT {
            return failure("PATCH " + path, patched);
        }
        return "UPDATED";
    }

    public isolated function breakerState() returns resilience:BreakerState => resilience:breakerState(self.http);
}

# An error for an unexpected scheduler answer, with the scheduler's validation message when it sent one.
#
# + call - What was called
# + res - The answer
# + return - The error
isolated function failure(string call, http:Response res) returns error {
    string detail = "";
    json|error body = res.getJsonPayload();
    if body is json && body != () {
        string text = body.toJsonString();
        detail = ": " + (text.length() > 300 ? text.substring(0, 300) : text);
    }
    return error(string `scheduler ${call} answered HTTP ${res.statusCode}${detail}`);
}
