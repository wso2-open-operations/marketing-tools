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
import mock_linkedin.store;

import ballerina/http;
import ballerina/log;

# Health check for liveness and readiness probes.
@display {
    label: "Mock LinkedIn Health",
    id: "linkedin/mock-health"
}
service /health on apiListener {

    # Reports that the mock is up.
    #
    # + return - Status
    isolated resource function get .() returns map<string> => {status: HEALTH_STATUS_UP};
}

# Admin endpoints for tests: see what the mock has stored, and wipe it between runs.
# Attached only when `enableMockAdmin` is true, and then only for a caller holding the internal key.
# Never expose these outside local testing.
@display {
    label: "Mock LinkedIn Admin",
    id: "linkedin/mock-admin"
}
final http:Service mockAdminService = service object {

    # Lists every post the mock holds.
    #
    # + req - Request, carrying the internal key
    # + return - Posts, oldest first, or 401 without the key
    isolated resource function get posts(http:Request req) returns store:Post[]|http:Unauthorized {
        http:Unauthorized? denied = requireAdminKey(req);
        if denied is http:Unauthorized {
            return denied;
        }
        return store:listPosts();
    }

    # Clears tokens, codes, posts, uploads and rate counters.
    #
    # + req - Request, carrying the internal key
    # + return - 204, or 401 without the key
    isolated resource function post reset(http:Request req) returns http:NoContent|http:Unauthorized {
        http:Unauthorized? denied = requireAdminKey(req);
        if denied is http:Unauthorized {
            return denied;
        }
        store:reset();
        log:printInfo("Mock state reset");
        return http:NO_CONTENT;
    }
};

# Attaches the admin endpoints. Fail-closed: with the flag on but no usable key configured, they are
# not attached at all, so a missing secret can never leave them open.
#
# `init` passes the configured values. The parameters let the tests drive both states without changing
# the config; the resources themselves check the same `mockAdminKey`.
#
# + httpListener - Listener to attach to
# + enabled - `enableMockAdmin`
# + adminKey - `mockAdminKey`
# + return - An error if the endpoints could not be attached
function attachMockAdmin(http:Listener httpListener, boolean enabled, string adminKey) returns error? {
    if !enabled {
        return;
    }
    if !isAdminKeyConfigured(adminKey) {
        log:printError(string `Mock admin endpoints not attached: enableMockAdmin is true but mockAdminKey ` +
                string `is shorter than ${MIN_ADMIN_KEY_LENGTH} characters`);
        return;
    }
    check httpListener.attach(mockAdminService, MOCK_ADMIN_BASE_PATH);
    log:printInfo("Mock admin endpoints enabled", basePath = MOCK_ADMIN_BASE_PATH);
}

# Whether a key is long enough to gate the admin endpoints. A blank key is the "admin off" default.
#
# + adminKey - `mockAdminKey`
# + return - True when the key is long enough
isolated function isAdminKeyConfigured(string adminKey) returns boolean =>
    adminKey.trim().length() >= MIN_ADMIN_KEY_LENGTH;

# Checks the internal key on an admin request.
#
# + req - Inbound request
# + return - A 401 response when the key is missing or wrong
isolated function requireAdminKey(http:Request req) returns http:Unauthorized? {
    string|http:HeaderNotFoundError presented = req.getHeader(ADMIN_KEY_HEADER);
    if presented is string && keyMatches(presented, mockAdminKey) {
        return ();
    }
    // Whether a key was sent, never the key itself.
    log:printWarn("Mock admin call refused", route = req.method + " " + req.rawPath, keySent = presented is string);
    return <http:Unauthorized>{body: {message: MSG_ADMIN_UNAUTHORIZED}};
}

# Compares a presented key with the configured one without an early exit, so a failed attempt says
# nothing about how much of the key was right. Both sides are trimmed: a secret mounted from a file
# often ends in a newline.
#
# + presented - Key from the request header
# + configured - `mockAdminKey`
# + return - True when equal
isolated function keyMatches(string presented, string configured) returns boolean {
    byte[] a = presented.trim().toBytes();
    byte[] b = configured.trim().toBytes();
    int diff = a.length() ^ b.length();
    int length = a.length() > b.length() ? a.length() : b.length();
    foreach int i in 0 ..< length {
        int x = i < a.length() ? a[i] : 0;
        int y = i < b.length() ? b[i] : 0;
        diff = diff | (x ^ y);
    }
    return diff == 0;
}

function init() returns error? {
    check attachMockAdmin(apiListener, enableMockAdmin, mockAdminKey);
    log:printInfo("Mock LinkedIn started", apiPort = apiPort, wwwPort = wwwPort,
            adminEnabled = enableMockAdmin, maxUploadBytes = maxUploadBytes);
}
