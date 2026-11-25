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

// Native repost intent (`sharing_native_intent`): an employee opened a campaign post to reshare it on LinkedIn
// itself. The engagement sync marks it detected when it sees the reshare; until then the screen says it is looking,
// and after a day that it didn't find one.

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# How long the screen says "looking" before "not found", seconds (24 hours).
public const int NATIVE_LOOK_SECONDS = 86400;

# What the screen shows for a native repost.
public enum NativeStatus {
    # Opened less than a day ago, not seen yet
    LOOKING,
    # The sync saw the reshare
    DETECTED,
    # A day or more and not seen
    NOT_FOUND
}

# One employee's native repost intent for a campaign.
public type NativeIntent record {|
    # Employee
    types:EmployeeId employeeId;
    # Campaign
    string campaignId;
    # Latest click before detection
    time:Utc openedAt;
    # When the sync saw the reshare
    time:Utc? detectedAt;
|};

# Persistence port for `sharing_native_intent`.
public type NativeIntentRepository isolated object {
    # Records a click. A later click restarts the look unless the reshare was already seen.
    #
    # + employeeId - Employee
    # + campaignId - Campaign
    # + now - Click time
    # + return - The intent after the click, or an error
    public isolated function open(types:EmployeeId employeeId, string campaignId, time:Utc now) returns NativeIntent|error;

    # The employee's intents, newest first.
    #
    # + employeeId - Employee
    # + return - Intents, or an error
    public isolated function ofEmployee(types:EmployeeId employeeId) returns NativeIntent[]|error;
};

# Status of an intent.
#
# + intent - Intent
# + now - Current time
# + return - `DETECTED`, `LOOKING` (under 24 h) or `NOT_FOUND` (24 h or more)
public isolated function nativeStatus(NativeIntent intent, time:Utc now) returns NativeStatus {
    if intent.detectedAt !is () {
        return DETECTED;
    }
    return time:utcDiffSeconds(now, intent.openedAt) < <decimal>NATIVE_LOOK_SECONDS ? LOOKING : NOT_FOUND;
}

type NativeIntentRow record {|
    string employee_id;
    string campaign_id;
    time:Utc opened_at;
    time:Utc? detected_at;
|};

# `NativeIntentRepository` over PostgreSQL.
public isolated class PgNativeIntentRepository {
    *NativeIntentRepository;

    private final postgresql:Client db;

    # + db - Shared client
    public isolated function init(postgresql:Client db) {
        self.db = db;
    }

    public isolated function open(types:EmployeeId employeeId, string campaignId, time:Utc now) returns NativeIntent|error {
        NativeIntentRow row = check self.db->queryRow(`
            INSERT INTO sharing_native_intent (employee_id, campaign_id, opened_at)
            VALUES (${employeeId}, CAST(${campaignId} AS uuid), CAST(${store:ts(now)} AS timestamptz))
            ON CONFLICT (employee_id, campaign_id) DO UPDATE
                SET opened_at = CASE WHEN sharing_native_intent.detected_at IS NULL THEN EXCLUDED.opened_at
                                     ELSE sharing_native_intent.opened_at END
            RETURNING employee_id, campaign_id::text AS campaign_id, opened_at, detected_at`);
        return toIntent(row);
    }

    public isolated function ofEmployee(types:EmployeeId employeeId) returns NativeIntent[]|error {
        stream<NativeIntentRow, error?> rows = self.db->query(`
            SELECT employee_id, campaign_id::text AS campaign_id, opened_at, detected_at
            FROM sharing_native_intent WHERE employee_id = ${employeeId}
            ORDER BY opened_at DESC LIMIT 200`);
        return from NativeIntentRow r in rows select toIntent(r);
    }
}

isolated function toIntent(NativeIntentRow row) returns NativeIntent =>
    {employeeId: row.employee_id, campaignId: row.campaign_id, openedAt: row.opened_at, detectedAt: row.detected_at};
