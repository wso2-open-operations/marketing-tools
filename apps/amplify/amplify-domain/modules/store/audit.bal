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

// Audit writer (`audit.audit_log`, append-only, monthly partitions, 5 years). Used inside the same
// transaction as the change it records. `before` / `after` hold changed fields only, never tokens or
// commentary.

import ballerinax/postgresql;

# Outcome of an audited action.
public type AuditOutcome "SUCCESS"|"DENIED"|"FAILED";

# One audit row.
public type AuditEntry record {|
    # Employee id, or `system`
    string actorId;
    # Roles of the actor at the time
    string[] actorRoles = [];
    # What happened, for example the event type CampaignRegistered
    string action;
    # Table or aggregate, for example `campaign.campaign`
    string entityType;
    # Aggregate id
    string? entityId = ();
    # Outcome
    AuditOutcome outcome = "SUCCESS";
    # Changed fields before
    json before = ();
    # Changed fields after
    json after = ();
    # Reason given (PO decisions and corrections)
    string? reason = ();
    # Correlation id
    string? correlationId = ();
|};

# Writes one audit row.
#
# + db - Client, inside the caller's transaction
# + entry - Audit row
# + return - An error on failure
public isolated transactional function writeAudit(postgresql:Client db, AuditEntry entry) returns error? {
    string? before = entry.before is () ? () : entry.before.toJsonString();
    string? after = entry.after is () ? () : entry.after.toJsonString();
    string roles = arrayLiteral(entry.actorRoles);
    _ = check db->execute(`
        INSERT INTO audit.audit_log (actor_id, actor_roles, action, entity_type, entity_id, outcome, before, after,
                                     reason, correlation_id)
        VALUES (${entry.actorId}, CAST(${roles} AS text[]), ${entry.action}, ${entry.entityType}, ${entry.entityId},
                ${entry.outcome}, CAST(${before} AS jsonb), CAST(${after} AS jsonb), ${entry.reason},
                ${entry.correlationId})`);
}

# Postgres array literal for a bind parameter (cast to text[] in SQL): each item double-quoted, with
# double quotes and backslashes escaped.
# It's a value, never SQL text.
#
# + items - Strings
# + return - Array literal
public isolated function arrayLiteral(string[] items) returns string {
    string[] quoted = from string item in items
        select "\"" + re `"`.replaceAll(re `\\`.replaceAll(item, "\\\\"), "\\\"") + "\"";
    return "{" + string:'join(",", ...quoted) + "}";
}

# Who a repository acts for. Repositories are cheap wrappers over the shared client: amplify-api builds
# one per request with the caller, amplify-jobs uses `SYSTEM`. Every write audits with it.
public type Actor record {|
    # Employee id (Asgardeo `sub`) or `system`
    string actorId;
    # Caller's `amplify_*` roles
    string[] roles = [];
    # Request or run correlation id
    string? correlationId = ();
|};

# The jobs worker and maintenance.
public final Actor & readonly SYSTEM = {actorId: "system", roles: ["amplify_jobs"]};

# Audit row for a write by `actor`.
#
# + actor - Who
# + action - What, for example CampaignRegistered or CampaignUpdated
# + entityType - Table, for example `campaign.campaign`
# + entityId - Aggregate id
# + after - Changed fields after
# + reason - Reason, if any
# + before - The same fields before the change (`()` for an insert)
# + return - The entry
public isolated function auditOf(Actor actor, string action, string entityType, string entityId, json after = (),
        string? reason = (), json before = ()) returns AuditEntry => {
    actorId: actor.actorId,
    actorRoles: actor.roles,
    action,
    entityType,
    entityId,
    before,
    after,
    reason,
    correlationId: actor.correlationId
};
