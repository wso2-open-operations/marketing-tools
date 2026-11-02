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

import amplify_common.resilience;

import ballerina/http;
import ballerina/url;

# Reply in the campaign's thread, or start one.
const string REPLY_OPTION = "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD";

# Incoming webhook settings. The URL carries the space key and token: treat it as a secret: never log it, never put it in an error, and keep it off trace spans (transport.bal).
public type WebhookConfig record {|
    # Full webhook URL, `https://chat.googleapis.com/v1/spaces/{space}/messages?key=…&token=…`.
    # Plain `http` is accepted only for `localhost` / `127.0.0.1`, or any host when `allowInsecureHttp`.
    string webhookUrl;
    # Local stack only: accept plain `http` to any host (the compose `chat-stub`). Never set in Choreo
    boolean allowInsecureHttp = false;
    # Per-call timeout
    decimal timeoutSeconds = 10;
    # Breaker (M9): window, volume, ratio, reset time and status codes apply; retry and pool size do not (the call
    # goes through the JDK client, see transport.bal). Retry stays 0: a repeated webhook call posts the card twice (ADR-025)
    resilience:HttpResilience resilience = {};
|};

# A message Chat accepted.
public type ChatMessage record {|
    # Resource name, `spaces/{space}/messages/{message}` (`announcement.chat_message_name`)
    string name;
    # Thread resource name, when returned
    string? threadName;
|};

# Category of a webhook failure.
public type ChatErrorCode "INVALID_CONFIG"|"REJECTED"|"RATE_LIMITED"|"UNAVAILABLE"|"BAD_RESPONSE";

# Detail of a webhook error. Never holds the webhook URL.
public type ChatErrorDetail record {|
    # Category
    ChatErrorCode code;
    # HTTP status, when there was a response
    int? httpStatus;
    # Whether a later retry is safe and may succeed. False for a timeout: Chat may already have posted the message
    boolean retryable;
|};

# A webhook call failed.
public type ChatError distinct error<ChatErrorDetail>;

# Sends messages to one Google Chat space through its incoming webhook.
public isolated class WebhookClient {
    private final handle jdkClient;
    private final Breaker breakerImpl;
    private final decimal timeoutSeconds;
    // Scheme and host (no user info), and the path with the webhook's own `key` / `token` query. The URL is
    // rebuilt only inside `post`, never logged, never put in an error or on a span (see transport.bal).
    private final string origin;
    private final string path;

    # Creates the client.
    #
    # + config - Webhook settings
    # + return - `INVALID_CONFIG` if the URL isn't HTTPS (or local http), or a client error
    public isolated function init(WebhookConfig config) returns error? {
        string webhookUrl = config.webhookUrl.trim();
        string lower = webhookUrl.toLowerAscii();
        boolean local = lower.startsWith("http://") && isLoopbackHost(hostOf(lower.substring(7)));
        boolean insecureOk = config.allowInsecureHttp && lower.startsWith("http://");
        if !lower.startsWith("https://") && !local && !insecureOk {
            return chatError("INVALID_CONFIG", "Chat webhook URL must be HTTPS", (), false);
        }
        int schemeEnd = webhookUrl.indexOf("://") ?: 0;
        int pathStart = webhookUrl.indexOf("/", schemeEnd + 3) ?: webhookUrl.length();
        // The client gets scheme and host only: anything before `@` in the authority (`user@host`) is dropped.
        string authority = webhookUrl.substring(schemeEnd + 3, pathStart);
        int at = authority.lastIndexOf("@") ?: -1;
        string host = at >= 0 ? authority.substring(at + 1) : authority;
        self.origin = webhookUrl.substring(0, schemeEnd + 3) + host;
        self.timeoutSeconds = config.timeoutSeconds;
        self.jdkClient = newJdkClient(config.timeoutSeconds);
        resilience:HttpResilience r = config.resilience;
        self.breakerImpl = new (r.rollingWindowSeconds, r.requestVolumeThreshold, r.failureThreshold,
                r.resetTimeSeconds, r.breakerStatusCodes);
        string path = webhookUrl.substring(pathStart);
        self.path = path.length() == 0 ? "/" : path;
    }

    # Posts a message to the space, threaded by `threadKey`.
    #
    # + message - Message body, for example from `buildCampaignCard`
    # + threadKey - Thread key, for example from `threadKey(campaignId)`
    # + correlationId - Sent as `X-Correlation-ID`
    # + return - The created message, or a chat error. A response timeout is `UNAVAILABLE` with `retryable = false`
    # (the card may already be in the space); a refused connection or other no-response failure is retryable
    public isolated function post(json message, string threadKey, string? correlationId = ())
            returns ChatMessage|ChatError {
        string|url:Error encodedKey = url:encode(threadKey, "UTF-8");
        if encodedKey is url:Error {
            return chatError("INVALID_CONFIG", "Thread key could not be encoded", (), false);
        }
        string separator = self.path.includes("?") ? "&" : "?";
        string target = string `${self.path}${separator}threadKey=${encodedKey}&messageReplyOption=${REPLY_OPTION}`;
        // `target` carries the webhook key and token, so this call does not go through `ballerina/http`: its
        // client spans would carry the URL as `http.url`. `jdkPost` is not instrumented (transport.bal).
        if !self.breakerImpl.admit() {
            return chatError("UNAVAILABLE", "Chat webhook breaker is open", (), true);
        }
        RawResponse|NoResponse response = jdkPost(self.jdkClient, self.origin + target, message.toJsonString(),
                resilience:correlationHeaders(correlationId), self.timeoutSeconds);
        if response is NoResponse {
            self.breakerImpl.note(true);
            if response == "TIMEOUT" {
                // Chat may already have created the message; a retry would post the card again (ADR-025)
                return chatError("UNAVAILABLE", "Chat webhook call timed out; the card may have been posted", (), false);
            }
            return chatError("UNAVAILABLE", "Chat webhook call failed: no response", (), true);
        }
        int status = response.status;
        self.breakerImpl.note(self.breakerImpl.failsBreaker(status));
        if status == http:STATUS_TOO_MANY_REQUESTS {
            return chatError("RATE_LIMITED", "Chat webhook rate limited", status, true);
        }
        if status >= 500 {
            return chatError("UNAVAILABLE", string `Chat webhook failed with HTTP ${status}`, status, true);
        }
        if status != http:STATUS_OK {
            return chatError("REJECTED", string `Chat webhook refused the message with HTTP ${status}`, status, false);
        }
        json body = parseJson(response.body);
        if body is map<json> {
            json name = body["name"];
            json thread = body["thread"];
            string? threadName = ();
            if thread is map<json> && thread["name"] is string {
                threadName = <string>thread["name"];
            }
            if name is string {
                return {name, threadName};
            }
        }
        return chatError("BAD_RESPONSE", "Chat webhook returned no message name", status, false);
    }

    # Breaker state, for the run log.
    #
    # + return - `CLOSED`, `HALF_OPEN` or `OPEN`
    public isolated function breaker() returns resilience:BreakerState => self.breakerImpl.state();
}

// Host of `host[:port][/path][?query]`, without user info. Exact match only: a prefix check would let
// `http://localhost.example.com` send the webhook key and token in clear text.
isolated function hostOf(string afterScheme) returns string {
    int end = afterScheme.length();
    foreach string sep in ["/", "?", "#"] {
        int? i = afterScheme.indexOf(sep);
        if i is int && i < end {
            end = i;
        }
    }
    string authority = afterScheme.substring(0, end);
    int? at = authority.lastIndexOf("@");
    if at is int {
        authority = authority.substring(at + 1);
    }
    int? colon = authority.indexOf(":");
    return colon is int ? authority.substring(0, colon) : authority;
}

isolated function isLoopbackHost(string host) returns boolean => host == "localhost" || host == "127.0.0.1";

isolated function chatError(ChatErrorCode code, string message, int? httpStatus, boolean retryable) returns ChatError =>
    error ChatError(message, code = code, httpStatus = httpStatus, retryable = retryable);
