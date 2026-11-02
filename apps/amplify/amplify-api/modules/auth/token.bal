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
import amplify_common.types;

import ballerina/crypto;
import ballerina/http;
import ballerina/jwt;
import ballerina/lang.array;
import ballerina/log;
import ballerina/time;

# No `x-jwt-assertion`.
public const string TOKEN_MISSING = "TOKEN_MISSING";
# Not a three-part JWS, too large, or bad JSON.
public const string TOKEN_MALFORMED = "TOKEN_MALFORMED";
# `alg` other than RS256 (`none`, HS*, ...).
public const string TOKEN_ALG_NOT_ALLOWED = "TOKEN_ALG_NOT_ALLOWED";
# Signature doesn't verify with any trusted key.
public const string TOKEN_SIGNATURE_INVALID = "TOKEN_SIGNATURE_INVALID";
# `exp` missing or past.
public const string TOKEN_EXPIRED = "TOKEN_EXPIRED";
# `nbf` in the future.
public const string TOKEN_NOT_YET_VALID = "TOKEN_NOT_YET_VALID";
# `iss` not trusted.
public const string TOKEN_ISSUER_INVALID = "TOKEN_ISSUER_INVALID";
# `aud` doesn't name this API.
public const string TOKEN_AUDIENCE_INVALID = "TOKEN_AUDIENCE_INVALID";
# `sub` or `email` missing or invalid.
public const string TOKEN_CLAIMS_INVALID = "TOKEN_CLAIMS_INVALID";
# No signing keys and the JWKS can't be fetched (503, not 401).
public const string KEYS_UNAVAILABLE = "KEYS_UNAVAILABLE";

// Longest token read. The HTTP listener refuses a header over its own `maxHeaderSize` (default 8192) before this
// code runs, with no problem body and no audit row, so a higher limit here would never be reached.
public const int MAX_TOKEN_LENGTH = 8192;
const string RS256 = "RS256";

# Detail of an authentication failure: a stable code only, never token content.
public type AuthErrorDetail record {|
    # Stable code, for example `TOKEN_EXPIRED`
    string code;
|};

# Authentication failure.
public type AuthError distinct error<AuthErrorDetail>;

# The verified caller, stored in the request context for resources.
public type Principal record {|
    # Asgardeo `sub`
    types:EmployeeId employeeId;
    # Lowercased email (claim)
    string email;
    # Display name (claim), if present
    string? displayName;
    # Groups from the roles claim that the access configuration names (others are dropped)
    string[] roles;
    # Grants those groups give (`EMPLOYEE` always)
    Access[] grants;
    # Issuer the token was verified against
    string issuer;
|};

# Claim names and trust settings.
public type VerifierConfig record {|
    # Gateway `iss`
    string issuer;
    # Accepted `aud` values (any one must appear)
    string[] audiences;
    # Clock skew allowed on `exp` / `nbf`, seconds
    int clockSkewSeconds = 60;
    # Claim holding groups/roles (array, or a comma/space separated string)
    string rolesClaim = "groups";
    # Email claim
    string emailClaim = "email";
    # Display name claim
    string nameClaim = "name";
    # Groups granted each capability
    AccessGroups access = {};
|};

# Dev-only trust for locally signed tokens (ADR-023). Its issuer must differ from the gateway's.
public type DevTrust record {|
    # `iss` the local tokens carry
    string issuer;
    # Keys from the local JWKS file
    Jwk[] keys;
|};

# Verifies the gateway's backend JWT: RS256 signature against the JWKS, then `iss`, `aud`, `exp`, `nbf`,
# then the identity claims. Nothing is trusted before the signature verifies.
public isolated class TokenVerifier {
    private final JwksCache jwks;
    private final VerifierConfig & readonly config;
    private final DevTrust? & readonly dev;

    # + jwks - Gateway key cache
    # + config - Trust settings
    # + dev - Local signing trust, only when the dev switch is on
    public isolated function init(JwksCache jwks, VerifierConfig config, DevTrust? dev = ()) {
        self.jwks = jwks;
        self.config = config.cloneReadOnly();
        self.dev = dev.cloneReadOnly();
    }

    # State of the key-fetch breaker, for `/ready`.
    #
    # + return - Breaker state
    public isolated function keysBreakerState() returns http:CircuitState => self.jwks.breakerState();

    # Verifies a token.
    #
    # + token - Compact JWS from `x-jwt-assertion`
    # + now - Current time
    # + return - The caller, or an `AuthError` with a stable code
    public isolated function verify(string? token, time:Utc now = time:utcNow()) returns Principal|AuthError {
        if token is () || token.trim().length() == 0 {
            return authError(TOKEN_MISSING, "Credentials are missing");
        }
        string jws = token.trim();
        string[] parts = re `\.`.split(jws);
        if jws.length() > MAX_TOKEN_LENGTH || parts.length() != 3 {
            return authError(TOKEN_MALFORMED, "Credentials are malformed");
        }
        [jwt:Header, jwt:Payload]|jwt:Error decoded = jwt:decode(jws);
        if decoded is jwt:Error {
            return authError(TOKEN_MALFORMED, "Credentials are malformed");
        }
        [jwt:Header, jwt:Payload] [header, payload] = decoded;
        if header.alg != RS256 {
            return authError(TOKEN_ALG_NOT_ALLOWED, "Signing algorithm is not allowed");
        }
        byte[]|error signature = fromBase64Url(parts[2]);
        if signature is error {
            return authError(TOKEN_MALFORMED, "Credentials are malformed");
        }

        // Pick the trust anchor by the (still untrusted) issuer, then verify. A token claiming the dev
        // issuer is only ever checked against dev keys, and never when the switch is off.
        string? iss = payload.iss;
        DevTrust? dev = self.dev;
        Jwk[] candidates;
        string trustedIssuer;
        if dev is DevTrust && iss == dev.issuer {
            candidates = from Jwk k in dev.keys where header.kid is () || k.kid == header.kid select k;
            trustedIssuer = dev.issuer;
        } else {
            candidates = check self.jwks.keysFor(header.kid);
            trustedIssuer = self.config.issuer;
        }
        if !verifiesWithAny(parts[0] + "." + parts[1], signature, candidates) {
            return authError(TOKEN_SIGNATURE_INVALID, "Credentials signature is invalid");
        }

        int nowSeconds = now[0];
        int skew = self.config.clockSkewSeconds;
        int? exp = payload.exp;
        if exp is () || nowSeconds >= exp + skew {
            return authError(TOKEN_EXPIRED, "Credentials have expired");
        }
        int? nbf = payload.nbf;
        if nbf is int && nowSeconds + skew < nbf {
            return authError(TOKEN_NOT_YET_VALID, "Credentials are not valid yet");
        }
        if iss != trustedIssuer {
            // iss/aud are not secrets or PII; logging them at debug speeds up setup (runbook step C4).
            log:printDebug("Token issuer not trusted", iss = iss);
            return authError(TOKEN_ISSUER_INVALID, "Credentials issuer is not trusted");
        }
        string|string[]? aud = payload.aud;
        string[] auds = [];
        if aud is string {
            auds = [aud];
        } else if aud is string[] {
            auds = aud;
        }
        if (from string a in auds where self.config.audiences.indexOf(a) !is () select a).length() == 0 {
            log:printDebug("Token audience not accepted", aud = auds);
            return authError(TOKEN_AUDIENCE_INVALID, "Credentials are not for this API");
        }

        types:EmployeeId|types:DomainError employeeId = types:parseEmployeeId(payload.sub ?: "");
        anydata emailClaim = payload[self.config.emailClaim];
        string|types:DomainError email = types:parseEmail(emailClaim is string ? emailClaim.toString() : "");
        if employeeId is types:DomainError || email is types:DomainError {
            return authError(TOKEN_CLAIMS_INVALID, "Credentials are missing identity claims");
        }
        anydata name = payload[self.config.nameClaim];
        anydata rolesValue = payload[self.config.rolesClaim];
        string? displayName = ();
        if name is string {
            displayName = types:trimToNil(name);
        }
        string[] roles = knownGroups(rolesValue, self.config.access);
        return {employeeId, email, displayName, roles, grants: grantsOf(roles, self.config.access), issuer: trustedIssuer};
    }
}

# Groups from the roles claim that the access configuration names. A missing claim means a plain employee
# (no extra grant); other groups are dropped.
#
# + claim - Claim value: array of strings, or a comma/space separated string
# + access - Configured groups
# + return - Known groups, no duplicates
public isolated function knownGroups(anydata claim, AccessGroups access) returns string[] {
    string[] raw = [];
    if claim is string {
        raw = re `[,\s]+`.split(claim);
    } else if claim is anydata[] {
        foreach anydata item in claim {
            if item is string {
                raw.push(item);
            }
        }
    }
    string[] known = configuredGroups(access);
    string[] result = [];
    foreach string role in raw {
        string r = role.trim();
        if known.indexOf(r) !is () && result.indexOf(r) is () {
            result.push(r);
        }
    }
    return result;
}

# Decodes base64url without padding (RFC 7515).
#
# + input - Text
# + return - Bytes, or an error
public isolated function fromBase64Url(string input) returns byte[]|error {
    string std = re `_`.replaceAll(re `-`.replaceAll(input, "+"), "/");
    int pad = (4 - std.length() % 4) % 4;
    if pad == 3 {
        return error("Invalid base64url length");
    }
    return array:fromBase64(std + "==".substring(0, pad));
}

# Encodes base64url without padding (RFC 7515).
#
# + input - Bytes
# + return - Text
public isolated function toBase64Url(byte[] input) returns string =>
    re `=+$`.replace(re `/`.replaceAll(re `\+`.replaceAll(input.toBase64(), "-"), "_"), "");

isolated function verifiesWithAny(string signingInput, byte[] signature, Jwk[] keys) returns boolean {
    byte[] data = signingInput.toBytes();
    foreach Jwk k in keys {
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

isolated function authError(string code, string message) returns AuthError => error AuthError(message, code = code);
