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


// LinkedIn ID-token validation on connect (common H1 / api H1), with `linkedinIdTokenValidation` on: the
// test gateway's RS256 key and JWKS (:9591) stand in for LinkedIn's. Good token, bad signature, wrong
// audience, expired, missing, and a `sub` that doesn't match userinfo. The validator's reason never reaches
// the caller. Also: `/ready` reports the validator's JWKS breaker without gating on it.

import amplify_common.linkedin;

import ballerina/http;
import ballerina/test;
import ballerina/time;

final linkedin:IdTokenValidator testIdTokens = check new ({clientId: TEST_AUDIENCE, issuer: TEST_ISSUER,
    jwksUrl: "http://localhost:9591/jwks"});

isolated boolean idTokenValidationOn = false;

function setIdTokenValidation(boolean enabled) {
    lock {
        idTokenValidationOn = enabled;
    }
}

@test:Mock {functionName: "idTokens"}
isolated function mockIdTokens() returns linkedin:IdTokenValidator? {
    lock {
        return idTokenValidationOn ? testIdTokens : ();
    }
}

# Runs start + complete with a given ID token on the exchange.
#
# + who - Employee id
# + code - Authorization code (userinfo `sub` is `li-li-token-<code>`)
# + idToken - ID token the fake exchange returns
# + return - The complete response
function connectWith(string who, string code, string? idToken) returns http:Response|error {
    setLinkedInMode("OK");
    string token = check employee(who);
    string state = check stateOf(check startFor(token));
    setIdTokenOnExchange(idToken);
    http:Response res = check send("POST", "/connections/linkedin/complete", {code, state, redirectUri: TEST_REDIRECT_URI}, token);
    setIdTokenOnExchange(());
    return res;
}

function assertRefused(http:Response res, string why) returns error? {
    test:assertEquals(res.statusCode, 422, why);
    test:assertEquals(check codeIn(res), "OAUTH_STATE_INVALID", why);
    string text = check res.getTextPayload();
    test:assertFalse(text.includes("signature") || text.includes("audience") || text.includes("expired"),
            "the validator's reason stays in the log: " + why);
}

@test:Config {groups: ["connect"]}
function testIdTokenValidationOnConnect() returns error? {
    setIdTokenValidation(true);
    do {
        string sub = "li-li-token-c-idt-good";
        http:Response good = check connectWith("emp-idt-1", "c-idt-good", check mint({sub}));
        test:assertEquals(good.statusCode, 200, "a valid ID token for the same member connects");

        check assertRefused(check connectWith("emp-idt-2", "c-idt-sig",
                check mint({sub: "li-li-token-c-idt-sig"}, key = rogueKey)), "bad signature");
        check assertRefused(check connectWith("emp-idt-3", "c-idt-aud",
                check mint({sub: "li-li-token-c-idt-aud", aud: "someone-else"})), "wrong audience");
        int now = time:utcNow()[0];
        check assertRefused(check connectWith("emp-idt-4", "c-idt-exp",
                check mint({sub: "li-li-token-c-idt-exp", iat: now - 300, exp: now - 120})), "expired");
        check assertRefused(check connectWith("emp-idt-5", "c-idt-none", ()), "missing ID token");
        check assertRefused(check connectWith("emp-idt-6", "c-idt-sub", check mint({sub: "li-somebody-else"})),
                "sub doesn't match userinfo");
    } on fail error e {
        setIdTokenValidation(false);
        return e;
    }
    setIdTokenValidation(false);
    http:Response off = check connectWith("emp-idt-7", "c-idt-off", ());
    test:assertEquals(off.statusCode, 200, "validation off: no ID token needed (today's default)");
}

@test:Config {groups: ["connect"]}
function testReadyReportsTheIdTokenJwksBreakerWithoutGating() returns error? {
    setIdTokenValidation(false);
    http:Response plain = check testClient->get("/ready");
    json withoutValidation = check plain.getJsonPayload();
    test:assertEquals(check withoutValidation.breakers.linkedinIdTokenJwks, "NOT_CONFIGURED");
    setIdTokenValidation(true);
    http:Response withValidation = check testClient->get("/ready");
    setIdTokenValidation(false);
    json body = check withValidation.getJsonPayload();
    test:assertEquals(check body.breakers.linkedinIdTokenJwks, "CLOSED");
    test:assertEquals(withValidation.statusCode, 200, "reported, never gating");
}

// ---- OIDC nonce (`linkedinNonceMode`) -------------------------------------------------------------------

isolated NonceMode nonceModeInTest = "OFF";

function setNonceMode(NonceMode mode) {
    lock {
        nonceModeInTest = mode;
    }
}

@test:Mock {functionName: "nonceModeFor"}
isolated function mockNonceModeFor(linkedin:IdTokenValidator? validator) returns NonceMode {
    if validator is () {
        return "OFF";
    }
    lock {
        return nonceModeInTest;
    }
}

# Starts a connect and returns `[token, state, nonce sent on the authorize URL or ()]`.
function startWithNonce(string who) returns [string, string, string?]|error {
    setLinkedInMode("OK");
    string token = check employee(who);
    http:Response started = check startFor(token);
    json body = check started.getJsonPayload();
    string url = (check body.authorizationUrl).toString();
    string? nonce = ();
    foreach string param in re `&`.split(url.substring((url.indexOf("?") ?: 0) + 1)) {
        if param.startsWith("nonce=") {
            nonce = param.substring(6);
        }
    }
    return [token, (check body.state).toString(), nonce];
}

function completeWith(string token, string state, string code, string? idToken) returns http:Response|error {
    setIdTokenOnExchange(idToken);
    http:Response res = check send("POST", "/connections/linkedin/complete", {code, state, redirectUri: TEST_REDIRECT_URI}, token);
    setIdTokenOnExchange(());
    return res;
}

@test:Config {groups: ["connect"]}
function testNonceOffSendsNothingAndIgnoresIt() returns error? {
    setIdTokenValidation(true);
    setNonceMode("OFF");
    do {
        var [token, state, nonce] = check startWithNonce("emp-nonce-off");
        test:assertEquals(nonce, (), "OFF: no nonce parameter on the authorize URL");
        http:Response res = check completeWith(token, state, "c-nonce-off", check mint({sub: "li-li-token-c-nonce-off", nonce: "anything"}));
        test:assertEquals(res.statusCode, 200, "OFF: a nonce claim is not looked at");
    } on fail error e {
        setIdTokenValidation(false);
        return e;
    }
    setIdTokenValidation(false);
}

@test:Config {groups: ["connect"]}
function testNonceSendIsCheckedWhenEchoedAndLoggedWhenNot() returns error? {
    setIdTokenValidation(true);
    setNonceMode("SEND");
    do {
        var [token, state, nonce] = check startWithNonce("emp-nonce-send-1");
        test:assertTrue(nonce is string && nonce.length() >= 16, "SEND: the oauth_state nonce is on the authorize URL");
        http:Response good = check completeWith(token, state, "c-nonce-s1",
                check mint({sub: "li-li-token-c-nonce-s1", nonce: <string>nonce}));
        test:assertEquals(good.statusCode, 200, "an echoed nonce that matches");

        var [token2, state2, _] = check startWithNonce("emp-nonce-send-2");
        check assertRefused(check completeWith(token2, state2, "c-nonce-s2",
                check mint({sub: "li-li-token-c-nonce-s2", nonce: "another-flows-nonce"})), "echoed but wrong");

        var [token3, state3, _] = check startWithNonce("emp-nonce-send-3");
        http:Response none = check completeWith(token3, state3, "c-nonce-s3", check mint({sub: "li-li-token-c-nonce-s3"}));
        test:assertEquals(none.statusCode, 200, "SEND accepts a token with no nonce (and logs it): LinkedIn may not echo it");
    } on fail error e {
        setIdTokenValidation(false);
        setNonceMode("OFF");
        return e;
    }
    setIdTokenValidation(false);
    setNonceMode("OFF");
}

@test:Config {groups: ["connect"]}
function testNonceRequireRefusesAMissingOrWrongNonce() returns error? {
    setIdTokenValidation(true);
    setNonceMode("REQUIRE");
    do {
        var [token, state, nonce] = check startWithNonce("emp-nonce-req-1");
        http:Response good = check completeWith(token, state, "c-nonce-r1",
                check mint({sub: "li-li-token-c-nonce-r1", nonce: <string>nonce}));
        test:assertEquals(good.statusCode, 200);

        var [token2, state2, _] = check startWithNonce("emp-nonce-req-2");
        check assertRefused(check completeWith(token2, state2, "c-nonce-r2", check mint({sub: "li-li-token-c-nonce-r2"})),
                "REQUIRE: no nonce in the ID token");
        var [token3, state3, _] = check startWithNonce("emp-nonce-req-3");
        check assertRefused(check completeWith(token3, state3, "c-nonce-r3",
                check mint({sub: "li-li-token-c-nonce-r3", nonce: "replayed-from-another-flow"})), "REQUIRE: wrong nonce");
    } on fail error e {
        setIdTokenValidation(false);
        setNonceMode("OFF");
        return e;
    }
    setIdTokenValidation(false);
    setNonceMode("OFF");
}

@test:Config {groups: ["connect"]}
function testNonceIsNotSentWithoutIdTokenValidation() returns error? {
    setIdTokenValidation(false);
    setNonceMode("REQUIRE");
    var [_, _, nonce] = check startWithNonce("emp-nonce-novalidator");
    setNonceMode("OFF");
    test:assertEquals(nonce, (), "no validator can check it, so none is sent");
}
