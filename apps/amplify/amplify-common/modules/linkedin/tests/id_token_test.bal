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

// ID-token validation against a stub LinkedIn JWKS. RSA keys are generated per run with openssl (no key
// material in the repo), the same way amplify-api's gateway tests do it.

import amplify_common.types;

import ballerina/crypto;
import ballerina/file;
import ballerina/http;
import ballerina/lang.array;
import ballerina/os;
import ballerina/test;
import ballerina/time;

const int JWKS_STUB_PORT = 18213;
const string OIDC_CLIENT = "cid";
const string KID_1 = "li-key-1";
const string KID_2 = "li-key-2";

crypto:PrivateKey? liKey = ();
crypto:PrivateKey? rotatedKey = ();
crypto:PrivateKey? rogueKey = ();
json[] liJwk = [];
json[] rotatedJwk = [];

isolated json jwksDoc = {keys: []};
isolated int jwksHits = 0;

listener http:Listener jwksStub = new (JWKS_STUB_PORT);

service /oauth/openid on jwksStub {
    isolated resource function get jwks() returns json {
        lock {
            jwksHits += 1;
        }
        lock {
            return jwksDoc.clone();
        }
    }
}

function setJwks(json[] keys) {
    json doc = {keys};
    lock {
        jwksDoc = doc.clone();
    }
}

@test:BeforeSuite
function makeOidcKeys() returns error? {
    string dir = check file:createTempDir();
    [crypto:PrivateKey, json] k1 = check rsaPair(dir, "li1", KID_1);
    [crypto:PrivateKey, json] k2 = check rsaPair(dir, "li2", KID_2);
    [crypto:PrivateKey, json] rogue = check rsaPair(dir, "rogue", KID_1);
    liKey = k1[0];
    rotatedKey = k2[0];
    rogueKey = rogue[0];
    liJwk = [k1[1]];
    rotatedJwk = [k2[1]];
    // An encryption key and an EC key in the set are ignored.
    setJwks([{kty: "RSA", use: "enc", kid: "enc-1", n: "AQAB", e: "AQAB"}, {kty: "EC", kid: "ec-1"}, k1[1]]);
    check file:remove(dir, file:RECURSIVE);
}

function rsaPair(string dir, string name, string kid) returns [crypto:PrivateKey, json]|error {
    string pem = check file:joinPath(dir, name + ".pem");
    _ = check openssl(["genrsa", "-out", pem, "2048"]);
    string modulus = check openssl(["rsa", "-in", pem, "-noout", "-modulus"]);
    int offset = (modulus.indexOf("=") ?: -1) + 1;
    string hex = re `\s`.replaceAll(modulus.substring(offset), "");
    crypto:PrivateKey key = check crypto:decodeRsaPrivateKeyFromKeyFile(pem);
    return [key, {kty: "RSA", use: "sig", alg: "RS256", kid, n: types:toBase64Url(check array:fromBase16(hex)), e: "AQAB"}];
}

function openssl(string[] args) returns string|error {
    os:Process process = check os:exec({value: "openssl", arguments: args});
    int code = check process.waitForExit();
    byte[] out = check process.output();
    if code != 0 {
        return error(string `openssl ${args[0]} exited ${code}`);
    }
    return string:fromBytes(out);
}

# Mints a LinkedIn-shaped ID token.
#
# + claims - Payload overrides; `()` removes a claim
# + header - Header overrides
# + key - Signing key (default: the published key)
# + return - Compact JWS
function mintIdToken(map<json> claims = {}, map<json> header = {}, crypto:PrivateKey? key = ()) returns string|error {
    int now = time:utcNow()[0];
    map<json> payload = {iss: LINKEDIN_OIDC_ISSUER, aud: OIDC_CLIENT, sub: "782bbtaQ", iat: now, exp: now + 3600,
        name: "Avery Mock", email: "avery.mock@example.com"};
    foreach [string, json] [k, v] in claims.entries() {
        if v is () {
            _ = payload.removeIfHasKey(k);
        } else {
            payload[k] = v;
        }
    }
    map<json> head = {alg: "RS256", typ: "JWT", kid: KID_1};
    foreach [string, json] [k, v] in header.entries() {
        head[k] = v;
    }
    string input = types:toBase64Url(head.toJsonString().toBytes()) + "."
        + types:toBase64Url(payload.toJsonString().toBytes());
    crypto:PrivateKey signer = key ?: check liKey.ensureType();
    return input + "." + types:toBase64Url(check crypto:signRsaSha256(input.toBytes(), signer));
}

function validator(decimal minRefresh = 30) returns IdTokenValidator|error => new ({
    clientId: OIDC_CLIENT,
    jwksUrl: string `http://localhost:${JWKS_STUB_PORT}/oauth/openid/jwks`,
    jwksMinRefreshIntervalSeconds: minRefresh,
    timeoutSeconds: 2
});

function rejectedWith(IdTokenClaims|ProviderError result, string token) returns string {
    if result is IdTokenClaims {
        return "OK";
    }
    if token.length() >= 8 {
        test:assertFalse(result.toString().includes(token), "an ID-token error never carries the token");
    }
    return result.detail().code;
}

@test:Config
function idTokenValidates() returns error? {
    IdTokenValidator v = check validator();
    test:assertEquals(v.breaker(), "CLOSED");
    IdTokenClaims claims = check v.validate(check mintIdToken({nonce: "n-123"}), "n-123");
    test:assertEquals(claims.sub, "782bbtaQ");
    test:assertEquals(claims.issuer, LINKEDIN_OIDC_ISSUER);
    test:assertEquals(claims.nonce, "n-123");
    test:assertEquals(claims.name, "Avery Mock");
    test:assertEquals(claims.email, "avery.mock@example.com");
    // No nonce expected: a token without one is fine (LinkedIn doesn't document `nonce`).
    IdTokenClaims plain = check v.validate(check mintIdToken());
    test:assertEquals(plain.nonce, ());
}

function badIdTokens() returns map<[map<json>, map<json>, boolean, string?]> => {
    "wrongIssuer": [{iss: "https://www.linkedin.com"}, {}, false, ()],
    "wrongAudience": [{aud: "someone-else"}, {}, false, ()],
    "manyAudiencesNoAzp": [{aud: [OIDC_CLIENT, "other"]}, {}, false, ()],
    // OIDC Core 3.1.3.7: a present `azp` must name this client even with a single audience.
    "singleAudienceForeignAzp": [{aud: OIDC_CLIENT, azp: "some-other-app"}, {}, false, ()],
    "expired": [{exp: time:utcNow()[0] - 120}, {}, false, ()],
    "noExpiry": [{exp: ()}, {}, false, ()],
    "issuedInTheFuture": [{iat: time:utcNow()[0] + 600}, {}, false, ()],
    "issuedTooLongAgo": [{iat: time:utcNow()[0] - 3600}, {}, false, ()],
    "noIssueTime": [{iat: ()}, {}, false, ()],
    "notYetValid": [{nbf: time:utcNow()[0] + 600}, {}, false, ()],
    "noSubject": [{sub: ()}, {}, false, ()],
    "blankSubject": [{sub: "  "}, {}, false, ()],
    "nonceMissing": [{}, {}, false, "n-1"],
    "nonceMismatch": [{nonce: "n-2"}, {}, false, "n-1"],
    "hmacHeader": [{}, {alg: "HS256"}, false, ()],
    "noneHeader": [{}, {alg: "none"}, false, ()],
    "rogueSignature": [{}, {}, true, ()],
    "unknownKid": [{}, {kid: "nobody"}, false, ()]
};

@test:Config {dataProvider: badIdTokens}
function idTokenRejected(map<json> claims, map<json> header, boolean rogue, string? nonce) returns error? {
    IdTokenValidator v = check validator();
    string token = check mintIdToken(claims, header, rogue ? rogueKey : ());
    IdTokenClaims|ProviderError result = v.validate(token, nonce);
    test:assertEquals(rejectedWith(result, token), BAD_RESPONSE);
    if result is ProviderError {
        test:assertFalse(result.detail().retryable);
    }
}

@test:Config
function idTokenManyAudiencesWithAzpIsAccepted() returns error? {
    IdTokenValidator v = check validator();
    IdTokenClaims claims = check v.validate(check mintIdToken({aud: ["other", OIDC_CLIENT], azp: OIDC_CLIENT}));
    test:assertEquals(claims.sub, "782bbtaQ");
}

@test:Config
function idTokenSkewIsAllowed() returns error? {
    IdTokenValidator v = check validator();
    int now = time:utcNow()[0];
    // Expired 30 s ago and issued 30 s "in the future": both inside the 60 s skew.
    string token = check mintIdToken({exp: now - 30, iat: now + 30});
    test:assertTrue(v.validate(token) is IdTokenClaims);
    test:assertTrue(v.validate(token, now = [now + 120, 0]) is ProviderError, "outside the skew it fails");
}

@test:Config
function idTokenMalformedInputs() returns error? {
    IdTokenValidator v = check validator();
    string valid = check mintIdToken();
    string[] parts = re `\.`.split(valid);
    string long = "";
    foreach int i in 0 ..< ID_TOKEN_MAX_LENGTH + 1 {
        long += "a";
    }
    foreach string token in ["", "a.b", "a.b.c.d", "not-a-jwt.at.all", long, parts[0] + "." + parts[1] + ".%%%",
            parts[0] + "." + parts[1] + "." + parts[2].substring(1)] {
        test:assertEquals(rejectedWith(v.validate(token), token), BAD_RESPONSE, token.length() > 40 ? "long" : token);
    }
}

@test:Config
function idTokenPicksUpRotatedKey() returns error? {
    IdTokenValidator v = check validator(0);
    test:assertTrue(v.validate(check mintIdToken()) is IdTokenClaims, "warm the cache with key 1");
    setJwks([...liJwk, ...rotatedJwk]);
    string rotated = check mintIdToken(header = {kid: KID_2}, key = rotatedKey);
    IdTokenClaims|ProviderError result = v.validate(rotated);
    setJwks(liJwk);
    test:assertTrue(result is IdTokenClaims, "an unknown kid refreshes the JWKS");
}

@test:Config
function idTokenKeysUnavailableIsRetryable() returns error? {
    IdTokenValidator v = check new ({clientId: OIDC_CLIENT, jwksUrl: "http://localhost:1/jwks", timeoutSeconds: 2});
    string token = check mintIdToken();
    IdTokenClaims|ProviderError result = v.validate(token);
    test:assertEquals(rejectedWith(result, token), UNAVAILABLE);
    if result is ProviderError {
        test:assertTrue(result.detail().retryable);
    }
}

@test:Config
function idTokenColdCacheIsFetchedOncePerInterval() returns error? {
    // The JWKS answers but holds no keys, so the cache stays cold. With a 30 s gate a burst of validations
    // makes one fetch; the rest are refused by the gate instead of each calling LinkedIn.
    setJwks([]);
    IdTokenValidator v = check validator(30);
    string token = check mintIdToken();
    int before = jwksFetches();
    foreach int i in 0 ..< 5 {
        test:assertEquals(rejectedWith(v.validate(token), token), UNAVAILABLE);
    }
    int fetches = jwksFetches() - before;
    setJwks(liJwk);
    test:assertEquals(fetches, 1, "a cold cache is gated like a warm one");
}

function jwksFetches() returns int {
    lock {
        return jwksHits;
    }
}

@test:Config
function idTokenValidatorNeedsClientId() {
    IdTokenValidator|error v = new ({clientId: " "});
    test:assertTrue(v is error);
}

@test:Config
function oidcJwksParsing() returns error? {
    test:assertTrue(parseOidcJwks({keys: [{kty: "RSA", use: "enc", n: "x", e: "y"}]}) is error);
    test:assertTrue(parseOidcJwks({keys: [{kty: "RSA", alg: "RS512", n: "x", e: "y"}]}) is error);
    test:assertTrue(parseOidcJwks({nokeys: true}) is error);
    OidcKey[] keys = check parseOidcJwks({keys: [{kty: "RSA", n: "x", e: "y"}, "junk"]});
    test:assertEquals(keys, [{kid: (), n: "x", e: "y"}]);
    test:assertEquals(keysMatching(keys, ()).length(), 1, "a token without kid tries every key");
}

@test:Config
function constantTimeEqualsBehaves() {
    test:assertTrue(constantTimeEquals("abc", "abc"));
    test:assertFalse(constantTimeEquals("abc", "abd"));
    test:assertFalse(constantTimeEquals("abc", "abcd"));
    test:assertFalse(constantTimeEquals("", "a"));
    test:assertTrue(constantTimeEquals("", ""));
}

@test:Config
function base64UrlDecoding() returns error? {
    test:assertEquals(check fromBase64Url("AQAB"), <byte[]>[1, 0, 1]);
    test:assertEquals(check fromBase64Url("-_8"), <byte[]>[251, 255]);
    test:assertTrue(fromBase64Url("abcde") is error);
}
