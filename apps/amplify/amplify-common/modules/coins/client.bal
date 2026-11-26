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

// `CoinsPort` over HTTP, with a client-credentials token (mirrors the Swag Store's coins client in wso2-coin
// apps/swag-store/backend/internal/coins). The HTTP client is built on the first call, not in `init`: the OAuth2
// client fetches its token while it is built, so building it at start-up would stop a component from starting while
// the token endpoint is down. The built client keeps the token and fetches a new one when it expires.
//
// Every error says whether Coins may have moved (`delivered`): `NO` when nothing reached the service (token fetch,
// open breaker, refused connection) or the service refused (4xx); `UNKNOWN` when the call was sent and no clear answer
// came back (timeout, reset, 5xx, or a 201 that could not be read). No HTTP-level retry: a transfer is not idempotent.

import amplify_common.resilience;

import ballerina/http;
import ballerina/log;
import ballerina/url;

# `CoinsPort` over the Coins transaction service.
public isolated class CoinsClient {
    *CoinsPort;

    private final string baseUrl;
    private final string tokenUrl;
    private final string clientId;
    private final string clientSecret;
    private final readonly & string[] scopes;
    private final decimal timeoutSeconds;
    private final resilience:HttpResilience & readonly settings;
    private final string userHeader;
    private http:Client? httpClient = ();

    # Checks the settings; contacts nothing.
    #
    # + config - Endpoint and credentials
    # + return - An error when the base URL is empty or not https (plain http only to localhost), or a credential is
    # missing
    public isolated function init(CoinsConfig config) returns error? {
        string url = config.baseUrl.trim();
        while url.endsWith("/") {
            url = url.substring(0, url.length() - 1);
        }
        check checkUrl(url, "Coins base URL");
        check checkUrl(config.tokenUrl.trim(), "Coins token URL");
        if config.clientId.trim() == "" || config.clientSecret.trim() == "" {
            return error("Coins client id and secret are required");
        }
        if config.timeoutSeconds <= 0d {
            return error("Coins timeout must be positive");
        }
        self.baseUrl = url;
        self.tokenUrl = config.tokenUrl.trim();
        self.clientId = config.clientId.trim();
        self.clientSecret = config.clientSecret.trim();
        self.scopes = config.scopes.cloneReadOnly();
        self.timeoutSeconds = config.timeoutSeconds;
        self.settings = config.resilience.cloneReadOnly();
        self.userHeader = config.userAssertionHeader;
    }

    public isolated function transfer(string toAddress, int amount, string? correlationId = ())
            returns Transfer|CoinsError {
        if amount <= 0 || toAddress.trim() == "" {
            return coinsError(REJECTED, "A transfer needs a wallet and a positive amount");
        }
        http:Response response = check self.send(http:POST, "/wallets/master/transfer",
                {toAddress, amount: amount.toString()}, resilience:correlationHeaders(correlationId));
        int status = response.statusCode;
        if status != http:STATUS_CREATED && status != http:STATUS_OK {
            return statusError(response, "transfer");
        }
        json|error body = response.getJsonPayload();
        // The transfer is recorded: an unreadable answer is not a failure, the reconcile finds the reference.
        if body is error {
            return coinsError(BAD_RESPONSE, "Coins transfer answer unreadable", status, "UNKNOWN");
        }
        Transfer|error t = toTransfer(body);
        if t is error {
            return coinsError(BAD_RESPONSE, "Coins transfer answer unreadable", status, "UNKNOWN");
        }
        return t;
    }

    public isolated function walletsOf(string userAssertion, string? correlationId = ()) returns Wallet[]|CoinsError {
        if userAssertion.trim() == "" {
            return coinsError(UNAUTHORIZED, "No user token to forward");
        }
        map<string> headers = resilience:correlationHeaders(correlationId);
        headers[self.userHeader] = userAssertion;
        http:Response response = check self.send(http:GET, "/wallets/me", (), headers);
        if response.statusCode != http:STATUS_OK {
            return statusError(response, "wallets");
        }
        json|error body = response.getJsonPayload();
        if body !is json[] {
            return coinsError(BAD_RESPONSE, "Coins wallets answer unreadable", response.statusCode);
        }
        Wallet[] defaults = [];
        Wallet[] others = [];
        foreach json item in body {
            WalletWire|error w = item.cloneWithType();
            if w is error || w.walletAddress.trim() == "" {
                return coinsError(BAD_RESPONSE, "Coins wallets answer unreadable", response.statusCode);
            }
            Wallet wallet = {address: w.walletAddress, balance: w.balance, isDefault: w.defaultWallet};
            if w.defaultWallet {
                defaults.push(wallet);
            } else {
                others.push(wallet);
            }
        }
        return [...defaults, ...others];
    }

    public isolated function masterBalance(string? correlationId = ()) returns MasterBalance|CoinsError {
        http:Response response = check self.send(http:GET, "/wallets/master/balance", (),
                resilience:correlationHeaders(correlationId));
        if response.statusCode != http:STATUS_OK {
            return statusError(response, "master balance");
        }
        json|error body = response.getJsonPayload();
        MasterBalance|error b = body is error ? body : body.cloneWithType();
        if b is error || b.walletAddress.trim() == "" {
            return coinsError(BAD_RESPONSE, "Coins master balance answer unreadable", response.statusCode);
        }
        return {walletAddress: b.walletAddress, balance: b.balance};
    }

    public isolated function transactionByReference(string reference, string? correlationId = ())
            returns Transaction|CoinsError? {
        string|error escaped = url:encode(reference, "UTF-8");
        if escaped is error || reference.trim() == "" {
            return coinsError(REJECTED, "Invalid transaction reference");
        }
        http:Response response = check self.send(http:GET, "/transactions/" + escaped, (),
                resilience:correlationHeaders(correlationId));
        if response.statusCode == http:STATUS_NOT_FOUND {
            return ();
        }
        if response.statusCode != http:STATUS_OK {
            return statusError(response, "transaction");
        }
        json|error body = response.getJsonPayload();
        Transaction|error t = body is error ? body : toTransaction(body);
        if t is error {
            return coinsError(BAD_RESPONSE, "Coins transaction answer unreadable", response.statusCode);
        }
        return t;
    }

    public isolated function searchTransfers(SearchFilter filter, string? correlationId = ())
            returns TransactionPage|CoinsError {
        http:Response response = check self.send(http:POST, "/transactions/search", searchBody(filter),
                resilience:correlationHeaders(correlationId));
        if response.statusCode != http:STATUS_OK {
            return statusError(response, "search");
        }
        json|error body = response.getJsonPayload();
        if body !is map<json> {
            return coinsError(BAD_RESPONSE, "Coins search answer unreadable", response.statusCode);
        }
        json items = body["transactions"];
        json total = body["total"];
        if items !is json[] && items !is () || total !is int {
            return coinsError(BAD_RESPONSE, "Coins search answer unreadable", response.statusCode);
        }
        Transaction[] transactions = [];
        foreach json item in items is json[] ? items : [] {
            Transaction|error t = toTransaction(item);
            if t is error {
                return coinsError(BAD_RESPONSE, "Coins search answer unreadable", response.statusCode);
            }
            transactions.push(t);
        }
        return {transactions, total};
    }

    public isolated function breaker() returns resilience:BreakerState {
        lock {
            http:Client? conn = self.httpClient;
            return conn is () ? "CLOSED" : resilience:breakerState(conn);
        }
    }

    # Sends one call. Errors here are the ones without an HTTP answer.
    #
    # + method - `GET` or `POST`
    # + path - Path under the base URL
    # + payload - JSON body for `POST`
    # + headers - Extra headers
    # + return - The response, or an error saying whether the call may have reached the service
    isolated function send(string method, string path, json payload, map<string> headers) returns http:Response|CoinsError {
        http:Client|error conn = self.connect();
        if conn is error {
            return coinsError(UNAVAILABLE, "Coins token endpoint unreachable, nothing sent");
        }
        http:Response|http:ClientError response;
        if method == http:GET {
            response = conn->get(path, headers);
        } else {
            response = conn->post(path, payload, headers);
        }
        if response is http:Response {
            return response;
        }
        if response is http:UpstreamServiceUnavailableError {
            return coinsError(UNAVAILABLE, "Coins circuit open, nothing sent");
        }
        if response is http:ClientAuthError || failedBeforeSending(response) {
            return coinsError(UNAVAILABLE, "Coins unreachable (token or connection), nothing sent");
        }
        return coinsError(OUTCOME_UNKNOWN, "Coins call failed without an answer", (), "UNKNOWN");
    }

    isolated function connect() returns http:Client|error {
        lock {
            http:Client? existing = self.httpClient;
            if existing is http:Client {
                return existing;
            }
        }
        // Built outside the lock (the token fetch may be slow): `breaker()` must not wait for it. Two callers may build
        // at once; the first to publish wins.
        http:ClientConfiguration config = resilience:clientConfig(self.settings, self.timeoutSeconds);
        config.auth = <http:OAuth2ClientCredentialsGrantConfig>{tokenUrl: self.tokenUrl, clientId: self.clientId,
            clientSecret: self.clientSecret, scopes: self.scopes.clone()};
        // The constructor panics when it can't fetch the token: trap it.
        http:Client|error created = trap new (self.baseUrl, config);
        if created is error {
            log:printWarn("Coins client could not be built (token fetch)", reason = created.message());
            return created;
        }
        lock {
            http:Client? winner = self.httpClient;
            if winner is http:Client {
                return winner;
            }
            self.httpClient = created;
            return created;
        }
    }
}

type WalletWire record {
    string walletAddress;
    string balance;
    boolean defaultWallet = false;
};

type TransferWire record {
    string reference;
    string fromAddress;
    string toAddress;
    string amount;
};

type TransactionWire record {
    string reference;
    string fromAddress;
    string toAddress;
    string amount;
    string timestamp = "";
};

isolated function toTransfer(json body) returns Transfer|error {
    TransferWire w = check body.cloneWithType();
    if w.reference.trim() == "" {
        return error("empty reference");
    }
    return {reference: w.reference, fromAddress: w.fromAddress, toAddress: w.toAddress, amount: w.amount};
}

isolated function toTransaction(json body) returns Transaction|error {
    TransactionWire w = check body.cloneWithType();
    return {reference: w.reference, fromAddress: w.fromAddress, toAddress: w.toAddress, amount: w.amount,
        timestamp: w.timestamp};
}

# The search body: only the fields that are set.
#
# + filter - Filter
# + return - JSON body
isolated function searchBody(SearchFilter filter) returns map<json> {
    map<json> body = {'limit: filter.'limit, offset: filter.offset};
    if filter.fromAddresses.length() > 0 {
        body["fromAddresses"] = filter.fromAddresses.clone();
    }
    if filter.toAddresses.length() > 0 {
        body["toAddresses"] = filter.toAddresses.clone();
    }
    string? dateFrom = filter.dateFrom;
    if dateFrom is string {
        body["dateFrom"] = dateFrom;
    }
    string? dateTo = filter.dateTo;
    if dateTo is string {
        body["dateTo"] = dateTo;
    }
    return body;
}

# Maps a non-success answer. The service answers `{"message": ...}`; only the two money refusals are told apart by
# their text (it has no error codes yet; the Swag Store matches the same text).
#
# + response - The answer
# + what - Call name, for the message
# + return - The error; every one here is `delivered = NO` except a 5xx
isolated function statusError(http:Response response, string what) returns CoinsError {
    int status = response.statusCode;
    if status == http:STATUS_UNAUTHORIZED || status == http:STATUS_FORBIDDEN {
        return coinsError(UNAUTHORIZED, string `Coins refused the ${what} call with HTTP ${status}`, status);
    }
    if status == http:STATUS_NOT_FOUND {
        return coinsError(NOT_FOUND, string `Coins ${what}: not found`, status);
    }
    if status == http:STATUS_TOO_MANY_REQUESTS {
        return coinsError(RATE_LIMITED, string `Coins ${what}: rate limited`, status);
    }
    if status >= 500 {
        return coinsError(OUTCOME_UNKNOWN, string `Coins ${what} failed with HTTP ${status}`, status, "UNKNOWN");
    }
    string message = "";
    json|error body = response.getJsonPayload();
    if body is map<json> && body["message"] is string {
        message = (<string>body["message"]).toLowerAscii();
    }
    if message.includes("insufficient funds") {
        return coinsError(INSUFFICIENT_FUNDS, string `Coins ${what}: insufficient funds`, status);
    }
    if message.includes("recipient wallet not found") {
        return coinsError(RECIPIENT_NOT_FOUND, string `Coins ${what}: recipient wallet not found`, status);
    }
    return coinsError(REJECTED, string `Coins refused the ${what} call with HTTP ${status}`, status);
}

# Whether an absolute URL is acceptable: https, or plain http to localhost only (local stack and tests).
#
# + url - URL
# + name - Setting name for the message
# + return - An error naming the problem
isolated function checkUrl(string url, string name) returns error? {
    string lower = url.toLowerAscii();
    if lower.startsWith("https://") && lower.length() > 8 {
        return;
    }
    if lower.startsWith("http://localhost") || lower.startsWith("http://127.0.0.1") {
        return;
    }
    return error(string `${name} must be https`);
}

# Whether a client error happened before any byte of the request was sent (refused connection, unresolved host).
# A timeout or a reset never matches: those stay "may have moved".
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
