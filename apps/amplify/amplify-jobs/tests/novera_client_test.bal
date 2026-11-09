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


import amplify_domain.announcements;

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;

@test:Config
function noveraClientRefusesPlainHttpUnlessTheLocalFlagIsSet() {
    string url = "http://host.docker.internal:3003/internal/notifications";
    NoveraClient|error strict = new (url, "http://host.docker.internal:3003/token", "mock", "mock", [], 5);
    test:assertTrue(strict is error);
    NoveraClient|error local = new (url, "http://host.docker.internal:3003/token", "mock", "mock", [], 5,
        allowInsecureHttp = true);
    test:assertTrue(local is NoveraClient);
    // The flag never relaxes an https check, and never accepts another scheme.
    test:assertTrue((new NoveraClient("ftp://x.example/n", "https://x.example/t", "a", "b", [], 5,
        allowInsecureHttp = true)) is error);
}

@test:Config
function noveraTokenEndpointDownIsARetryableUnavailableNotAStartUpFailure() {
    // Built without any network call, so a Novera outage can't stop amplify-jobs from starting.
    NoveraClient|error built = new ("http://127.0.0.1:1/internal/notifications", "http://127.0.0.1:1/token", "mock",
        "mock", [], 2, allowInsecureHttp = true);
    test:assertTrue(built is NoveraClient);
    if built is NoveraClient {
        string|NoveraError? result = built.notify({'source: "amplify", title: "T", subtitle: "S", body: "B",
            button: {url: "https://one.wso2.com", label: "Amplify"}}, "amplify:c1", ());
        test:assertTrue(result is NoveraError);
        if result is NoveraError {
            test:assertEquals(result.detail().code, "UNAVAILABLE");
            test:assertTrue(result.detail().retryable);
            test:assertEquals(result.detail().delivered, "NO", "no request reached Novera");
        }
    }
}

// A Novera stand-in: a token endpoint and a notifications endpoint that answers whatever status the test sets.
const int NOVERA_STUB_PORT = 18299;
isolated int noveraStubStatus = 202;
isolated string? noveraStubIdempotencyKey = ();
# Body of an accepted notification (`()` = none, like an older Novera)
isolated json noveraStubAcceptBody = ();
# Stats answers by broadcast id: `[status, body]`
isolated map<[int, json]> noveraStubStats = {};
isolated string? noveraStubStatsPath = ();

listener http:Listener noveraStub = new (NOVERA_STUB_PORT);

service / on noveraStub {
    isolated resource function post token() returns json => {access_token: "stub-token", token_type: "Bearer", expires_in: 3600};

    isolated resource function post internal/notifications(http:Request req) returns http:Response {
        string|http:HeaderNotFoundError key = req.getHeader("Idempotency-Key");
        lock {
            noveraStubIdempotencyKey = key is string ? key : ();
        }
        int status;
        lock {
            status = noveraStubStatus;
        }
        if status == 0 {
            // Answer only after the client gave up: the request arrived, the answer was lost.
            runtime:sleep(2);
            status = 202;
        }
        http:Response res = new;
        res.statusCode = status;
        json body;
        lock {
            body = noveraStubAcceptBody.clone();
        }
        if body !is () {
            res.setJsonPayload(body);
        }
        return res;
    }

    isolated resource function get internal/notifications/[string id]/stats(http:Request req) returns http:Response {
        lock {
            noveraStubStatsPath = req.rawPath;
        }
        [int, json]? answer;
        lock {
            answer = noveraStubStats[id].clone();
        }
        http:Response res = new;
        if answer is () {
            res.statusCode = 404;
            return res;
        }
        res.statusCode = answer[0];
        if answer[1] !is () {
            res.setJsonPayload(answer[1]);
        }
        return res;
    }
}

function noveraAnswers(int status, decimal timeoutSeconds = 5) returns NoveraError? {
    string|NoveraError? result = noveraAccepts(status, timeoutSeconds);
    return result is string ? () : result;
}

function noveraAccepts(int status, decimal timeoutSeconds = 5) returns string|NoveraError? {
    lock {
        noveraStubStatus = status;
    }
    NoveraClient|error novera = new (string `http://127.0.0.1:${NOVERA_STUB_PORT}/internal/notifications`,
        string `http://127.0.0.1:${NOVERA_STUB_PORT}/token`, "id", "secret", [], timeoutSeconds, allowInsecureHttp = true);
    if novera is error {
        return noveraError("UNAVAILABLE", "client not built", (), false, "NO");
    }
    return novera.notify({'source: "amplify", title: "T", subtitle: "S", body: "B",
        button: {url: "https://one.wso2.com", label: "Amplify"}}, "amplify:c1", ());
}

@test:Config
function noveraGetsTheIdempotencyKeyAsAHeader() {
    test:assertEquals(noveraAnswers(202), ());
    lock {
        test:assertEquals(noveraStubIdempotencyKey, "amplify:c1", "the key rides in a header, not the body");
    }
}

@test:Config
function noveraStatusesAreClassifiedByWhoCanFixThem() {
    test:assertEquals(noveraAnswers(202), ());
    // A bad card is permanent; a refused credential or a limit is something an operator or time fixes.
    NoveraError? bad = noveraAnswers(400);
    test:assertTrue(bad is NoveraError && bad.detail().code == "REJECTED" && !bad.detail().retryable);
    foreach int status in [401, 403] {
        NoveraError? refused = noveraAnswers(status);
        test:assertTrue(refused is NoveraError && refused.detail().code == "UNAVAILABLE" && refused.detail().retryable,
                string `HTTP ${status} from Novera is retryable`);
    }
    NoveraError? limited = noveraAnswers(429);
    test:assertTrue(limited is NoveraError && limited.detail().code == "RATE_LIMITED" && limited.detail().retryable);
    NoveraError? down = noveraAnswers(503);
    test:assertTrue(down is NoveraError && down.detail().code == "UNAVAILABLE" && down.detail().retryable);
}

@test:Config
function noveraErrorsSayWhetherTheCardMayHaveGoneOut() {
    // Definitely not sent: retried automatically.
    foreach int status in [400, 401, 403, 429, 503] {
        NoveraError? e = noveraAnswers(status);
        test:assertTrue(e is NoveraError && e.detail().delivered == "NO", string `HTTP ${status} sent nothing`);
    }
    // Novera or the gateway may have handed the card on: never retried automatically.
    foreach int status in [500, 502, 504, 505] {
        NoveraError? e = noveraAnswers(status);
        test:assertTrue(e is NoveraError && e.detail().delivered == "UNKNOWN" && !e.detail().retryable
                && e.detail().code == "OUTCOME_UNKNOWN", string `HTTP ${status} may have sent`);
    }
}

@test:Config
function aLostAnswerAfterTheRequestWasSentIsDeliveryUnknown() {
    NoveraError? e = noveraAnswers(0, 1);
    test:assertTrue(e is NoveraError, "the client timed out");
    if e is NoveraError {
        test:assertEquals(e.detail().delivered, "UNKNOWN");
        test:assertEquals(e.detail().code, "OUTCOME_UNKNOWN");
        test:assertFalse(e.detail().retryable);
        test:assertEquals(e.detail().httpStatus, ());
    }
}

@test:Config
function buttonUrlSettingIsCheckedAtStartUp() {
    test:assertEquals(validateNoveraButtonUrl("", false), (), "empty: announcements wait, start-up goes on");
    test:assertEquals(validateNoveraButtonUrl("https://one.wso2.com/amplify/celebrate?share={campaignId}", false), ());
    error? noPlaceholder = validateNoveraButtonUrl("https://one.wso2.com/amplify/celebrate", false);
    test:assertTrue(noPlaceholder is error && noPlaceholder.message().startsWith("noveraButtonUrl is invalid"));
    test:assertTrue(validateNoveraButtonUrl("http://one.wso2.com/amplify/celebrate?share={campaignId}", false) is error,
            "a non-https template is refused");
    test:assertEquals(validateNoveraButtonUrl("http://localhost:3000/amplify/celebrate?share={campaignId}", true), (),
            "http only on the local stack");
    test:assertTrue(validateNoveraButtonUrl("https://x.example/{campaignId}/{other}", false) is error);
}

@test:Config
function aRefusedConnectionMeansNothingWasSentAndIsRetryable() {
    // The token endpoint answers; the notify port is closed, so the connection is refused before any request.
    NoveraClient|error novera = new ("http://127.0.0.1:1/internal/notifications",
        string `http://127.0.0.1:${NOVERA_STUB_PORT}/token`, "id", "secret", [], 3, allowInsecureHttp = true);
    test:assertTrue(novera is NoveraClient);
    if novera is NoveraClient {
        string|NoveraError? e = novera.notify({'source: "amplify", title: "T", subtitle: "S", body: "B",
            button: {url: "https://one.wso2.com", label: "Amplify"}}, "amplify:c1", ());
        test:assertTrue(e is NoveraError);
        if e is NoveraError {
            test:assertEquals(e.detail().delivered, "NO", "a refused connection cannot have carried the request");
            test:assertTrue(e.detail().retryable);
            test:assertEquals(e.detail().code, "UNAVAILABLE");
        }
    }
}

@test:Config
function onlyConnectFailuresAreSeenAsBeforeSending() {
    test:assertTrue(failedBeforeSending(error("Connection refused: /127.0.0.1:1")));
    test:assertTrue(failedBeforeSending(error("Something failed", error("java.net.UnknownHostException: novera.example"))));
    test:assertFalse(failedBeforeSending(error("Idle timeout triggered before initiating inbound response")));
    test:assertFalse(failedBeforeSending(error("Connection reset by peer")));
}

function stubNovera() returns NoveraClient|error => new (string `http://127.0.0.1:${NOVERA_STUB_PORT}/internal/notifications`,
    string `http://127.0.0.1:${NOVERA_STUB_PORT}/token`, "id", "secret", [], 5, allowInsecureHttp = true);

@test:Config
function anAcceptedCardReturnsNoverasBroadcastIdWhenThereIsOne() {
    lock {
        noveraStubAcceptBody = {accepted: true, notificationId: "0b9a7c1e-1f2d-4c3b-9a8e-7d6c5b4a3f21"};
    }
    test:assertEquals(noveraAccepts(202), "0b9a7c1e-1f2d-4c3b-9a8e-7d6c5b4a3f21");
    lock {
        noveraStubAcceptBody = {accepted: true};
    }
    test:assertEquals(noveraAccepts(202), (), "an older Novera: accepted, no id");
    lock {
        noveraStubAcceptBody = {accepted: true, notificationId: "../../admin"};
    }
    test:assertEquals(noveraAccepts(202), (), "an id that isn't URL-safe is ignored, the card still counts as sent");
    lock {
        noveraStubAcceptBody = ();
    }
    test:assertEquals(noveraAccepts(202), (), "no body at all");
}

@test:Config
function statsAreReadFromTheBroadcastsStatsPath() returns error? {
    lock {
        noveraStubStats["n-ok"] = [200, {notificationId: "n-ok", 'source: "amplify", reference: "c1", recipients: 900,
            sent: 898, failed: 2, seen: 312, createdAt: "2026-11-09T10:00:00Z", finishedAt: "2026-11-09T10:01:00Z",
            lastCheckedAt: "2026-11-09T12:00:00Z"}];
        noveraStubStats["n-over"] = [200, {recipients: 3, seen: 4}];
        noveraStubStats["n-unchecked"] = [200, {recipients: 900, seen: 0, lastCheckedAt: ()}];
        noveraStubStats["n-no-time"] = [200, {recipients: 900, seen: 0}];
        noveraStubStats["n-text"] = [200, "not json"];
        noveraStubStats["n-down"] = [503, ()];
    }
    NoveraClient novera = check stubNovera();
    test:assertEquals(novera.stats("n-ok", "corr-1"), {recipients: 900, seen: 312}, "extra fields are ignored");
    lock {
        test:assertEquals(noveraStubStatsPath, "/internal/notifications/n-ok/stats");
    }
    announcements:NoveraSeenStats|NoveraError unknown = novera.stats("n-unknown", ());
    test:assertTrue(unknown is NoveraError && unknown.detail().code == "NOT_FOUND" && !unknown.detail().retryable);
    foreach string id in ["n-over", "n-text"] {
        announcements:NoveraSeenStats|NoveraError bad = novera.stats(id, ());
        test:assertTrue(bad is NoveraError && bad.detail().code == "BAD_RESPONSE", id);
    }
    foreach string id in ["n-unchecked", "n-no-time"] {
        announcements:NoveraSeenStats|NoveraError notYet = novera.stats(id, ());
        test:assertTrue(notYet is NoveraError && notYet.detail().code == "NOT_COUNTED" && !notYet.detail().retryable,
                id + ": a count Novera hasn't checked is not 'seen 0'");
    }
    announcements:NoveraSeenStats|NoveraError down = novera.stats("n-down", ());
    test:assertTrue(down is NoveraError && down.detail().code == "UNAVAILABLE" && down.detail().httpStatus == 503);
    announcements:NoveraSeenStats|NoveraError unsafe = novera.stats("a/b", ());
    test:assertTrue(unsafe is NoveraError && unsafe.detail().code == "REJECTED", "never put an unsafe id in the path");
}
