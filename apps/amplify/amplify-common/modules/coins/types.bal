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

// Shapes of the WSO2 Coins transaction service (wso2-coin operations/transaction-service, internal/model) and the
// port Amplify calls it through (ADR-048). Amounts are decimal strings on the wire (9 decimal places at most).

import amplify_common.resilience;

# Header the Coins service reads the signed-in user's token from (its `USER_ASSERTION_HEADER` default).
public const string USER_ASSERTION_HEADER = "X-User-Assertion";

# Endpoint and the client-credentials application Amplify calls the Coins service with. The application's client id
# is what the service maps to Amplify's master wallet (`client_master_wallet`).
public type CoinsConfig record {|
    # Base URL of the Coins transaction service as Amplify reaches it (the Choreo gateway URL)
    string baseUrl;
    # Token endpoint of the client-credentials grant
    string tokenUrl;
    # Client id of the subscribed application
    string clientId;
    # Its client secret (a Choreo secret; never logged)
    string clientSecret;
    # Token scopes; empty asks for none
    string[] scopes = [];
    # Per-call timeout, seconds (token and API)
    decimal timeoutSeconds = 10;
    # Breaker and pool. Retry stays 0: a transfer is not idempotent, and the conversion reconciles instead
    resilience:HttpResilience resilience = {};
    # Header the user's token goes in on `GET /wallets/me`
    string userAssertionHeader = USER_ASSERTION_HEADER;
|};

# One of the signed-in user's wallets (`GET /wallets/me`).
public type Wallet record {|
    # Wallet address
    string address;
    # Balance as the service sent it
    string balance;
    # The user's default wallet
    boolean isDefault;
|};

# The master wallet mapped to Amplify's client, and what it holds (`GET /wallets/master/balance`).
public type MasterBalance record {|
    # Master wallet address
    string walletAddress;
    # Balance as the service sent it
    string balance;
|};

# A transfer the service recorded (`POST /wallets/master/transfer`, 201).
public type Transfer record {|
    # The service's reference (it generates it; there is no caller reference)
    string reference;
    # Master wallet
    string fromAddress;
    # Recipient wallet
    string toAddress;
    # Amount as the service sent it
    string amount;
|};

# One recorded transaction (`GET /transactions/{reference}`, `POST /transactions/search`).
public type Transaction record {|
    # The service's reference
    string reference;
    # From wallet
    string fromAddress;
    # To wallet
    string toAddress;
    # Amount as the service sent it
    string amount;
    # When the service recorded it, as it sent it (RFC 3339)
    string timestamp;
|};

# Filter of `POST /transactions/search`. Supplied fields are combined with AND.
public type SearchFilter record {|
    # From any of these wallets (at most 100)
    string[] fromAddresses = [];
    # To any of these wallets (at most 100)
    string[] toAddresses = [];
    # Recorded at or after, RFC 3339
    string? dateFrom = ();
    # Recorded at or before, RFC 3339
    string? dateTo = ();
    # Page size (the service caps it at 100)
    int 'limit = 100;
    # Rows to skip
    int offset = 0;
|};

# One page of search results, newest first.
public type TransactionPage record {|
    # Transactions on this page
    Transaction[] transactions;
    # Matches across every page
    int total;
|};

# Nothing reached the service, or it answered that nothing moved: retry later.
public const UNAVAILABLE = "UNAVAILABLE";
# The service refused Amplify's token (401, 403): a configuration problem, nothing moved.
public const UNAUTHORIZED = "UNAUTHORIZED";
# The service or the gateway throttled the call (429): nothing moved.
public const RATE_LIMITED = "RATE_LIMITED";
# The master wallet cannot cover the transfer: nothing moved.
public const INSUFFICIENT_FUNDS = "INSUFFICIENT_FUNDS";
# The recipient wallet does not exist at the service: nothing moved.
public const RECIPIENT_NOT_FOUND = "RECIPIENT_NOT_FOUND";
# Any other refusal (4xx): nothing moved.
public const REJECTED = "REJECTED";
# The service does not know the resource (404).
public const NOT_FOUND = "NOT_FOUND";
# The user's token was refused (401 on a user call).
public const USER_UNAUTHORIZED = "USER_UNAUTHORIZED";
# The call was sent and no clear answer came back (timeout, reset, 5xx): the transfer may have happened.
public const OUTCOME_UNKNOWN = "OUTCOME_UNKNOWN";
# A success answer that could not be read.
public const BAD_RESPONSE = "BAD_RESPONSE";

# Why a Coins call failed.
public type CoinsErrorCode UNAVAILABLE|UNAUTHORIZED|RATE_LIMITED|INSUFFICIENT_FUNDS|RECIPIENT_NOT_FOUND|REJECTED
    |NOT_FOUND|USER_UNAUTHORIZED|OUTCOME_UNKNOWN|BAD_RESPONSE;

# Whether a failed call may still have moved Coins: `NO`, or `UNKNOWN` (reconcile before sending again).
public type Delivery "NO"|"UNKNOWN";

# Detail of a failed Coins call. Carries codes and status only, never a token or a response body.
public type CoinsErrorDetail record {|
    # Stable code
    CoinsErrorCode code;
    # HTTP status, `()` when there was no answer
    int? httpStatus;
    # `NO`: nothing moved; `UNKNOWN`: a transfer may have happened
    Delivery delivered;
|};

# A failed Coins call.
public type CoinsError distinct error<CoinsErrorDetail>;

# Port to the Coins transaction service, so the conversion and the wallet capture run on fakes in tests.
public type CoinsPort isolated object {
    # Moves Coins from Amplify's master wallet (`POST /wallets/master/transfer`). Not idempotent: on an error with
    # `delivered = UNKNOWN` reconcile (`searchTransfers`) before sending again.
    #
    # + toAddress - Recipient wallet
    # + amount - Whole Coins, more than 0
    # + correlationId - Sent as `X-Correlation-ID`
    # + return - The recorded transfer, or an error
    public isolated function transfer(string toAddress, int amount, string? correlationId = ()) returns Transfer|CoinsError;

    # The signed-in user's wallets, default first (`GET /wallets/me`).
    #
    # + userAssertion - The user's token, forwarded as `X-User-Assertion`
    # + correlationId - Sent as `X-Correlation-ID`
    # + return - Wallets (empty when the user has none), or an error
    public isolated function walletsOf(string userAssertion, string? correlationId = ()) returns Wallet[]|CoinsError;

    # Amplify's master wallet and its balance (`GET /wallets/master/balance`).
    #
    # + correlationId - Sent as `X-Correlation-ID`
    # + return - The balance, or an error
    public isolated function masterBalance(string? correlationId = ()) returns MasterBalance|CoinsError;

    # One transaction by the service's reference (`GET /transactions/{reference}`).
    #
    # + reference - The service's reference
    # + correlationId - Sent as `X-Correlation-ID`
    # + return - The transaction, `()` when the service has none, or an error
    public isolated function transactionByReference(string reference, string? correlationId = ())
        returns Transaction|CoinsError?;

    # One page of transactions matching a filter (`POST /transactions/search`).
    #
    # + filter - Filter
    # + correlationId - Sent as `X-Correlation-ID`
    # + return - The page, or an error
    public isolated function searchTransfers(SearchFilter filter, string? correlationId = ())
        returns TransactionPage|CoinsError;

    # Breaker state of the client, `CLOSED` before the first call.
    #
    # + return - `CLOSED`, `HALF_OPEN` or `OPEN`
    public isolated function breaker() returns resilience:BreakerState;
};

# Builds a `CoinsError`.
#
# + code - Stable code
# + message - Message (no token, no body)
# + httpStatus - HTTP status, `()` when there was no answer
# + delivered - `NO` or `UNKNOWN`
# + return - The error
public isolated function coinsError(CoinsErrorCode code, string message, int? httpStatus = (), Delivery delivered = "NO")
        returns CoinsError =>
    error CoinsError(message, code = code, httpStatus = httpStatus, delivered = delivered);
