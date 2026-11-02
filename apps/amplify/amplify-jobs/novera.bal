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

// Novera, the Google Chat assistant (feat/amplify_on_novera). A campaign announcement goes to
// `POST /internal/notifications`, and Novera sends it as a card to everyone who has a chat open with it.
// Mirrors the Today I Learned backend's novera client (cs-tools apps/today-i-learned/backend/internal/novera).
// Novera answers 202 before it has sent anything, so there is no message name to keep. A 503 means Novera
// couldn't get a Google token and sent nothing: retryable. No HTTP-level retry: the outbox retries (ADR-025).

import amplify_common.resilience;
import amplify_domain.announcements;

import ballerina/http;
import ballerina/log;

# Why Novera did not accept an announcement.
type NoveraErrorDetail record {|
    # `UNAVAILABLE`, `RATE_LIMITED` or `REJECTED`
    string code;
    # HTTP status, `()` when there was no response
    int? httpStatus;
    # True when the outbox should try again
    boolean retryable;
|};

type NoveraError distinct error<NoveraErrorDetail>;

# Port to Novera's notifications endpoint.
type NoveraPort isolated object {
    isolated function notify(announcements:NoveraNotification notification, string? correlationId)
        returns NoveraError?;
    isolated function breaker() returns string;
};

# `NoveraPort` over the Choreo gateway, with a client-credentials token from an application subscribed to
# Novera's API. The HTTP client is built on the first call, not in `init`: the OAuth2 client fetches its token
# while it is built, so building it at start-up would stop amplify-jobs from starting whenever the token endpoint
# is down. A failed build is a retryable `UNAVAILABLE` and is tried again on the next call.
isolated class NoveraClient {
    *NoveraPort;

    private final string baseUrl;
    private final string path;
    private final string tokenUrl;
    private final string clientId;
    private final string clientSecret;
    private final readonly & string[] scopes;
    private final decimal timeoutSeconds;
    private final resilience:HttpResilience & readonly settings;
    private http:Client? httpClient = ();

    # + notifyUrl - Novera's `POST /internal/notifications` URL (https)
    # + tokenUrl - Token endpoint
    # + clientId - Client id of the subscribed application
    # + clientSecret - Client secret
    # + scopes - Token scopes
    # + timeoutSeconds - Per-call timeout (token and notification)
    # + settings - Breaker and pool settings
    # + allowInsecureHttp - Local stack only: accept a plain-http notify URL (the `local/novera-mock`). Never set in
    # Choreo
    # + return - An error when the URL is not https
    isolated function init(string notifyUrl, string tokenUrl, string clientId, string clientSecret, string[] scopes,
            decimal timeoutSeconds, resilience:HttpResilience settings = {}, boolean allowInsecureHttp = false)
            returns error? {
        string url = notifyUrl.trim();
        string lower = url.toLowerAscii();
        boolean insecureOk = allowInsecureHttp && lower.startsWith("http://");
        if !lower.startsWith("https://") && !insecureOk {
            return error("Novera notify URL must be HTTPS");
        }
        int pathStart = url.indexOf("/", lower.startsWith("https://") ? 8 : 7) ?: url.length();
        self.baseUrl = url.substring(0, pathStart);
        string path = url.substring(pathStart);
        self.path = path.length() == 0 ? "/" : path;
        self.tokenUrl = tokenUrl;
        self.clientId = clientId;
        self.clientSecret = clientSecret;
        self.scopes = scopes.cloneReadOnly();
        self.timeoutSeconds = timeoutSeconds;
        self.settings = settings.cloneReadOnly();
    }

    isolated function notify(announcements:NoveraNotification notification, string? correlationId)
            returns NoveraError? {
        http:Client|error conn = self.connect();
        if conn is error {
            return noveraError("UNAVAILABLE", "Novera token endpoint unreachable", (), true);
        }
        http:Response|http:ClientError response = conn->post(self.path, notification.toJson(),
                resilience:correlationHeaders(correlationId));
        if response is http:ClientError {
            return noveraError("UNAVAILABLE", "Novera call failed: no response", (), true);
        }
        int status = response.statusCode;
        if status == http:STATUS_ACCEPTED || status == http:STATUS_OK {
            return;
        }
        if status == http:STATUS_TOO_MANY_REQUESTS {
            return noveraError("RATE_LIMITED", "Novera rate limited", status, true);
        }
        if status == http:STATUS_UNAUTHORIZED || status == http:STATUS_FORBIDDEN {
            // A rotated client secret or a revoked subscription is an operator problem, not a bad card: retry
            // (the row stays queued and the run keeps trying) instead of failing every announcement for good.
            return noveraError("UNAVAILABLE", string `Novera refused our credentials with HTTP ${status}`, status, true);
        }
        if status >= 500 {
            return noveraError("UNAVAILABLE", string `Novera failed with HTTP ${status}`, status, true);
        }
        return noveraError("REJECTED", string `Novera refused the announcement with HTTP ${status}`, status, false);
    }

    isolated function breaker() returns string {
        lock {
            http:Client? conn = self.httpClient;
            return conn is () ? "CLOSED" : resilience:breakerState(conn);
        }
    }

    isolated function connect() returns http:Client|error {
        lock {
            http:Client? existing = self.httpClient;
            if existing is http:Client {
                return existing;
            }
        }
        // The OAuth2 client fetches its token while it is built, so build it outside the lock: `breaker()` (and
        // therefore `GET /ready`) must not wait for a slow token endpoint. Two callers may build at once; the
        // first to publish wins and the other is dropped.
        http:ClientConfiguration config = resilience:clientConfig(self.settings, self.timeoutSeconds);
        http:OAuth2ClientCredentialsGrantConfig grant = {tokenUrl: self.tokenUrl, clientId: self.clientId,
            clientSecret: self.clientSecret, scopes: self.scopes.clone()};
        config.auth = grant;
        // The constructor panics when it can't fetch the token: trap it.
        http:Client|error created = trap new (self.baseUrl, config);
        if created is error {
            log:printWarn("Novera client could not be built (token fetch)", resilience:loggable(created));
            return created;
        }
        http:Client? winner;
        lock {
            winner = self.httpClient;
            if winner is () {
                self.httpClient = created;
            }
        }
        if winner is http:Client {
            // A concurrent caller won the build race: ours is dropped (`http:Client` has no close here). The
            // race happens only when the first two callers start together, so at most one client is wasted.
            return winner;
        }
        return created;
    }
}

isolated function noveraError(string code, string message, int? httpStatus, boolean retryable) returns NoveraError =>
    error NoveraError(message, code = code, httpStatus = httpStatus, retryable = retryable);
