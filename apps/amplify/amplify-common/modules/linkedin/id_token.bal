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

// OIDC ID-token validation for Sign In with LinkedIn (S2, plan M10 gap "no ID-token validation").
// LinkedIn's discovery document (https://www.linkedin.com/oauth/.well-known/openid-configuration, read
// 2026-10-17) gives issuer `https://www.linkedin.com/oauth`, jwks_uri
// `https://www.linkedin.com/oauth/openid/jwks` and `RS256` as the only signing algorithm. The docs page
// "Sign In with LinkedIn using OpenID Connect" lists `iss`, `sub`, `aud` (= client id), `iat`, `exp`.
// The token is never logged and never put in an error.

import amplify_common.resilience;

import ballerina/crypto;
import ballerina/http;
import ballerina/jwt;
import ballerina/lang.array;
import ballerina/time;

# Issuer in LinkedIn's OIDC discovery document.
public const string LINKEDIN_OIDC_ISSUER = "https://www.linkedin.com/oauth";
# LinkedIn's OIDC signing keys.
public const string LINKEDIN_JWKS_URL = "https://www.linkedin.com/oauth/openid/jwks";
# Longest ID token accepted, characters.
public const int ID_TOKEN_MAX_LENGTH = 8192;

const string ALG_RS256 = "RS256";

# ID-token validation settings.
public type IdTokenConfig record {|
    # OAuth client id: the only accepted `aud`
    string clientId;
    # Expected `iss`
    string issuer = LINKEDIN_OIDC_ISSUER;
    # JWKS URL (mock: the mock's own JWKS)
    string jwksUrl = LINKEDIN_JWKS_URL;
    # Clock skew allowed on `exp`, `nbf` and `iat`, seconds
    int clockSkewSeconds = 60;
    # Oldest `iat` accepted, seconds. The token comes straight from the code exchange, so it is fresh
    int maxAgeSeconds = 600;
    # Keys older than this are refreshed (the last good keys keep serving if a refresh fails)
    decimal jwksRefreshSeconds = 3600;
    # At most one refresh per interval for an unknown `kid` (stops kid floods)
    decimal jwksMinRefreshIntervalSeconds = 30;
    # JWKS call timeout
    decimal timeoutSeconds = 10;
    # JWKS breaker and its own pool. A GET of a public document, so a retry would be safe
    resilience:HttpResilience resilience = {};
|};

# Claims of a validated LinkedIn ID token.
public type IdTokenClaims record {|
    # Member id (`sub`), the same value `/v2/userinfo` returns
    string sub;
    # Issuer
    string issuer;
    # Issued at, seconds since the epoch
    int issuedAt;
    # Expires at, seconds since the epoch
    int expiresAt;
    # `nonce`, when the token carries one
    string? nonce;
    # Display name, when present
    string? name;
    # Email, only with the `email` scope
    string? email;
|};

type OidcKey record {|
    string? kid;
    string n;
    string e;
|};

# Validates LinkedIn ID tokens: RS256 signature against the cached LinkedIn JWKS, `iss`, `aud`, `exp`,
# `nbf`, `iat` (with skew and a maximum age) and, when the caller sent one, `nonce`.
public isolated class IdTokenValidator {
    private final http:Client jwks;
    private final IdTokenConfig & readonly config;
    private OidcKey[] keys = [];
    private decimal fetchedAt = -1d;
    private decimal lastAttemptAt = -1d;

    # Creates the validator.
    #
    # + config - Settings
    # + return - An error when the client id is blank or the JWKS URL is invalid
    public isolated function init(IdTokenConfig config) returns error? {
        if config.clientId.trim().length() == 0 {
            return error("ID token validation needs the OAuth client id");
        }
        self.config = config.cloneReadOnly();
        self.jwks = check new (config.jwksUrl, resilience:clientConfig(config.resilience, config.timeoutSeconds));
    }

    # Validates an ID token from the code exchange.
    #
    # + idToken - Compact JWS (`TokenGrant.idToken`)
    # + expectedNonce - The `nonce` sent on the authorization request, if one was sent; then the token
    # must carry the same value
    # + now - Current time (a test seam)
    # + return - The claims, `BAD_RESPONSE` for a token that fails any check, or `UNAVAILABLE` when no
    # signing key can be fetched
    public isolated function validate(string idToken, string? expectedNonce = (), time:Utc now = time:utcNow())
            returns IdTokenClaims|ProviderError {
        string jws = idToken.trim();
        string[] parts = re `\.`.split(jws);
        if jws.length() == 0 || jws.length() > ID_TOKEN_MAX_LENGTH || parts.length() != 3 {
            return invalidIdToken("malformed");
        }
        [jwt:Header, jwt:Payload]|jwt:Error decoded = jwt:decode(jws);
        if decoded is jwt:Error {
            return invalidIdToken("malformed");
        }
        [jwt:Header, jwt:Payload] [header, payload] = decoded;
        if header.alg != jwt:RS256 {
            return invalidIdToken("not signed with RS256");
        }
        byte[]|error signature = fromBase64Url(parts[2]);
        if signature is error {
            return invalidIdToken("malformed");
        }
        OidcKey[] candidates = check self.keysFor(header.kid);
        if !verifiesWithAny(parts[0] + "." + parts[1], signature, candidates) {
            return invalidIdToken("signature does not verify");
        }
        return checkClaims(payload, self.config, expectedNonce, now[0]);
    }

    # Breaker state of the JWKS client.
    #
    # + return - `CLOSED`, `HALF_OPEN` or `OPEN`
    public isolated function breaker() returns resilience:BreakerState => resilience:breakerState(self.jwks);

    isolated function keysFor(string? kid) returns OidcKey[]|ProviderError {
        decimal now = time:monotonicNow();
        boolean refresh;
        lock {
            boolean empty = self.keys.length() == 0;
            boolean stale = self.fetchedAt < 0d || now - self.fetchedAt >= self.config.jwksRefreshSeconds;
            boolean unknownKid = kid is string && keysMatching(self.keys, kid).length() == 0;
            // The gate holds on a cold cache too, so a burst of validations during a cold start or a LinkedIn
            // JWKS outage makes one fetch per interval, not one per call.
            boolean gated = self.lastAttemptAt >= 0d
                && now - self.lastAttemptAt < self.config.jwksMinRefreshIntervalSeconds;
            refresh = (empty || stale || unknownKid) && !gated;
            if refresh {
                self.lastAttemptAt = now;
            }
        }
        if refresh {
            OidcKey[]|error fetched = self.fetch();
            if fetched is OidcKey[] {
                lock {
                    self.keys = fetched.clone();
                    self.fetchedAt = now;
                }
            }
        }
        lock {
            if self.keys.length() == 0 {
                return providerError(UNAVAILABLE, "LinkedIn ID token signing keys are unavailable", (), (), true);
            }
            return keysMatching(self.keys, kid).clone();
        }
    }

    isolated function fetch() returns OidcKey[]|error {
        json body = check self.jwks->get("");
        return parseOidcJwks(body);
    }
}

# Checks the claims of a token whose signature already verified.
#
# + payload - Decoded payload
# + config - Settings
# + expectedNonce - Nonce sent on the authorization request, if any
# + nowSeconds - Current time, seconds since the epoch
# + return - The claims, or `BAD_RESPONSE`
isolated function checkClaims(jwt:Payload payload, IdTokenConfig config, string? expectedNonce, int nowSeconds)
        returns IdTokenClaims|ProviderError {
    int skew = config.clockSkewSeconds;
    if payload.iss != config.issuer {
        return invalidIdToken("issuer is not LinkedIn");
    }
    string|string[]? aud = payload.aud;
    string[] auds = [];
    if aud is string {
        auds = [aud];
    } else if aud is string[] {
        auds = aud;
    }
    if auds.indexOf(config.clientId) is () {
        return invalidIdToken("audience is not this client");
    }
    // OIDC Core 3.1.3.7: with several audiences `azp` must be present, and whenever it is present it must name
    // this client.
    anydata azp = payload["azp"];
    if (auds.length() > 1 || azp !is ()) && azp != config.clientId {
        return invalidIdToken("authorized party is not this client");
    }
    int? exp = payload.exp;
    if exp is () || nowSeconds >= exp + skew {
        return invalidIdToken("expired");
    }
    int? nbf = payload.nbf;
    if nbf is int && nowSeconds + skew < nbf {
        return invalidIdToken("not valid yet");
    }
    int? iat = payload.iat;
    if iat is () || iat > nowSeconds + skew || nowSeconds - iat > config.maxAgeSeconds + skew {
        return invalidIdToken("issue time is missing or out of range");
    }
    string sub = (payload.sub ?: "").trim();
    if sub.length() == 0 {
        return invalidIdToken("has no subject");
    }
    anydata nonceClaim = payload["nonce"];
    string? nonce = nonceClaim is string ? nonceClaim : ();
    if expectedNonce is string && (nonce is () || !constantTimeEquals(nonce, expectedNonce)) {
        return invalidIdToken("nonce does not match");
    }
    anydata name = payload["name"];
    anydata email = payload["email"];
    return {
        sub,
        issuer: config.issuer,
        issuedAt: iat,
        expiresAt: exp,
        nonce,
        name: name is string ? name : (),
        email: email is string ? email : ()
    };
}

# RSA signing keys from a JWKS document. Other key types, encryption keys and keys for another algorithm
# are skipped.
#
# + body - JWKS JSON
# + return - Keys, or an error when the document has none
isolated function parseOidcJwks(json body) returns OidcKey[]|error {
    json[] entries = check (check body.keys).ensureType();
    OidcKey[] result = [];
    foreach json entry in entries {
        if entry !is map<json> || entry["kty"] != "RSA" {
            continue;
        }
        json use = entry["use"];
        json alg = entry["alg"];
        json n = entry["n"];
        json e = entry["e"];
        json kid = entry["kid"];
        if (use is () || use == "sig") && (alg is () || alg == ALG_RS256) && n is string && e is string {
            result.push({kid: kid is string ? kid : (), n, e});
        }
    }
    if result.length() == 0 {
        return error("JWKS has no RSA signing keys");
    }
    return result;
}

isolated function keysMatching(OidcKey[] keys, string? kid) returns OidcKey[] =>
    kid is () ? keys : from OidcKey k in keys where k.kid == kid select k;

isolated function verifiesWithAny(string signingInput, byte[] signature, OidcKey[] keys) returns boolean {
    byte[] data = signingInput.toBytes();
    foreach OidcKey k in keys {
        crypto:PublicKey|crypto:Error key = crypto:buildRsaPublicKey(k.n, k.e);
        if key is crypto:Error {
            continue;
        }
        boolean|crypto:Error ok = crypto:verifyRsaSha256Signature(data, signature, key);
        if ok is boolean && ok {
            return true;
        }
    }
    return false;
}

# Compares two strings in time that depends only on their lengths, so a nonce check leaks nothing about
# how many leading characters matched.
#
# + a - First value
# + b - Second value
# + return - True when equal
isolated function constantTimeEquals(string a, string b) returns boolean {
    byte[] x = a.toBytes();
    byte[] y = b.toBytes();
    int diff = x.length() ^ y.length();
    int n = x.length() < y.length() ? x.length() : y.length();
    foreach int i in 0 ..< n {
        diff = diff | (x[i] ^ y[i]);
    }
    return diff == 0;
}

isolated function fromBase64Url(string input) returns byte[]|error {
    string b64 = re `-`.replaceAll(re `_`.replaceAll(input, "/"), "+");
    int pad = (4 - b64.length() % 4) % 4;
    if pad == 3 {
        return error("Invalid base64url length");
    }
    foreach int i in 0 ..< pad {
        b64 += "=";
    }
    return array:fromBase64(b64);
}

isolated function invalidIdToken(string reason) returns ProviderError =>
    providerError(BAD_RESPONSE, "LinkedIn ID token " + reason, (), (), false);
