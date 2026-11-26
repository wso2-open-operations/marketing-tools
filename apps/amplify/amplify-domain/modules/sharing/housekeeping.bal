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

// Housekeeping of the sharing context's working tables (V029). Each call deletes at most `batchRows` rows in one
// short statement and returns the count; amplify-jobs repeats a call while it deletes a full batch. Engagements are
// business data and are never pruned.

import ballerinax/postgresql;

# Deletes native repost intents detected, or opened and never seen, more than `days` ago (V029).
#
# + db - Client
# + days - `housekeeping.native_intent_days` (2-365)
# + batchRows - Most rows deleted (1-50000)
# + return - Rows deleted, or an error
public isolated function pruneNativeIntents(postgresql:Client db, int days, int batchRows) returns int|error {
    return db->queryRow(`SELECT sharing_prune_native_intent(CAST(${days} AS int), CAST(${batchRows} AS int))`);
}

# Deletes Community Management call counters of UTC days more than `days` ago (V029).
#
# + db - Client
# + days - `housekeeping.api_usage_days` (30-730)
# + batchRows - Most rows deleted (1-50000)
# + return - Rows deleted, or an error
public isolated function pruneApiUsage(postgresql:Client db, int days, int batchRows) returns int|error {
    return db->queryRow(`SELECT sharing_prune_api_usage(CAST(${days} AS int), CAST(${batchRows} AS int))`);
}

# Deletes post cursors (reactions, comments) not moved for `days`; the page's share-notification cursor stays (V029).
#
# + db - Client
# + days - `housekeeping.sync_cursor_days` (30-730)
# + batchRows - Most rows deleted (1-50000)
# + return - Rows deleted, or an error
public isolated function pruneSyncCursors(postgresql:Client db, int days, int batchRows) returns int|error {
    return db->queryRow(`SELECT sharing_prune_sync_cursor(CAST(${days} AS int), CAST(${batchRows} AS int))`);
}
