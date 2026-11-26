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

// `POST /coins/convert` (phase 2, ADR-048): the automatic Coins conversion. Off unless `coin.wallets_enabled` is true
// (answers 202 SKIPPED `WALLETS_OFF`; points keep counting). The rules, the three steps per employee and the reconcile
// of unknown outcomes live in amplify_domain.scoring (`convertCoins`); this file wires the WSO2 Coins transaction
// service and the database to it. Never logs tokens or wallet addresses.

import amplify_common.coins;
import amplify_common.resilience;
import amplify_domain.scoring;
import amplify_domain.store;

import ballerina/log;
import ballerina/time;
import ballerinax/postgresql;

# Base URL of the WSO2 Coins transaction service (its Choreo gateway URL, https). Empty = not configured: the
# conversion answers 202 SKIPPED `COINS_NOT_CONFIGURED`.
configurable string coinsBaseUrl = "";
# Token endpoint of the client-credentials grant (an application subscribed to the Coins API).
configurable string coinsTokenUrl = "";
# Client id of that application; the Coins service maps it to Amplify's master wallet.
configurable string coinsClientId = "";
# Client secret of that application (Choreo secret; never logged).
configurable string coinsClientSecret = "";
# Comma-separated scopes for the token; empty = none.
configurable string coinsScopes = "";
# Seconds before a Coins call (token or API) gives up.
configurable decimal coinsTimeoutSeconds = 10;
# Coins breaker and pool. Keep `retryCount` 0: a transfer is not idempotent (the conversion reconciles instead).
configurable resilience:HttpResilience coinsResilience = {};
# Stop sending after this many seconds (`PARTIAL`; a re-run of the period carries on). Below the scheduler's
# `coinsDeadlineSeconds` (amplify-api, 600).
configurable decimal coinsMaxSeconds = 540;
# An open (PENDING/UNKNOWN) issue is reconciled only once its attempt is this old, seconds.
configurable decimal coinsReconcileAfterSeconds = 600;

final coins:CoinsClient? coinsClient = check newCoinsClient();

# Returned when the conversion did not run: another holds the lock (`CONVERSION_IN_PROGRESS`), wallets are off
# (`WALLETS_OFF`), or the Coins service is not configured (`COINS_NOT_CONFIGURED`).
type CoinsSkipped record {|
    # `SKIPPED`
    string status = "SKIPPED";
    # Why
    string reason;
|};

# What the conversion needs from the database (a port, so the tests run on fakes).
type CoinConversionStore isolated object {
    isolated function settings() returns scoring:CoinSettings|error;
    isolated function repository() returns scoring:CoinRepository;
};

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
        scopes: splitScopes(coinsScopes),
        timeoutSeconds: coinsTimeoutSeconds,
        resilience: coinsResilience
    });
}

# Test seam: the Coins port.
#
# + return - The client, or `()` when not configured
isolated function coinsPort() returns coins:CoinsPort? => coinsClient;

isolated function splitScopes(string raw) returns string[] =>
    from string scope in re `,`.split(raw)
    let string trimmed = scope.trim()
    where trimmed != ""
    select trimmed;

# One conversion run.
#
# + st - Database side
# + port - Coins service, `()` when not configured
# + correlationId - Trigger correlation id, sent to the Coins service
# + now - Run time
# + return - The run report, a skip, or a database error
isolated function runCoinConversion(CoinConversionStore st, coins:CoinsPort? port, string? correlationId,
        time:Utc now) returns scoring:CoinRunReport|CoinsSkipped|error {
    scoring:CoinSettings settings = check st.settings();
    if !settings.walletsEnabled {
        return <CoinsSkipped>{reason: scoring:RUN_WALLETS_OFF};
    }
    if port is () {
        return <CoinsSkipped>{reason: "COINS_NOT_CONFIGURED"};
    }
    return scoring:convertCoins(st.repository(), port, settings,
            {maxSeconds: coinsMaxSeconds, reconcileAfterSeconds: coinsReconcileAfterSeconds, correlationId}, now);
}

# The conversion settings from rows; missing or malformed values keep the defaults (off, 100 = 10, caps 500 / 50000,
# verified within 48 hours).
#
# + rows - Setting rows
# + return - Settings
isolated function toCoinSettings(store:Setting[] rows) returns scoring:CoinSettings {
    scoring:CoinSettings s = {};
    foreach store:Setting row in rows {
        json v = row.value;
        match row.key {
            "coin.wallets_enabled" => {
                s.walletsEnabled = v == true;
            }
            "coin.block_points" => {
                s.blockPoints = v is int && v > 0 ? v : s.blockPoints;
            }
            "coin.block_coins" => {
                s.blockCoins = v is int && v > 0 ? v : s.blockCoins;
            }
            "coin.max_coins_per_person" => {
                s.maxCoinsPerPerson = v is int && v > 0 ? v : s.maxCoinsPerPerson;
            }
            "coin.max_coins_per_run" => {
                s.maxCoinsPerRun = v is int && v > 0 ? v : s.maxCoinsPerRun;
            }
            "coin.schedule" => {
                s.schedule = v == "WEEKLY" ? "WEEKLY" : v == "DAILY" ? "DAILY" : "MONTHLY";
            }
            "coin.verify_max_age_hours" => {
                s.verifyMaxAgeHours = v is int && v > 0 ? v : s.verifyMaxAgeHours;
            }
        }
    }
    return s;
}

# Logs a finished conversion: counts only.
#
# + result - The result
# + correlationId - Trigger correlation id
isolated function logCoinConversion(scoring:CoinRunReport|CoinsSkipped result, string? correlationId) {
    if result is CoinsSkipped {
        log:printInfo("Coins conversion skipped", skipReason = result.reason, correlationId = correlationId);
        return;
    }
    log:printInfo("Coins conversion", status = result.status, stopReason = result.stopReason, period = result.period,
            sent = result.sent, coinsSent = result.coinsSent, failed = result.failed, unknown = result.unknown,
            skippedNoWallet = result.skippedNoWallet, passedOver = result.passedOver,
            reconciledSent = result.reconciledSent, reconciledNotSent = result.reconciledNotSent,
            stillOpen = result.stillOpen, correlationId = correlationId);
}

# Breaker state of the Coins client, for `/ready` and the gauge.
#
# + return - The state, or `NOT_CONFIGURED`
isolated function coinsBreaker() returns string {
    coins:CoinsClient? c = coinsClient;
    return c is () ? "NOT_CONFIGURED" : c.breaker();
}

// ---- PostgreSQL -----------------------------------------------------------------------------------

# `CoinConversionStore` over the conversion's own single-connection client.
isolated class PgCoinConversionStore {
    *CoinConversionStore;

    private final postgresql:Client db;

    isolated function init(postgresql:Client db) {
        self.db = db;
    }

    isolated function settings() returns scoring:CoinSettings|error => toCoinSettings(check store:readSettings(self.db));

    isolated function repository() returns scoring:CoinRepository => new scoring:PgCoinRepository(self.db);
}
