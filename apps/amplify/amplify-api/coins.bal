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

// Wallet capture for the automatic Coins conversion (ADR-048): `POST /me/coins/wallet` asks the WSO2 Coins transaction
// service for the signed-in employee's wallets (`GET /wallets/me`) with Amplify's service token and the caller's own
// backend JWT forwarded as `X-User-Assertion` (the same as the Swag Store), takes the default wallet (else the first)
// and stores it. The conversion in amplify-jobs sends Coins only to a captured wallet. The token and the full address
// are never logged; the API answers the address masked.

import amplify_api.auth;
import amplify_common.coins;
import amplify_common.resilience;
import amplify_domain.scoring;

import ballerina/http;
import ballerina/log;
import ballerina/time;

# Base URL of the WSO2 Coins transaction service (its Choreo gateway URL, https). Empty = not configured: the wallet
# capture answers 503 `COINS_UNAVAILABLE`.
configurable string coinsBaseUrl = "";
# Token endpoint of the client-credentials grant (an application subscribed to the Coins API).
configurable string coinsTokenUrl = "";
# Client id of that application.
configurable string coinsClientId = "";
# Client secret of that application (Choreo secret; never logged).
configurable string coinsClientSecret = "";
# Comma-separated scopes for the token; empty = none.
configurable string coinsScopes = "";
# Seconds before a Coins call (token or API) gives up.
configurable decimal coinsTimeoutSeconds = 10;
# Coins breaker and pool.
configurable resilience:HttpResilience coinsResilience = {};

final coins:CoinsClient? coinsClient = check newCoinsClient();

# The Coins client, `()` when any of the URL, token endpoint or credentials is not set.
#
# + return - The client, `()`, or an error when a set value is invalid (not https)
isolated function newCoinsClient() returns coins:CoinsClient?|error {
    if coinsBaseUrl.trim() == "" || coinsTokenUrl.trim() == "" || coinsClientId.trim() == ""
            || coinsClientSecret.trim() == "" {
        return ();
    }
    return check new coins:CoinsClient({
        baseUrl: coinsBaseUrl,
        tokenUrl: coinsTokenUrl,
        clientId: coinsClientId,
        clientSecret: coinsClientSecret,
        scopes: from string scope in re `,`.split(coinsScopes)
            let string trimmed = scope.trim()
            where trimmed != ""
            select trimmed,
        timeoutSeconds: coinsTimeoutSeconds,
        resilience: coinsResilience
    });
}

# The Coins port (a seam the tests replace).
#
# + return - The client, or `()` when not configured
isolated function coinsPort() returns coins:CoinsPort? => coinsClient;

# Breaker state of the Coins client, for `/ready` (reported, never gating).
#
# + return - The state, or `NOT_CONFIGURED`
isolated function coinsBreaker() returns BreakerReport {
    coins:CoinsPort? c = coinsPort();
    return c is () ? "NOT_CONFIGURED" : c.breaker();
}

# `POST /me/coins/wallet`: captures the caller's Coins wallet.
#
# + p - Employee
# + userAssertion - The caller's backend JWT as the gateway sent it (the `jwtHeader` header)
# + correlationId - Correlation id
# + return - 200 with the masked wallet, 404 `NO_WALLET`, 503 `COINS_UNAVAILABLE`, or problem details
isolated function captureCoinsWallet(auth:Principal p, string? userAssertion, string? correlationId)
        returns http:StatusCodeResponse {
    coins:CoinsPort? port = coinsPort();
    if port is () || userAssertion is () {
        return coinsUnavailable(correlationId);
    }
    do {
        scoring:CoinWallet|coins:CoinsError|error? captured = scoring:captureWallet(check coinWalletRepository(actorOf(p,
                correlationId)), port, p.employeeId, userAssertion, correlationId, time:utcNow());
        if captured is coins:CoinsError {
            log:printWarn("Coins wallet lookup failed", errorCode = captured.detail().code,
                    httpStatus = captured.detail().httpStatus, correlationId = correlationId);
            return coinsUnavailable(correlationId);
        }
        if captured is error {
            fail captured;
        }
        if captured is () {
            return <http:NotFound>{
                mediaType: PROBLEM_JSON,
                body: problem(404, "Not Found", NO_WALLET,
                        "WSO2 Coins has no wallet for you yet; create one in WSO2 Coins, then try again", correlationId)
            };
        }
        return <http:Ok>{body: walletDto(captured.walletAddress, captured.capturedAt)};
    } on fail error e {
        return failure(e, correlationId, "Capture Coins wallet");
    }
}

# The wallet as the screens show it.
#
# + address - Full address
# + capturedAt - When it was captured
# + return - `{walletAddress (masked), capturedAt}`
isolated function walletDto(string address, time:Utc capturedAt) returns json =>
    {walletAddress: scoring:maskWallet(address), capturedAt: ts(capturedAt)};

isolated function coinsUnavailable(string? correlationId) returns http:ServiceUnavailable =>
    unavailable(COINS_UNAVAILABLE, correlationId, "WSO2 Coins can't be reached right now, try again shortly");
