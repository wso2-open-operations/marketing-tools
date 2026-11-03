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

// Novera, the Google Chat assistant, is Amplify's one announcement channel (owner decision 2026-11-03: it replaced
// the Club space webhook). A campaign announcement goes to `POST /internal/notifications`, and Novera sends it as a
// card to everyone who has a chat open with it.
// Mirrors the Today I Learned backend's novera client (cs-tools apps/today-i-learned/backend/internal/novera).
// Novera answers 202 before it has sent anything, so there is no message name to keep. No HTTP-level retry: the
// outbox retries (ADR-025).
// Novera does not dedupe (owner decision 2026-11-03: it ignores `Idempotency-Key`), so Amplify announces a campaign
// at most once on its own: every error says whether the card definitely did not go out (`delivered = "NO"`: the
// client could not be built, the breaker was open, or Novera answered 401, 403, 429, 503 or another refusal) or
// may have (`"UNKNOWN"`: no answer after the request was sent, or a 500, 502, 504 or other 5xx). The handler retries
// only the first kind. The `Idempotency-Key: amplify:<campaignId>` header still goes out on every attempt, in case
// Novera ever honours it.

import amplify_common.resilience;
import amplify_domain.announcements;

import ballerina/http;
import ballerina/log;

# Whether a failed Novera call may still have sent the card: `NO` (nothing went out) or `UNKNOWN` (it may have).
type NoveraDelivery "NO"|"UNKNOWN";

# Why Novera did not accept an announcement.
type NoveraErrorDetail record {|
    # `UNAVAILABLE`, `RATE_LIMITED`, `REJECTED` or `OUTCOME_UNKNOWN`
    string code;
    # HTTP status, `()` when there was no response
    int? httpStatus;
    # True when the outbox should try again (only ever with `delivered = "NO"`)
    boolean retryable;
    # `NO` when the card definitely did not go out, `UNKNOWN` when it may have
    NoveraDelivery delivered;
|};

type NoveraError distinct error<NoveraErrorDetail>;

# Header that carries the announcement's idempotency key.
const string IDEMPOTENCY_HEADER = "Idempotency-Key";

# Port to Novera's notifications endpoint.
type NoveraPort isolated object {
    isolated function notify(announcements:NoveraNotification notification, string idempotencyKey,
            string? correlationId) returns NoveraError?;
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

    isolated function notify(announcements:NoveraNotification notification, string idempotencyKey,
            string? correlationId) returns NoveraError? {
        http:Client|error conn = self.connect();
        if conn is error {
            // The token fetch failed while the client was built: no request reached Novera.
            return noveraError("UNAVAILABLE", "Novera token endpoint unreachable", (), true, "NO");
        }
        map<string> headers = resilience:correlationHeaders(correlationId);
        headers[IDEMPOTENCY_HEADER] = idempotencyKey;
        http:Response|http:ClientError response = conn->post(self.path, notification.toJson(), headers);
        if response is http:ClientError {
            if response is http:UpstreamServiceUnavailableError {
                // The breaker is open: the client refused before sending anything.
                return noveraError("UNAVAILABLE", "Novera circuit open, nothing sent", (), true, "NO");
            }
            if failedBeforeSending(response) {
                // A refused connection or an unresolved host: no byte of the request left, so Novera got nothing
                // and the outbox may retry (a Novera outage is not a pile of "Delivery unknown" rows).
                return noveraError("UNAVAILABLE", "Novera unreachable (connection refused), nothing sent", (), true,
                        "NO");
            }
            // A timeout or a dropped connection: the request may have reached Novera.
            return noveraError("OUTCOME_UNKNOWN", "Novera call failed: no response, the card may have gone out", (),
                    false, "UNKNOWN");
        }
        int status = response.statusCode;
        if status == http:STATUS_ACCEPTED || status == http:STATUS_OK {
            return;
        }
        if status == http:STATUS_TOO_MANY_REQUESTS {
            return noveraError("RATE_LIMITED", "Novera rate limited", status, true, "NO");
        }
        if status == http:STATUS_UNAUTHORIZED || status == http:STATUS_FORBIDDEN {
            // A rotated client secret or a revoked subscription is an operator problem, not a bad card: retry
            // (the row stays queued and the run keeps trying) instead of failing every announcement for good.
            return noveraError("UNAVAILABLE", string `Novera refused our credentials with HTTP ${status}`, status, true,
                    "NO");
        }
        if status == http:STATUS_SERVICE_UNAVAILABLE {
            // Novera could not get a Google token and sent nothing.
            return noveraError("UNAVAILABLE", "Novera unavailable (HTTP 503), nothing sent", status, true, "NO");
        }
        if status >= 500 {
            // 500, 502, 504 and the rest: Novera or the gateway may have handed the card on before failing.
            return noveraError("OUTCOME_UNKNOWN", string `Novera failed with HTTP ${status}, the card may have gone out`,
                    status, false, "UNKNOWN");
        }
        return noveraError("REJECTED", string `Novera refused the announcement with HTTP ${status}`, status, false,
                "NO");
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

isolated function noveraError(string code, string message, int? httpStatus, boolean retryable,
        NoveraDelivery delivered) returns NoveraError =>
    error NoveraError(message, code = code, httpStatus = httpStatus, retryable = retryable, delivered = delivered);

# Checks `noveraButtonUrl` at start-up. Empty is allowed (announcements then wait with "Novera button URL is not
# configured"); anything else must be an https URL template containing `{campaignId}` (http only with
# `noveraAllowInsecureHttp`, local stack only).
#
# + template - `noveraButtonUrl`
# + allowInsecureHttp - `noveraAllowInsecureHttp`
# + return - An error naming the setting and the problem
isolated function validateNoveraButtonUrl(string template, boolean allowInsecureHttp) returns error? {
    string trimmed = template.trim();
    if trimmed == "" {
        return;
    }
    error? invalid = announcements:checkButtonUrlTemplate(trimmed, allowInsecureHttp);
    if invalid is error {
        return error(string `noveraButtonUrl is invalid: ${invalid.message()}`);
    }
}

# Whether a client error happened before any byte of the request was sent: the connection was refused or the host
# did not resolve. These cannot occur after a request was written, so the card did not go out. The client types do
# not separate them from a reset connection, so the (cause chain) messages are read. A timeout or a reset is never
# matched here: those stay "delivery unknown".
#
# + err - The client error
# + return - True when the failure was before sending
isolated function failedBeforeSending(error err) returns boolean {
    error? current = err;
    int depth = 0;
    while current is error && depth < 8 {
        string message = current.message().toLowerAscii();
        if message.includes("connection refused") || message.includes("unknownhost") || message.includes("unknown host")
                || message.includes("no route to host") || message.includes("network is unreachable")
                || message.includes("name or service not known") || message.includes("nodename nor servname")
                || message.includes("failed to resolve") {
            return true;
        }
        current = current.cause();
        depth += 1;
    }
    return false;
}
