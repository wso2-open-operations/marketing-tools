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

import amplify_common.crypto;
import amplify_common.resilience;
import amplify_domain.connection;
import amplify_domain.store;

import ballerina/log;

# Body returned by `POST /maintenance/partitions`.
type MaintenanceReport record {|
    *store:MaintenanceResult;
    # Expired `messaging.idempotency_key` rows deleted
    int idempotency_keys_purged;
    # Token key rotation pass (`provider_token` rows moved to the active key)
    TokenRotation token_rotation;
    # Leaver sweep: employees gone from the directory (`OFF` unless `leaverSweepMode` is set)
    LeaverSweepReport leaver_sweep;
|};

# What the key-rotation step of `POST /maintenance/partitions` did.
type TokenRotation record {|
    # `DONE`; `PARTIAL` when the row cap stopped it (the next pass carries on); `NOT_CONFIGURED` without token
    # keys; `FAILED` when the database refused (partition upkeep still counts)
    "DONE"|"PARTIAL"|"NOT_CONFIGURED"|"FAILED" status;
    # Rows re-sealed under the active key
    int resealed;
    # Rows that changed meanwhile (a concurrent re-seal or reconnect)
    int skipped;
    # Rows that didn't open (key missing from the ring, or tampered): left as they are, worth a look
    int failed;
|};

# Body returned by `POST /maintenance/rebuild-recognition`.
type RebuildResult record {|
    # New `recognition.standing_version` for period `ALL`
    int standingVersion;
|};

# Key rotation step (common H4 / jobs H2): moves `provider_token` rows sealed under an older key to the
# active key so an old key can leave the ring before its last partition drops. Never fails the maintenance
# call; never logs token material.
#
# + cipher - Token cipher, `()` when token keys aren't configured
# + tokens - Token rows
# + maxRows - Most rows per pass
# + return - What was done
isolated function rotateTokenKeys(crypto:TokenCipher? cipher, connection:TokenResealStore tokens,
        int maxRows = 10000) returns TokenRotation {
    if cipher is () {
        return {status: "NOT_CONFIGURED", resealed: 0, skipped: 0, failed: 0};
    }
    connection:ResealReport|error report = connection:resealStaleTokens(cipher, tokens, maxRows = maxRows);
    if report is error {
        log:printError("Key rotation pass failed", resilience:loggable(report));
        return {status: "FAILED", resealed: 0, skipped: 0, failed: 0};
    }
    if report.failed > 0 {
        log:printWarn("Key rotation: some token rows don't open with the key ring", rows = report.failed);
    }
    return {status: report.truncated ? "PARTIAL" : "DONE", resealed: report.resealed, skipped: report.skipped,
        failed: report.failed};
}
