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
        NoveraError? result = built.notify({'source: "amplify", title: "T", subtitle: "S", body: "B",
            button: {url: "https://one.wso2.com", label: "Amplify"}}, ());
        test:assertTrue(result is NoveraError);
        if result is NoveraError {
            test:assertEquals(result.detail().code, "UNAVAILABLE");
            test:assertTrue(result.detail().retryable);
        }
    }
}

// A Novera stand-in: a token endpoint and a notifications endpoint that answers whatever status the test sets.
const int NOVERA_STUB_PORT = 18299;
isolated int noveraStubStatus = 202;

listener http:Listener noveraStub = new (NOVERA_STUB_PORT);

service / on noveraStub {
    isolated resource function post token() returns json => {access_token: "stub-token", token_type: "Bearer", expires_in: 3600};

    isolated resource function post internal/notifications() returns http:Response {
        http:Response res = new;
        lock {
            res.statusCode = noveraStubStatus;
        }
        return res;
    }
}

function noveraAnswers(int status) returns NoveraError? {
    lock {
        noveraStubStatus = status;
    }
    NoveraClient|error novera = new (string `http://127.0.0.1:${NOVERA_STUB_PORT}/internal/notifications`,
        string `http://127.0.0.1:${NOVERA_STUB_PORT}/token`, "id", "secret", [], 5, allowInsecureHttp = true);
    if novera is error {
        return noveraError("UNAVAILABLE", "client not built", (), false);
    }
    return novera.notify({'source: "amplify", title: "T", subtitle: "S", body: "B",
        button: {url: "https://one.wso2.com", label: "Amplify"}}, ());
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
