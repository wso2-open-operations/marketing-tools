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

// PostgreSQL side of the engagement sync on the sharing tables only: `sharing_sync_cursor`, `sharing_api_usage`,
// `sharing_engagement` (+ its outbox event and audit row) and `sharing_native_intent`.

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

const string ENGAGEMENT_TABLE = "sharing_engagement";

# The engagement sync's writes and the Community Management call counter.
public isolated class PgEngagementSyncRepository {

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Shared client
    # + actor - Who the writes are for (audit); the sync runs as `system`
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    # A cursor.
    #
    # + resourceUrn - Post or page
    # + endpoint - Finder
    # + return - The cursor, `()` before the first run, or an error
    public isolated function cursor(string resourceUrn, SyncEndpoint endpoint) returns string|error? {
        string|error value = self.db->queryRow(`
            SELECT cursor FROM sharing_sync_cursor
            WHERE provider = ${types:LINKEDIN} AND provider_api = ${types:COMMUNITY_MANAGEMENT}
              AND resource_urn = ${resourceUrn} AND endpoint = ${endpoint}`);
        if value is error {
            return store:isNoRows(value) ? () : value;
        }
        return value;
    }

    # Moves a cursor (upsert).
    #
    # + resourceUrn - Post or page
    # + endpoint - Finder
    # + cursor - New value
    # + now - Run time
    # + return - An error on failure
    public isolated function saveCursor(string resourceUrn, SyncEndpoint endpoint, string cursor, time:Utc now)
            returns error? {
        _ = check self.db->execute(`
            INSERT INTO sharing_sync_cursor (provider, provider_api, resource_urn, endpoint, cursor, last_run_at)
            VALUES (${types:LINKEDIN}, ${types:COMMUNITY_MANAGEMENT}, ${resourceUrn}, ${endpoint}, ${cursor},
                    CAST(${store:ts(now)} AS timestamptz))
            ON CONFLICT (provider, provider_api, resource_urn, endpoint)
            DO UPDATE SET cursor = EXCLUDED.cursor, last_run_at = EXCLUDED.last_run_at`);
    }

    # Counts one call against the UTC day's budget, in one statement (two runs can't both take the last call).
    #
    # + now - Current time
    # + budget - Calls allowed per UTC day
    # + return - False when the budget is spent, or an error
    public isolated function takeCall(time:Utc now, int budget) returns boolean|error =>
        takeApiCall(self.db, types:COMMUNITY_MANAGEMENT, now, budget);

    # Records a synced engagement with `EngagementRecorded` and an audit row in one transaction. A reshare is
    # skipped when the employee already has a share of that post (in app or synced earlier), and either way marks
    # the employee's native intent for the campaign detected.
    #
    # + engagement - From `syncedEngagement`
    # + now - Current time
    # + return - True when recorded, false when already covered, or an error
    public isolated function recordSynced(Engagement engagement, time:Utc now) returns boolean|error {
        final readonly & Engagement e = engagement.cloneReadOnly();
        final time:Utc & readonly at = now.cloneReadOnly();
        return (check store:inTransactionValue(() => self.recordSyncedTx(e, at))).ensureType();
    }

    private isolated function recordSyncedTx(Engagement e, time:Utc now) returns boolean|error {
        boolean recorded = false;
        boolean reshare = !(e.action == types:REACTION || e.action == types:COMMENT);
        transaction {
            boolean covered = false;
            if reshare {
                int shares = check self.db->queryRow(`
                    SELECT count(*)::int FROM sharing_engagement
                    WHERE provider = ${e.provider} AND target_resource_urn = ${e.targetResourceUrn}
                      AND employee_id = ${e.employeeId}
                      AND action IN ('REPOST', 'REPOST_COMMENTARY', 'SHARE', 'SHARE_COMMENTARY')`);
                covered = shares > 0;
            }
            if !covered {
                var inserted = check self.db->execute(`
                    INSERT INTO sharing_engagement (id, provider, provider_api, origin, target_resource_urn, campaign_id,
                        actor_member_urn, employee_id, action, activity_urn, occurred_at, observed_at)
                    VALUES (CAST(${e.id} AS uuid), ${e.provider}, ${e.providerApi}, ${e.origin}, ${e.targetResourceUrn},
                        CAST(${e.campaignId} AS uuid), ${e.actorMemberUrn}, ${e.employeeId}, ${e.action}, ${e.activityUrn},
                        CAST(${store:ts(e.occurredAt)} AS timestamptz), CAST(${store:ts(e.observedAt)} AS timestamptz))
                    ON CONFLICT DO NOTHING`);
                recorded = inserted.affectedRowCount == 1;
            }
            if recorded {
                _ = check store:writeOutbox(self.db, [engagementRecordedEvent(e)], self.actor.correlationId);
                check store:writeAudit(self.db, store:auditOf(self.actor, "EngagementSynced", ENGAGEMENT_TABLE, e.id,
                        {campaignId: e.campaignId, action: e.action, origin: e.origin, providerApi: e.providerApi}));
            }
            if reshare {
                _ = check self.db->execute(`
                    UPDATE sharing_native_intent SET detected_at = CAST(${store:ts(now)} AS timestamptz)
                    WHERE employee_id = ${e.employeeId} AND campaign_id = CAST(${e.campaignId} AS uuid)
                      AND detected_at IS NULL`);
            }
            check commit;
        }
        return recorded;
    }
}

# Community Management calls made on a UTC day.
#
# + db - Client
# + day - The day
# + return - Calls, 0 when none, or an error
public isolated function apiCallsOn(postgresql:Client db, time:Utc day) returns int|error {
    string date = time:utcToString(day).substring(0, 10);
    int|error calls = db->queryRow(`
        SELECT calls FROM sharing_api_usage
        WHERE provider_api = ${types:COMMUNITY_MANAGEMENT} AND day = CAST(${date} AS date)`);
    if calls is error {
        return store:isNoRows(calls) ? 0 : calls;
    }
    return calls;
}
