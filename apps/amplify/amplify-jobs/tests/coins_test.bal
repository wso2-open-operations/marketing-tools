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

// `POST /coins/convert` wiring on fakes (ADR-048): the settings, the switch, the unconfigured service, one employee
// paid end to end through the domain's conversion, and the scheduler key's access to the route. The conversion rules
// themselves are covered in amplify_domain.scoring (coins_test.bal) and against PostgreSQL there.

import amplify_common.coins;
import amplify_common.resilience;
import amplify_domain.scoring;
import amplify_domain.store;

import ballerina/http;
import ballerina/test;
import ballerina/time;

final time:Utc COINS_T0 = [1796090400, 0];

// One employee with 230 HELD points and a wallet; records what the conversion wrote.
isolated class OneEmployeeRepo {
    *scoring:CoinRepository;

    private string[] writes = [];

    isolated function log() returns string[] {
        lock {
            return self.writes.clone();
        }
    }

    isolated function note(string w) {
        lock {
            self.writes.push(w);
        }
    }

    public isolated function openRun(string period, time:Utc now) returns scoring:CoinRun|error {
        self.note("open " + period);
        return {id: "run-1", period};
    }

    public isolated function openIssues() returns scoring:CoinIssue[]|error => [];

    public isolated function issuesOf(string runId) returns map<scoring:CoinIssue>|error => {};

    public isolated function candidates() returns scoring:CoinCandidate[]|error =>
        [{employeeId: "e1", carryIn: 0, rows: [{reference: "ADJ-1", points: 150}, {reference: "ADJ-2", points: 80}],
            walletAddress: "0xe1"}];

    public isolated function committedCoins(string runId) returns int|error => 0;

    public isolated function transferTaken(string transferReference) returns boolean|error => false;

    public isolated function begin(scoring:CoinPlan plan, string runId, time:Utc now) returns scoring:CoinIssue|error {
        self.note(string `begin ${plan.employeeId} ${plan.coins} ${plan.carryOut}`);
        return {id: "i1", runId, employeeId: plan.employeeId, pointsIn: plan.pointsIn, carryIn: plan.carryIn,
            coins: plan.coins, carryOut: plan.carryOut, walletAddress: plan.walletAddress, reference: "CNV-1",
            transferReference: (), status: scoring:COIN_PENDING, attempts: 1, lastErrorCode: (), nextAttemptAt: (),
            attemptedAt: now};
    }

    public isolated function skipNoWallet(scoring:CoinPlan plan, string runId, time:Utc now) returns error? {
        self.note("skip " + plan.employeeId);
    }

    public isolated function markSent(scoring:CoinIssue issue, string transferReference, time:Utc now) returns error? {
        self.note("sent " + transferReference);
    }

    public isolated function markFailed(scoring:CoinIssue issue, string errorCode, time:Utc nextAttemptAt, time:Utc now)
            returns error? {
        self.note("failed " + errorCode);
    }

    public isolated function markUnknown(scoring:CoinIssue issue, string errorCode, time:Utc now) returns error? {
        self.note("unknown " + errorCode);
    }

    public isolated function finishRun(string runId, string status, string? stopReason, time:Utc now)
            returns scoring:CoinRunTotals|error {
        self.note("finish " + status);
        return {issuesSent: 1, coinsSent: 20};
    }
}

isolated class FakeCoinStore {
    *CoinConversionStore;

    private final scoring:CoinSettings & readonly s;
    private final OneEmployeeRepo repo;

    isolated function init(scoring:CoinSettings s, OneEmployeeRepo repo) {
        self.s = s.cloneReadOnly();
        self.repo = repo;
    }

    isolated function settings() returns scoring:CoinSettings|error => self.s;

    isolated function repository() returns scoring:CoinRepository => self.repo;
}

isolated class FakeCoinsService {
    *coins:CoinsPort;

    private string[] calls = [];

    isolated function log() returns string[] {
        lock {
            return self.calls.clone();
        }
    }

    public isolated function transfer(string toAddress, int amount, string? correlationId = ())
            returns coins:Transfer|coins:CoinsError {
        lock {
            self.calls.push(string `transfer ${toAddress} ${amount} ${correlationId ?: ""}`);
        }
        return {reference: "tx-1", fromAddress: "0xmaster", toAddress, amount: amount.toString()};
    }

    public isolated function walletsOf(string userAssertion, string? correlationId = ())
            returns coins:Wallet[]|coins:CoinsError => [];

    public isolated function masterBalance(string? correlationId = ()) returns coins:MasterBalance|coins:CoinsError =>
        {walletAddress: "0xmaster", balance: "1000"};

    public isolated function transactionByReference(string reference, string? correlationId = ())
            returns coins:Transaction|coins:CoinsError? => ();

    public isolated function searchTransfers(coins:SearchFilter filter, string? correlationId = ())
            returns coins:TransactionPage|coins:CoinsError => {transactions: [], total: 0};

    public isolated function breaker() returns resilience:BreakerState => "CLOSED";
}

@test:Config
function testCoinSettingsFromRowsKeepDefaultsForBadValues() {
    scoring:CoinSettings s = toCoinSettings([
        {key: "coin.wallets_enabled", value: true, updatedBy: "system", updatedAt: COINS_T0, version: 1},
        {key: "coin.block_points", value: 50, updatedBy: "system", updatedAt: COINS_T0, version: 1},
        {key: "coin.block_coins", value: 0, updatedBy: "system", updatedAt: COINS_T0, version: 1},
        {key: "coin.max_coins_per_person", value: 200, updatedBy: "system", updatedAt: COINS_T0, version: 1},
        {key: "coin.max_coins_per_run", value: "lots", updatedBy: "system", updatedAt: COINS_T0, version: 1},
        {key: "coin.schedule", value: "WEEKLY", updatedBy: "system", updatedAt: COINS_T0, version: 1},
        {key: "other.key", value: 1, updatedBy: "system", updatedAt: COINS_T0, version: 1}
    ]);
    test:assertEquals(s, {walletsEnabled: true, blockPoints: 50, blockCoins: 10, maxCoinsPerPerson: 200,
        maxCoinsPerRun: 50000, schedule: "WEEKLY"});
    scoring:CoinSettings defaults = {};
    test:assertEquals(toCoinSettings([]), defaults, "off by default");
    test:assertEquals(toCoinSettings([{key: "coin.wallets_enabled", value: "true", updatedBy: "system", updatedAt: COINS_T0, version: 1},
        {key: "coin.schedule", value: "HOURLY", updatedBy: "system", updatedAt: COINS_T0, version: 1}]), defaults,
            "only a JSON true turns it on");
    test:assertEquals(toCoinSettings([{key: "coin.schedule", value: "DAILY", updatedBy: "system", updatedAt: COINS_T0, version: 1}]).schedule, "DAILY");
}

@test:Config
function testWalletsOffAndNoServiceSkipTheRun() returns error? {
    OneEmployeeRepo repo = new;
    scoring:CoinRunReport|CoinsSkipped off = check runCoinConversion(new FakeCoinStore({}, repo), new FakeCoinsService(),
            (), COINS_T0);
    test:assertEquals(off, <CoinsSkipped>{reason: "WALLETS_OFF"});
    scoring:CoinRunReport|CoinsSkipped unconfigured = check runCoinConversion(
            new FakeCoinStore({walletsEnabled: true}, repo), (), (), COINS_T0);
    test:assertEquals(unconfigured, <CoinsSkipped>{reason: "COINS_NOT_CONFIGURED"});
    test:assertEquals(repo.log(), [], "nothing opened or written");
}

@test:Config
function testOneEmployeeIsPaidThroughTheDomainConversion() returns error? {
    OneEmployeeRepo repo = new;
    FakeCoinsService svc = new;
    scoring:CoinRunReport|CoinsSkipped result = check runCoinConversion(new FakeCoinStore({walletsEnabled: true}, repo),
            svc, "corr-coins", COINS_T0);
    if result is CoinsSkipped {
        test:assertFail("expected a run");
    }
    test:assertEquals([result.status, result.period, result.sent, result.coinsSent], ["DONE", "2026-12", 1, 20]);
    test:assertEquals(repo.log(), ["open 2026-12", "begin e1 20 30", "sent tx-1", "finish DONE"]);
    test:assertEquals(svc.log(), ["transfer 0xe1 20 corr-coins"], "the correlation id goes to the Coins service");
    logCoinConversion(result, "corr-coins");
    logCoinConversion(<CoinsSkipped>{reason: "WALLETS_OFF"}, ());
}

@test:Config
function testCoinsClientIsOptionalAndScopesSplit() {
    test:assertEquals(coinsPort(), (), "no Coins URL in the test config");
    test:assertEquals(coinsBreaker(), "NOT_CONFIGURED");
    test:assertEquals(breakerStates()["coins"], "NOT_CONFIGURED");
    test:assertEquals(splitScopes(" a, ,b "), ["a", "b"]);
    test:assertEquals(splitScopes(""), []);
    coins:CoinsClient?|error none = newCoinsClient();
    test:assertTrue(none is (), "not configured");
}

@test:Config
function testTheSchedulerKeyMayConvertCoins() returns error? {
    test:assertTrue(schedulerMayCall("POST", ["coins", "convert"]));
    test:assertFalse(schedulerMayCall("GET", ["coins", "convert"]));
    test:assertFalse(schedulerMayCall("POST", ["coins"]));
    foreach map<string> keys in [KEYED, SCHEDULER_KEYED] {
        http:Response res = check testClient->post("/coins/convert", (), keys);
        test:assertEquals(res.statusCode, http:STATUS_SERVICE_UNAVAILABLE, "no database in the unit tests");
    }
    http:Response none = check testClient->post("/coins/convert", ());
    test:assertEquals(none.statusCode, http:STATUS_UNAUTHORIZED);
}

@test:Config
function testTheSettingRowShapeIsTheStoreOne() {
    store:Setting row = {key: "coin.wallets_enabled", value: true, updatedBy: "system", updatedAt: COINS_T0, version: 3};
    test:assertTrue(toCoinSettings([row]).walletsEnabled);
}
