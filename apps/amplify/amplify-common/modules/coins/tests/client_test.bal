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

// The Coins client against a local stub of the transaction service and its token endpoint (port 18215): the wire
// contract, the token kept between calls, and which failures may have moved Coins.

import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;

const int COINS_STUB_PORT = 18215;
// Nothing listens here: a refused connection.
const int CLOSED_PORT = 18298;
const string STUB = "http://localhost:18215";
const string SERVICE_TOKEN = "svc-token-1";
const string MASTER = "0xmaster";

isolated int tokenCalls = 0;
isolated json lastBody = ();
isolated string lastUserAssertion = "";
isolated string lastCorrelation = "";

listener http:Listener coinsListener = new (COINS_STUB_PORT);

service / on coinsListener {
    resource function post oauth2/token(http:Request req) returns json|http:Unauthorized|error {
        map<string> form = check req.getFormParams();
        string|http:HeaderNotFoundError basic = req.getHeader("Authorization");
        if form["grant_type"] != "client_credentials" || basic !is string || !basic.startsWith("Basic ") {
            return <http:Unauthorized>{};
        }
        lock {
            tokenCalls += 1;
        }
        return {access_token: SERVICE_TOKEN, token_type: "Bearer", expires_in: 3600};
    }

    resource function post wallets/master/transfer(http:Request req)
            returns http:Response|error {
        check expectServiceToken(req);
        json body = check req.getJsonPayload();
        lock {
            lastBody = body.cloneReadOnly();
        }
        string|http:HeaderNotFoundError cid = req.getHeader("X-Correlation-ID");
        lock {
            lastCorrelation = cid is string ? cid : "";
        }
        string to = check body.toAddress;
        http:Response res = new;
        match to {
            "0xbroke" => {
                return answer(400, {message: "Insufficient funds."});
            }
            "0xnobody" => {
                return answer(400, {message: "Recipient wallet not found."});
            }
            "0xself" => {
                return answer(400, {message: "Cannot transfer to the same wallet."});
            }
            "0xcrash" => {
                return answer(500, {message: "An internal server error occurred. Please try again later."});
            }
            "0xgateway" => {
                return answer(503, {message: "unavailable"});
            }
            "0xdenied" => {
                return answer(403, {message: "Access to the requested resource is forbidden."});
            }
            "0xslow-down" => {
                return answer(429, {message: "slow down"});
            }
            "0xgarbled" => {
                res.statusCode = 201;
                res.setTextPayload("not json");
                return res;
            }
            "0xslow" => {
                runtime:sleep(3);
            }
        }
        string amount = check body.amount;
        return answer(201, {reference: "tx-" + to, fromAddress: MASTER, toAddress: to, amount});
    }

    resource function get wallets/me(http:Request req) returns http:Response|error {
        check expectServiceToken(req);
        string|http:HeaderNotFoundError user = req.getHeader("X-User-Assertion");
        lock {
            lastUserAssertion = user is string ? user : "";
        }
        if user is http:HeaderNotFoundError || user == "bad" {
            return answer(401, {message: "You are not authorized to perform this action."});
        }
        if user == "no-wallets" {
            return answer(200, []);
        }
        if user == "garbled" {
            return answer(200, {walletAddress: "0x1"});
        }
        return answer(200, [
            {walletAddress: "0xsecond", balance: "1.5", defaultWallet: false},
            {walletAddress: "0xdefault", balance: "20", defaultWallet: true}
        ]);
    }

    resource function get wallets/master/balance(http:Request req) returns http:Response|error {
        check expectServiceToken(req);
        return answer(200, {walletAddress: MASTER, balance: "12500.000000000"});
    }

    resource function get transactions/[string reference](http:Request req) returns http:Response|error {
        check expectServiceToken(req);
        if reference == "tx-missing" {
            return answer(404, {message: "The requested resource was not found."});
        }
        return answer(200, {reference, fromAddress: MASTER, toAddress: "0xa", amount: "10",
            timestamp: "2026-12-01T02:00:01Z"});
    }

    resource function post transactions/search(http:Request req) returns http:Response|error {
        check expectServiceToken(req);
        json body = check req.getJsonPayload();
        lock {
            lastBody = body.cloneReadOnly();
        }
        return answer(200, {
            transactions: [{reference: "tx-a", fromAddress: MASTER, toAddress: "0xa", amount: "10.000000000",
                timestamp: "2026-12-01T02:00:01Z"}],
            total: 1, 'limit: 100, offset: 0, next: (), previous: ()
        });
    }
}

function expectServiceToken(http:Request req) returns error? {
    if req.getHeader("Authorization") != "Bearer " + SERVICE_TOKEN {
        return error("missing service token");
    }
}

function answer(int status, json body) returns http:Response {
    http:Response res = new;
    res.statusCode = status;
    res.setJsonPayload(body);
    return res;
}

function coinsClient(string baseUrl = STUB, string tokenUrl = STUB + "/oauth2/token", decimal timeoutSeconds = 2)
        returns CoinsClient|error =>
    new ({baseUrl, tokenUrl, clientId: "amplify-client", clientSecret: "amplify-secret", timeoutSeconds});

function code(any|error result) returns string {
    if result is CoinsError {
        return result.detail().code;
    }
    return "no error";
}

function delivered(any|error result) returns string {
    if result is CoinsError {
        return result.detail().delivered;
    }
    return "no error";
}

@test:Config
function testTransferSendsTheAmountAsADecimalStringWithTheServiceToken() returns error? {
    CoinsClient c = check coinsClient();
    Transfer t = check c.transfer("0xalice", 30, "corr-1");
    test:assertEquals(t, {reference: "tx-0xalice", fromAddress: MASTER, toAddress: "0xalice", amount: "30"});
    lock {
        test:assertEquals(lastBody, {toAddress: "0xalice", amount: "30"});
    }
    lock {
        test:assertEquals(lastCorrelation, "corr-1");
    }
    test:assertEquals(c.breaker(), "CLOSED");
}

@test:Config
function testTheTokenIsFetchedOnceAndKept() returns error? {
    CoinsClient c = check coinsClient();
    int before;
    lock {
        before = tokenCalls;
    }
    _ = check c.masterBalance();
    _ = check c.masterBalance();
    _ = check c.transfer("0xbob", 10);
    int after;
    lock {
        after = tokenCalls;
    }
    test:assertEquals(after - before, 1, "one token for the client's calls, fetched lazily on the first");
}

@test:Config
function testRefusalsMovedNothing() returns error? {
    CoinsClient c = check coinsClient();
    [string, string][] cases = [["0xbroke", INSUFFICIENT_FUNDS], ["0xnobody", RECIPIENT_NOT_FOUND],
        ["0xself", REJECTED], ["0xdenied", UNAUTHORIZED], ["0xslow-down", RATE_LIMITED]];
    foreach [string, string] [to, expected] in cases {
        Transfer|CoinsError r = c.transfer(to, 10);
        test:assertEquals(code(r), expected, to);
        test:assertEquals(delivered(r), "NO", to);
    }
    test:assertEquals(code(c.transfer("0xalice", 0)), REJECTED, "a positive amount only");
    test:assertEquals(code(c.transfer(" ", 10)), REJECTED, "a wallet is required");
}

@test:Config
function testNoClearAnswerMayHaveMovedCoins() returns error? {
    CoinsClient c = check coinsClient();
    foreach string to in ["0xcrash", "0xgateway", "0xgarbled"] {
        Transfer|CoinsError r = c.transfer(to, 10);
        test:assertEquals(delivered(r), "UNKNOWN", to);
    }
    test:assertEquals(code(c.transfer("0xcrash", 10)), OUTCOME_UNKNOWN);
    test:assertEquals(code(c.transfer("0xgarbled", 10)), BAD_RESPONSE, "a 201 recorded the transfer");
    CoinsClient impatient = check coinsClient(timeoutSeconds = 1);
    Transfer|CoinsError slow = impatient.transfer("0xslow", 10);
    test:assertEquals(code(slow), OUTCOME_UNKNOWN, "a timeout after sending");
    test:assertEquals(delivered(slow), "UNKNOWN");
}

@test:Config
function testNothingSentWhenTheServiceOrTheTokenEndpointIsUnreachable() returns error? {
    CoinsClient noToken = check coinsClient(tokenUrl = string `http://localhost:${CLOSED_PORT}/oauth2/token`);
    Transfer|CoinsError r = noToken.transfer("0xalice", 10);
    test:assertEquals(code(r), UNAVAILABLE);
    test:assertEquals(delivered(r), "NO");
    test:assertEquals(noToken.breaker(), "CLOSED", "no client was built");
    // Tried again on the next call (the build is not cached when it fails).
    test:assertEquals(code(noToken.masterBalance()), UNAVAILABLE);

    CoinsClient down = check coinsClient(baseUrl = string `http://localhost:${CLOSED_PORT}`);
    Transfer|CoinsError refused = down.transfer("0xalice", 10);
    test:assertEquals(code(refused), UNAVAILABLE, "a refused connection sent nothing");
    test:assertEquals(delivered(refused), "NO");
}

@test:Config
function testWalletsForwardTheUserTokenDefaultFirst() returns error? {
    CoinsClient c = check coinsClient();
    Wallet[] wallets = check c.walletsOf("user-jwt", "corr-2");
    lock {
        test:assertEquals(lastUserAssertion, "user-jwt");
    }
    test:assertEquals(wallets, [
        {address: "0xdefault", balance: "20", isDefault: true},
        {address: "0xsecond", balance: "1.5", isDefault: false}
    ]);
    test:assertEquals(check c.walletsOf("no-wallets"), []);
    test:assertEquals(code(c.walletsOf("bad")), UNAUTHORIZED);
    test:assertEquals(code(c.walletsOf("")), UNAUTHORIZED, "never called without a user token");
    test:assertEquals(code(c.walletsOf("garbled")), BAD_RESPONSE);
}

@test:Config
function testMasterBalanceTransactionAndSearch() returns error? {
    CoinsClient c = check coinsClient();
    test:assertEquals(check c.masterBalance(), {walletAddress: MASTER, balance: "12500.000000000"});
    Transaction? t = check c.transactionByReference("tx-a");
    test:assertEquals(t, {reference: "tx-a", fromAddress: MASTER, toAddress: "0xa", amount: "10",
        timestamp: "2026-12-01T02:00:01Z"});
    test:assertEquals(check c.transactionByReference("tx-missing"), ());
    test:assertEquals(code(c.transactionByReference(" ")), REJECTED);

    TransactionPage page = check c.searchTransfers({fromAddresses: [MASTER], toAddresses: ["0xa"],
        dateFrom: "2026-12-01T01:58:00Z", 'limit: 50});
    test:assertEquals(page.total, 1);
    test:assertEquals(page.transactions[0].reference, "tx-a");
    lock {
        test:assertEquals(lastBody, {'limit: 50, offset: 0, fromAddresses: [MASTER], toAddresses: ["0xa"],
            dateFrom: "2026-12-01T01:58:00Z"}, "only the fields that are set");
    }
}

@test:Config
function testSettingsAreCheckedWithoutCallingAnything() {
    test:assertTrue((new CoinsClient({baseUrl: "", tokenUrl: STUB, clientId: "a", clientSecret: "b"})) is error);
    test:assertTrue((new CoinsClient({baseUrl: "http://coins.example.com", tokenUrl: STUB, clientId: "a",
        clientSecret: "b"})) is error, "plain http only to localhost");
    test:assertTrue((new CoinsClient({baseUrl: "https://coins.example.com", tokenUrl: "ftp://x", clientId: "a",
        clientSecret: "b"})) is error);
    test:assertTrue((new CoinsClient({baseUrl: "https://coins.example.com", tokenUrl: STUB, clientId: "",
        clientSecret: "b"})) is error);
    test:assertTrue((new CoinsClient({baseUrl: "https://coins.example.com", tokenUrl: STUB, clientId: "a",
        clientSecret: "b", timeoutSeconds: 0})) is error);
    test:assertTrue((new CoinsClient({baseUrl: "https://coins.example.com/", tokenUrl: STUB, clientId: "a",
        clientSecret: "b"})) is CoinsClient);
}

@test:Config
function testFailedBeforeSendingReadsTheCauseChain() {
    test:assertTrue(failedBeforeSending(error("outer", error("Connection refused: localhost"))));
    test:assertFalse(failedBeforeSending(error("Idle timeout triggered")));
}
