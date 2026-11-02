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
import ballerina/test;

final http:Client stubClient = check new (string `http://localhost:${port}`);

@test:Config
function answersLikeChatAndKeepsTheCard() returns error? {
    http:Response res = check stubClient->post(
        "/v1/spaces/dev/messages?key=k&token=t&threadKey=campaign-c1&messageReplyOption=REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD",
        {cardsV2: []});
    test:assertEquals(res.statusCode, 200);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.thread.name, "spaces/dev/threads/campaign-c1");
    json[] seen = check stubClient->get("/stub/messages");
    test:assertEquals(check seen[seen.length() - 1].threadKey, "campaign-c1");
}

@test:Config {dependsOn: [answersLikeChatAndKeepsTheCard]}
function scriptedFailures() returns error? {
    http:Response bad = check stubClient->post("/v1/spaces/status-400/messages", {text: "x"});
    test:assertEquals(bad.statusCode, 400);
    http:Response ok = check stubClient->put("/stub/status/429", {});
    test:assertEquals(ok.statusCode, 200);
    http:Response busy = check stubClient->post("/v1/spaces/dev/messages", {text: "x"});
    test:assertEquals(busy.statusCode, 429);
    http:Response reset = check stubClient->put("/stub/status/200", {});
    test:assertEquals(reset.statusCode, 200);
    http:Response back = check stubClient->post("/v1/spaces/dev/messages", {text: "x"});
    test:assertEquals(back.statusCode, 200);
    http:Response nope = check stubClient->put("/stub/status/99", {});
    test:assertEquals(nope.statusCode, 400);
}
