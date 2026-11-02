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
import ballerina/log;
import ballerina/time;

# One RSA signing key from a JWKS (only the parts we need).
public type Jwk record {|
    # Key id; `()` when the set doesn't name its keys
    string? kid;
    # Modulus, base64url
    string n;
    # Exponent, base64url
    string e;
|};

# JWKS fetch settings. Values come from `configurable`s in the component.
public type JwksConfig record {|
    # Gateway JWKS URL
    string url;
    # Keys older than this are refreshed (they keep serving if the refresh fails)
    decimal refreshSeconds = 3600;
    # At most one refresh per interval for an unknown `kid` or stale keys (stops kid floods)
    decimal minRefreshIntervalSeconds = 30;
    # HTTP timeout
    decimal timeoutSeconds = 5;
    # Breaker: failure ratio that opens it
    float breakerFailureThreshold = 0.5;
    # Breaker: seconds before a half-open probe
    decimal breakerResetSeconds = 30;
    # Breaker: rolling window, seconds
    decimal breakerWindowSeconds = 60;
|};

# Cached gateway JWKS behind a circuit breaker. Keys are refreshed on age or an unknown `kid`; when the
# IdP is down the last good keys keep serving (M9).
public isolated class JwksCache {
    private final http:Client httpClient;
    private final decimal refreshSeconds;
    private final decimal minRefreshIntervalSeconds;
    private Jwk[] keys = [];
    private decimal fetchedAt = -1d;
    private decimal lastAttemptAt = -1d;

    # + config - Settings
    # + return - An error when the URL is invalid
    public isolated function init(JwksConfig config) returns error? {
        self.refreshSeconds = config.refreshSeconds;
        self.minRefreshIntervalSeconds = config.minRefreshIntervalSeconds;
        self.httpClient = check new (config.url, {
            timeout: config.timeoutSeconds,
            circuitBreaker: {
                rollingWindow: {timeWindow: config.breakerWindowSeconds, bucketSize: config.breakerWindowSeconds / 6,
                    requestVolumeThreshold: 1},
                failureThreshold: config.breakerFailureThreshold,
                resetTime: config.breakerResetSeconds,
                statusCodes: [500, 502, 503, 504]
            }
        });
    }

    # State of the JWKS breaker, for `/ready`.
    #
    # + return - `CLOSED`, `HALF_OPEN` or `OPEN`
    public isolated function breakerState() returns http:CircuitState => self.httpClient.getCircuitBreakerCurrentState();

    # Candidate keys for a token.
    #
    # + kid - Token `kid`, or `()`
    # + return - Matching keys (all keys when the token has no `kid`), or `KEYS_UNAVAILABLE` when there
    # are none and the JWKS can't be fetched
    public isolated function keysFor(string? kid) returns Jwk[]|AuthError {
        decimal now = time:monotonicNow();
        boolean refresh;
        lock {
            boolean empty = self.keys.length() == 0;
            boolean stale = self.fetchedAt < 0d || now - self.fetchedAt >= self.refreshSeconds;
            boolean unknownKid = kid is string && keysMatching(self.keys, kid).length() == 0;
            // Holds on a cold cache too: a burst of requests at start-up, or during a JWKS outage, makes one
            // fetch per interval instead of one per request.
            boolean gated = self.lastAttemptAt >= 0d && now - self.lastAttemptAt < self.minRefreshIntervalSeconds;
            refresh = (empty || stale || unknownKid) && !gated;
            if refresh {
                self.lastAttemptAt = now;
            }
        }
        if refresh {
            Jwk[]|error fetched = self.fetch();
            if fetched is error {
                log:printWarn("JWKS refresh failed; serving cached keys", reason = fetched.message());
            } else {
                lock {
                    self.keys = fetched.clone();
                    self.fetchedAt = now;
                }
            }
        }
        lock {
            if self.keys.length() == 0 {
                return authError(KEYS_UNAVAILABLE, "Signing keys are unavailable");
            }
            return keysMatching(self.keys, kid).clone();
        }
    }

    isolated function fetch() returns Jwk[]|error {
        json body = check self.httpClient->get("");
        return parseJwks(body);
    }
}

# RSA signing keys from a JWKS document; other key types and encryption keys are skipped.
#
# + body - JWKS JSON
# + return - Keys, or an error when the document has none
public isolated function parseJwks(json body) returns Jwk[]|error {
    json[] entries = check (check body.keys).ensureType();
    Jwk[] result = [];
    foreach json entry in entries {
        if entry !is map<json> || entry["kty"] != "RSA" {
            continue;
        }
        json use = entry["use"];
        json n = entry["n"];
        json e = entry["e"];
        json kid = entry["kid"];
        if (use is () || use == "sig") && n is string && e is string {
            result.push({kid: kid is string ? kid.toString() : (), n, e});
        }
    }
    if result.length() == 0 {
        return error("JWKS has no RSA signing keys");
    }
    return result;
}

isolated function keysMatching(Jwk[] keys, string? kid) returns Jwk[] =>
    kid is () ? keys : from Jwk k in keys where k.kid == kid select k;
