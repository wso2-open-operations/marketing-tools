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

// M6a webhook tests (no DB): the real `WebhookChat` + `googlechat:WebhookClient` against a scripted Chat
// stub, through the whole Run (in-memory outbox and store). Covers 200, 400 (bad card → FAILED, no retry
// storm), 429 (backoff) and 5xx (retry, then sent).

import amplify_common.events;
import amplify_common.googlechat;
import amplify_common.types;

import ballerina/http;
import ballerina/test;
import ballerina/time;

const int WEBHOOK_STUB_PORT = 9297;

type StubState record {|
    int status;
    int hits;
    json lastBody;
    string lastQuery;
|};

isolated StubState stubState = {status: 200, hits: 0, lastBody: (), lastQuery: ""};

isolated function setStubStatus(int status) {
    lock {
        stubState.status = status;
    }
}

isolated function stub() returns StubState {
    lock {
        return stubState.clone();
    }
}

# Answers like Chat with whatever status the test asked for.
service /v1/spaces on new http:Listener(WEBHOOK_STUB_PORT) {
    resource function post [string space]/messages(http:Request req, @http:Payload json body)
            returns http:Response {
        int status;
        int n;
        lock {
            stubState.hits += 1;
            stubState.lastBody = body.clone();
            stubState.lastQuery = req.getQueryParams().toString();
            status = stubState.status;
            n = stubState.hits;
        }
        http:Response res = new;
        res.statusCode = status;
        if status == 200 {
            res.setJsonPayload({name: string `spaces/${space}/messages/m${n}`,
                thread: {name: string `spaces/${space}/threads/t${n}`}});
        } else {
            res.setJsonPayload({'error: {code: status, message: "scripted"}});
        }
        return res;
    }
}

function webhookWorld() returns World|error {
    World w = harness();
    // Throttle 0: tests don't wait out the 1 rps space quota.
    w.deps.chat = new WebhookChat(check new googlechat:WebhookClient({
        webhookUrl: string `http://localhost:${WEBHOOK_STUB_PORT}/v1/spaces/dev/messages?key=k&token=SECRET-TOKEN`,
        timeoutSeconds: 5
    }), "dev-test", 0);
    RunConfig cfg = check TEST_CONFIG.cloneWithType();
    cfg.cardAvatarUrl = "https://media.wso2.com/amplify-avatar.png";
    w.deps.config = cfg.cloneReadOnly();
    return w;
}

function enqueueCampaign(World w) returns [string, int] {
    string cid = types:newUuidV7();
    w.mem.putCampaign(openCampaign(cid, time:utcNow()));
    return [cid, w.queue.enqueue(events:CAMPAIGN_REGISTERED, registered(cid))];
}

@test:Config {groups: ["webhook"]}
function webhook200StoresMessageAndThreadName() returns error? {
    World w = check webhookWorld();
    setStubStatus(200);
    [string, int] [cid, id] = enqueueCampaign(w);
    int before = stub().hits;
    _ = check run(w);
    StubState s = stub();
    test:assertEquals(s.hits, before + 1);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    test:assertTrue(s.lastQuery.includes(string `campaign-${cid}`), "threadKey sent");
    test:assertTrue(s.lastQuery.includes("REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD"));
    json card = check s.lastBody.cardsV2;
    string cardJson = card.toJsonString();
    test:assertTrue(cardJson.includes(string `https://one.wso2.com/amplify/celebrate?share=${cid}`), "openLink");
    test:assertTrue(cardJson.includes("\"imageType\":\"CIRCLE\""), "header avatar");
    test:assertTrue(cardJson.includes("\"altText\""), "image altText");
    var a = check w.mem.announcement(cid);
    if a is () {
        return error("no announcement");
    }
    test:assertTrue(a.sentAt !is ());
    test:assertEquals(a.chatMessageName, string `spaces/dev/messages/m${s.hits}`);
    test:assertEquals(a.chatThreadName, string `spaces/dev/threads/t${s.hits}`);
}

@test:Config {groups: ["webhook"], dependsOn: [webhook200StoresMessageAndThreadName]}
function webhook400FailsOnceWithoutRetryStorm() returns error? {
    World w = check webhookWorld();
    setStubStatus(400);
    [string, int] [cid, id] = enqueueCampaign(w);
    int before = stub().hits;
    _ = check run(w);
    [string, int, string?] [status, _, lastError] = w.queue.statusOf(id);
    test:assertEquals(status, "FAILED", "a bad card is final on the first answer");
    test:assertFalse((lastError ?: "").includes("SECRET-TOKEN"), "URL never stored");
    var a = check w.mem.announcement(cid);
    test:assertTrue(a !is () && a.failedAt !is () && (a.lastError ?: "").includes("REJECTED"));
    w.queue.makeAllDue();
    _ = check run(w);
    _ = check run(w);
    test:assertEquals(stub().hits, before + 1, "exactly one call: no retry storm");
}

@test:Config {groups: ["webhook"], dependsOn: [webhook400FailsOnceWithoutRetryStorm]}
function webhook429BacksOffThenSends() returns error? {
    World w = check webhookWorld();
    setStubStatus(429);
    [string, int] [cid, id] = enqueueCampaign(w);
    int before = stub().hits;
    RunReport r = check run(w);
    test:assertEquals(r.retried, 1);
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING");
    _ = check run(w);
    test:assertEquals(stub().hits, before + 1, "backoff: not due again in the same minute");
    setStubStatus(200);
    w.queue.makeAllDue();
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "DONE");
    var a = check w.mem.announcement(cid);
    test:assertTrue(a !is () && a.sentAt !is ());
}

@test:Config {groups: ["webhook"], dependsOn: [webhook429BacksOffThenSends]}
function webhook5xxRetriesThenFailsAfterMaxAttempts() returns error? {
    World w = check webhookWorld();
    setStubStatus(503);
    [string, int] [cid, id] = enqueueCampaign(w);
    int before = stub().hits;
    _ = check run(w);
    test:assertEquals(w.queue.statusOf(id)[0], "PENDING", "5xx is retried");
    foreach int i in 2 ... TEST_CONFIG.maxAttempts {
        w.queue.makeAllDue();
        _ = check run(w);
    }
    test:assertEquals(w.queue.statusOf(id)[0], "FAILED");
    test:assertEquals(stub().hits, before + TEST_CONFIG.maxAttempts, "one call per attempt");
    var a = check w.mem.announcement(cid);
    test:assertTrue(a !is () && a.failedAt !is () && (a.lastError ?: "").includes("UNAVAILABLE"));
    // Stored texts (outbox `last_error` and announcement) never carry the webhook key, token or path.
    foreach string stored in [(a is () ? "" : a.lastError ?: ""), w.queue.statusOf(id)[2] ?: ""] {
        foreach string secret in ["SECRET-TOKEN", "token=", "key=", "/v1/spaces/"] {
            test:assertFalse(stored.includes(secret), string `stored error text leaks ${secret}`);
        }
    }
    setStubStatus(200);
}
