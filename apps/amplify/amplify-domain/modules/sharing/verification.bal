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

// Pre-coin verification, sharing side (V027): which LinkedIn read can still see an engagement, and the record of what
// each check found (`sharing_engagement_verification`, `sharing_engagement.last_verified_at` / `deleted_at`, V004).
// The ledger side is amplify_domain.scoring (verification.bal); amplify-jobs joins the two.

import amplify_common.types;
import amplify_domain.store;

import ballerina/time;
import ballerinax/postgresql;

# Read the employee's own post (an in-app share, or a native reshare the sync found): `GET /rest/posts/{urn}`.
public const TARGET_MEMBER_POST = "MEMBER_POST";
# Read the member's reaction on the page post with the page token.
public const TARGET_REACTION = "REACTION";
# Read the comment with the page token.
public const TARGET_COMMENT = "COMMENT";

# Which read.
public type VerifyTargetKind TARGET_MEMBER_POST|TARGET_REACTION|TARGET_COMMENT;

# The engagement holds no URN to read.
public const NO_ACTIVITY = "NO_ACTIVITY";
# The member was erased (ADR-040); the reaction can't be looked up by member any more.
public const MEMBER_ERASED = "MEMBER_ERASED";

# The member URN erasure leaves on an engagement (V018).
const string ERASED_MEMBER_URN = "urn:li:person:erased";

# What to read for one engagement.
public type VerifyTarget record {|
    # Which read
    VerifyTargetKind kind;
    # The post or comment URN (`MEMBER_POST`, `COMMENT`); the page post (`REACTION`)
    string urn;
    # Who reacted (`REACTION` only)
    string? actorUrn = ();
|};

# An engagement's verification target, or why there is none (`NO_ACTIVITY`, `MEMBER_ERASED`).
#
# + e - Engagement
# + return - The target, or a reason code
public isolated function verifyTarget(Engagement e) returns VerifyTarget|string {
    if e.action == types:REACTION {
        return e.actorMemberUrn == ERASED_MEMBER_URN ? MEMBER_ERASED
            : {kind: TARGET_REACTION, urn: e.targetResourceUrn, actorUrn: e.actorMemberUrn};
    }
    string? activity = e.activityUrn;
    if activity is () || activity.trim() == "" {
        return NO_ACTIVITY;
    }
    return e.action == types:COMMENT ? {kind: TARGET_COMMENT, urn: activity} : {kind: TARGET_MEMBER_POST, urn: activity};
}

type EngagementRow record {|
    string id;
    string provider;
    string provider_api;
    string origin;
    string target_resource_urn;
    string? campaign_id;
    string actor_member_urn;
    string employee_id;
    string action;
    string? activity_urn;
    time:Utc occurred_at;
    time:Utc observed_at;
    time:Utc? last_verified_at;
    time:Utc? deleted_at;
|};

# The verification's reads and writes on the sharing tables.
public isolated class PgEngagementVerificationRepository {

    private final postgresql:Client db;
    private final store:Actor & readonly actor;

    # + db - Client
    # + actor - Who the writes are for (audit); the verification runs as `system`
    public isolated function init(postgresql:Client db, store:Actor actor = store:SYSTEM) {
        self.db = db;
        self.actor = actor.cloneReadOnly();
    }

    # An engagement by id.
    #
    # + id - `sharing_engagement.id`
    # + return - The engagement, `()` when none, or an error
    public isolated function find(string id) returns Engagement|error? {
        EngagementRow|error row = self.db->queryRow(`
            SELECT id::text AS id, provider, provider_api, origin, target_resource_urn, campaign_id::text AS campaign_id,
                   actor_member_urn, employee_id, action, activity_urn, occurred_at, observed_at, last_verified_at,
                   deleted_at
            FROM sharing_engagement WHERE id = CAST(${id} AS uuid)`);
        if row is error {
            return store:isNoRows(row) ? () : row;
        }
        return {
            id: row.id,
            provider: check row.provider.ensureType(),
            providerApi: check row.provider_api.ensureType(),
            origin: check row.origin.ensureType(),
            targetResourceUrn: row.target_resource_urn,
            campaignId: row.campaign_id,
            actorMemberUrn: row.actor_member_urn,
            employeeId: row.employee_id,
            action: check row.action.ensureType(),
            activityUrn: row.activity_urn,
            occurredAt: row.occurred_at,
            observedAt: row.observed_at,
            lastVerifiedAt: row.last_verified_at,
            deletedAt: row.deleted_at
        };
    }

    # Records what one check found, in one transaction: a `sharing_engagement_verification` row, then
    # `last_verified_at` (still there) or `deleted_at` (gone, first time only), and an audit row.
    #
    # + engagementId - Engagement
    # + providerApi - The API read (`SHARE_ON_LINKEDIN` with a member token, `COMMUNITY_MANAGEMENT` with the page's)
    # + stillExists - What LinkedIn said
    # + now - Check time
    # + return - An error on failure
    public isolated function recordCheck(string engagementId, types:ProviderApi providerApi, boolean stillExists,
            time:Utc now) returns error? {
        final readonly & time:Utc at = now.cloneReadOnly();
        return store:inTransaction(isolated function () returns error? =>
            self.recordCheckTx(engagementId, providerApi, stillExists, at));
    }

    private isolated function recordCheckTx(string engagementId, types:ProviderApi providerApi, boolean stillExists,
            time:Utc now) returns error? {
        transaction {
            _ = check self.db->execute(`
                INSERT INTO sharing_engagement_verification (engagement_id, provider_api, checked_at, still_exists)
                VALUES (CAST(${engagementId} AS uuid), ${providerApi}, CAST(${store:ts(now)} AS timestamptz),
                        ${stillExists})`);
            if stillExists {
                _ = check self.db->execute(`
                    UPDATE sharing_engagement SET last_verified_at = CAST(${store:ts(now)} AS timestamptz)
                    WHERE id = CAST(${engagementId} AS uuid)`);
            } else {
                _ = check self.db->execute(`
                    UPDATE sharing_engagement SET deleted_at = CAST(${store:ts(now)} AS timestamptz)
                    WHERE id = CAST(${engagementId} AS uuid) AND deleted_at IS NULL`);
            }
            check store:writeAudit(self.db, store:auditOf(self.actor, stillExists ? "EngagementVerified"
                    : "EngagementGone", ENGAGEMENT_TABLE, engagementId, {providerApi, stillExists}));
            check commit;
        }
    }

    # Counts one call against the UTC day's budget of an API (`sharing_api_usage`), in one statement.
    #
    # + providerApi - `COMMUNITY_MANAGEMENT` (page token) or `SHARE_ON_LINKEDIN` (member tokens, V027)
    # + now - Current time
    # + budget - Calls allowed per UTC day
    # + return - False when the budget is spent, or an error
    public isolated function takeCall(types:ProviderApi providerApi, time:Utc now, int budget) returns boolean|error =>
        takeApiCall(self.db, providerApi, now, budget);
}

# Counts one call against the UTC day's budget of an API, in one statement (two runs can't both take the last call).
#
# + db - Client
# + providerApi - API
# + now - Current time
# + budget - Calls allowed per UTC day
# + return - False when the budget is spent, or an error
isolated function takeApiCall(postgresql:Client db, types:ProviderApi providerApi, time:Utc now, int budget)
        returns boolean|error {
    if budget <= 0 {
        return false;
    }
    string day = time:utcToString(now).substring(0, 10);
    int|error calls = db->queryRow(`
        INSERT INTO sharing_api_usage (provider_api, day, calls)
        VALUES (${providerApi}, CAST(${day} AS date), 1)
        ON CONFLICT (provider_api, day) DO UPDATE SET calls = sharing_api_usage.calls + 1
        WHERE sharing_api_usage.calls < ${budget}
        RETURNING calls`);
    if calls is error {
        return store:isNoRows(calls) ? false : calls;
    }
    return true;
}
