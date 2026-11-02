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

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;

const int SLOW_CHAT_STUB_PORT = 18212;
// Nothing listens here, so a call is refused before it can reach Chat
const int CLOSED_PORT = 18213;

listener http:Listener slowChatListener = new (SLOW_CHAT_STUB_PORT);

service /v1/spaces on slowChatListener {
    // Answers after the client has given up: Chat may have accepted the message by then
    resource function post [string space]/messages(@http:Payload json body) returns http:Ok {
        runtime:sleep(4);
        return <http:Ok>{body: {name: string `spaces/${space}/messages/m1`}};
    }
}

// Regression (PR 97 review): a timeout reported retryable made the outbox post the Club card twice.
@test:Config
function webhookTimeoutIsNotRetryable() returns error? {
    WebhookClient chat = check new ({
        webhookUrl: string `http://localhost:${SLOW_CHAT_STUB_PORT}/v1/spaces/slow/messages?key=k`,
        timeoutSeconds: 1
    });
    ChatMessage|ChatError result = chat.post({text: "x"}, "campaign-c1");
    if result !is ChatError {
        test:assertFail("expected a timeout error");
    }
    test:assertEquals(result.detail(), {code: "UNAVAILABLE", httpStatus: (), retryable: false});
}

@test:Config
function webhookRefusedConnectionStaysRetryable() returns error? {
    WebhookClient chat = check new ({
        webhookUrl: string `http://localhost:${CLOSED_PORT}/v1/spaces/x/messages?key=k`,
        timeoutSeconds: 2
    });
    ChatMessage|ChatError result = chat.post({text: "x"}, "campaign-c1");
    if result !is ChatError {
        test:assertFail("expected a connection error");
    }
    test:assertEquals(result.detail(), {code: "UNAVAILABLE", httpStatus: (), retryable: true});
}
