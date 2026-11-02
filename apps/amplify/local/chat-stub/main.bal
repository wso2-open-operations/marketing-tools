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

// Local Google Chat incoming-webhook stub (plan M6a). Accepts `POST /v1/spaces/{space}/messages` like
// chat.googleapis.com, logs the card JSON, and answers like Chat: 200 with `name` and `thread.name`.
// Never used outside the local stack and tests.
//
// Scripted failures, for trying the outbox paths by hand or from tests:
//   - per call: space `status-400`, `status-429`, `status-500`, `status-503` answers with that status
//   - sticky:   PUT /stub/status/{code}   (200 resets); `defaultStatus` sets it at start-up
//   - inspect:  GET /stub/messages        (newest last, at most `keepMessages`)
//   - reset:    DELETE /stub/messages
// The query string carries `key` / `token` in the real URL: it's never logged here either.

import ballerina/http;
import ballerina/log;

# Listener port.
configurable int port = 9095;
# Status every call gets unless a space or `PUT /stub/status` says otherwise.
configurable int defaultStatus = 200;
# How many received messages `GET /stub/messages` keeps.
configurable int keepMessages = 50;

# One message the stub received.
type Received record {|
    # Space from the path
    string space;
    # `threadKey` query parameter
    string? threadKey;
    # `messageReplyOption` query parameter
    string? messageReplyOption;
    # Status the stub answered with
    int status;
    # Message body (the card)
    json body;
|};

isolated int stickyStatus = defaultStatus;
isolated record {|int counter; Received[] received;|} inbox = {counter: 0, received: []};

listener http:Listener stubListener = new (port);

@display {label: "Chat stub", id: "amplify/chat-stub"}
service / on stubListener {

    resource function post v1/spaces/[string space]/messages(http:Request req, @http:Payload json body,
            string? threadKey = (), string? messageReplyOption = ()) returns http:Response {
        int status = statusFor(space);
        int n;
        lock {
            inbox.counter += 1;
            n = inbox.counter;
            inbox.received.push({space, threadKey, messageReplyOption, status, body: body.clone()});
            if inbox.received.length() > keepMessages {
                _ = inbox.received.shift();
            }
        }
        log:printInfo("Chat stub received a message", space = space, threadKey = threadKey,
                messageReplyOption = messageReplyOption, status = status, card = body.toJsonString());
        http:Response res = new;
        res.statusCode = status;
        if status == http:STATUS_OK {
            res.setJsonPayload(messageResponse(space, threadKey, n));
        } else {
            res.setJsonPayload({'error: {code: status, message: "chat-stub scripted failure", status: "STUB"}});
        }
        return res;
    }

    resource function put stub/status/[int code]() returns http:Ok|http:BadRequest {
        if code < 200 || code > 599 {
            return <http:BadRequest>{body: {message: "status must be 200..599"}};
        }
        lock {
            stickyStatus = code;
        }
        log:printInfo("Chat stub status set", status = code);
        return <http:Ok>{body: {status: code}};
    }

    resource function get stub/messages() returns json {
        lock {
            return inbox.received.clone().toJson();
        }
    }

    resource function delete stub/messages() returns http:NoContent {
        lock {
            inbox.received = [];
        }
        return {};
    }
}

# Status for a call: a `status-NNN` space wins, then the sticky status.
#
# + space - Space from the path
# + return - HTTP status to answer with
isolated function statusFor(string space) returns int {
    if space.startsWith("status-") {
        int|error code = int:fromString(space.substring(7));
        if code is int && code >= 200 && code <= 599 {
            return code;
        }
    }
    lock {
        return stickyStatus;
    }
}

# The body Chat returns for a created message.
#
# + space - Space
# + threadKey - Thread key, if sent
# + n - Message counter
# + return - `{name, thread: {name}}`
isolated function messageResponse(string space, string? threadKey, int n) returns json => {
    name: string `spaces/${space}/messages/stub-${n}`,
    thread: {name: string `spaces/${space}/threads/${threadKey ?: string `stub-${n}`}`}
};
