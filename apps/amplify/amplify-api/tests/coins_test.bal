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

// Wallet capture (`POST /me/coins/wallet`, ADR-048) over HTTP on fakes: the caller's own JWT goes to the Coins service,
// the default wallet is stored and answered masked, no wallet is 404 `NO_WALLET`, an unconfigured or failing Coins
// service is 503 `COINS_UNAVAILABLE`; and the wallet shows in `GET /me/points`.

import amplify_api.auth;
import amplify_common.coins;
import amplify_common.resilience;
import amplify_common.types;
import amplify_domain.scoring;
import amplify_domain.store;

import ballerina/http;
import ballerina/test;
import ballerina/time;

// The Coins service as the wallet capture sees it. `walletsMode`: "default", "none", "down".
isolated class WalletCoins {
    *coins:CoinsPort;

    private string mode = "default";
    private string lastAssertion = "";

    isolated function setMode(string m) {
        lock {
            self.mode = m;
        }
    }

    isolated function assertion() returns string {
        lock {
            return self.lastAssertion;
        }
    }

    public isolated function transfer(string toAddress, int amount, string? correlationId = ())
            returns coins:Transfer|coins:CoinsError => coins:coinsError(coins:REJECTED, "not here");

    public isolated function walletsOf(string userAssertion, string? correlationId = ())
            returns coins:Wallet[]|coins:CoinsError {
        lock {
            self.lastAssertion = userAssertion;
            if self.mode == "none" {
                return [];
            }
            if self.mode == "down" {
                return coins:coinsError(coins:OUTCOME_UNKNOWN, "scripted", 502, "UNKNOWN");
            }
            return [{address: "0xfirst000000aaaa", balance: "0", isDefault: false},
                {address: "0x12ab34cd56ef9f3c", balance: "5", isDefault: true}];
        }
    }

    public isolated function masterBalance(string? correlationId = ()) returns coins:MasterBalance|coins:CoinsError =>
        coins:coinsError(coins:REJECTED, "not here");

    public isolated function transactionByReference(string reference, string? correlationId = ())
            returns coins:Transaction|coins:CoinsError? => ();

    public isolated function searchTransfers(coins:SearchFilter filter, string? correlationId = ())
            returns coins:TransactionPage|coins:CoinsError => {transactions: [], total: 0};

    public isolated function breaker() returns resilience:BreakerState => "CLOSED";
}

final WalletCoins walletCoins = new;
isolated boolean coinsConfigured = true;

function setCoinsConfigured(boolean v) {
    lock {
        coinsConfigured = v;
    }
}

isolated map<scoring:CoinWallet> storedWallets = {};

isolated class MemWallets {
    *scoring:CoinWalletRepository;

    public isolated function walletOf(types:EmployeeId employeeId) returns scoring:CoinWallet|error? {
        lock {
            return storedWallets[employeeId].clone();
        }
    }

    public isolated function saveWallet(types:EmployeeId employeeId, string walletAddress, time:Utc now)
            returns scoring:CoinWallet|error {
        scoring:CoinWallet w = {employeeId, walletAddress, capturedAt: [1796090400, 0]};
        lock {
            storedWallets[employeeId] = w.clone();
        }
        return w;
    }
}

@test:Mock {functionName: "coinsPort"}
isolated function mockCoinsPort() returns coins:CoinsPort? {
    lock {
        if !coinsConfigured {
            return ();
        }
    }
    return walletCoins;
}

@test:Mock {functionName: "coinWalletRepository"}
isolated function mockCoinWalletRepository(store:Actor actor) returns scoring:CoinWalletRepository|error {
    check dbGate();
    return new MemWallets();
}

@test:Mock {functionName: "coinSummary"}
isolated function mockCoinSummary(types:EmployeeId employeeId) returns scoring:CoinSummary|error {
    check dbGate();
    scoring:CoinWallet? w;
    lock {
        w = storedWallets[employeeId].clone();
    }
    return {coinsReceived: w is () ? 0 : 20, carryPoints: 0, walletAddress: w is () ? () : w.walletAddress,
        walletCapturedAt: w is () ? () : w.capturedAt};
}

@test:Config {groups: ["coins"]}
function testCaptureStoresTheDefaultWalletAndAnswersItMasked() returns error? {
    setCoinsConfigured(true);
    walletCoins.setMode("default");
    string token = check employee("wallet-owner");
    http:Response res = check send("POST", "/me/coins/wallet", (), token);
    test:assertEquals(res.statusCode, 200);
    check assertShape(res, "CoinWallet");
    json body = check res.getJsonPayload();
    test:assertEquals(body, {walletAddress: "0x12ab…9f3c", capturedAt: "2026-12-01T02:00:00Z"});
    test:assertEquals(walletCoins.assertion(), token, "the caller's own backend JWT goes to the Coins service");
    lock {
        test:assertEquals(storedWallets["wallet-owner"]?.walletAddress, "0x12ab34cd56ef9f3c", "stored unmasked");
    }

    http:Response points = check send("GET", "/me/points", (), token);
    test:assertEquals(points.statusCode, 200);
    check assertShape(points, "MyPoints");
    json coinsBlock = check (check points.getJsonPayload()).coins;
    test:assertEquals(check coinsBlock.wallet, {walletAddress: "0x12ab…9f3c", capturedAt: "2026-12-01T02:00:00Z"});
    test:assertEquals(check coinsBlock.coinsReceived, 20);
}

@test:Config {groups: ["coins"]}
function testNoWalletAtTheCoinsServiceIs404() returns error? {
    setCoinsConfigured(true);
    walletCoins.setMode("none");
    http:Response res = check send("POST", "/me/coins/wallet", (), check employee("walletless"));
    test:assertEquals(res.statusCode, 404);
    test:assertEquals(check codeIn(res), NO_WALLET);
    lock {
        test:assertFalse(storedWallets.hasKey("walletless"));
    }
}

@test:Config {groups: ["coins"]}
function testAnUnconfiguredOrFailingCoinsServiceIs503() returns error? {
    walletCoins.setMode("down");
    setCoinsConfigured(true);
    http:Response down = check send("POST", "/me/coins/wallet", (), check employee("coins-down"));
    test:assertEquals(down.statusCode, 503);
    test:assertEquals(check codeIn(down), COINS_UNAVAILABLE);
    setCoinsConfigured(false);
    http:Response off = check send("POST", "/me/coins/wallet", (), check employee("coins-off"));
    test:assertEquals(off.statusCode, 503);
    test:assertEquals(check codeIn(off), COINS_UNAVAILABLE);
    test:assertEquals(coinsBreaker(), "NOT_CONFIGURED");
    setCoinsConfigured(true);
    test:assertEquals(coinsBreaker(), "CLOSED");
    walletCoins.setMode("default");
}

@test:Config {groups: ["coins"]}
function testCaptureWithoutAnAssertionNeverCallsTheService() {
    auth:Principal p = {employeeId: "e-no-jwt", email: "e@wso2.com", displayName: "E", roles: [], grants: [auth:EMPLOYEE],
        issuer: "test"};
    http:StatusCodeResponse res = captureCoinsWallet(p, (), "c-1");
    test:assertEquals(statusOf(res), 503);
}

@test:Config {groups: ["coins"]}
function testCoinCapsAreAdminSettings() {
    test:assertEquals(checkSettingChange("coin.max_coins_per_person", 0), [INVALID_SETTING,
        "coin.max_coins_per_person must be a whole number from 1 to 1000000"]);
    test:assertEquals(checkSettingChange("coin.max_coins_per_run", 50000), ());
    test:assertTrue(isVisibleSetting("coin.max_coins_per_person"));
    test:assertTrue(isVisibleSetting("coin.max_coins_per_run"));
    test:assertTrue(PO_SETTINGS.indexOf("coin.max_coins_per_run") is (), "caps stay with admins");
    Settings s = settingsOf([
        {key: "coin.max_coins_per_person", value: 200, updatedBy: "a", updatedAt: [0, 0], version: 1},
        {key: "coin.max_coins_per_run", value: -1, updatedBy: "a", updatedAt: [0, 0], version: 1}
    ]);
    test:assertEquals([s.coinMaxPerPerson, s.coinMaxPerRun], [200, 50000]);
    test:assertTrue(touchesSchedule(["coin.schedule"]));
    test:assertTrue(touchesSchedule(["coin.wallets_enabled"]));
}
