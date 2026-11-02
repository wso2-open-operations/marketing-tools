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

// The activity matrix in code. Mirrors architecture/solution/Phase 1/activity-matrix.md row for row:
// change both together. The interceptor enforces grant × method × route (403); everything in `useCase`
// (state, ownership, kill switches) is checked by the use case behind the resource, never here.

# One row of the matrix.
public type Rule record {|
    # HTTP method, upper case
    string method;
    # Route template; `{name}` matches one path segment
    string path;
    # Grant the caller needs (anyone else gets 403)
    Access requires;
    # Capability this row grants, reported by `GET /me`
    string capability;
    # State and ownership conditions the use case checks (not the interceptor)
    string useCase = "";
    # False while the route has no resource yet: the row keeps the grant in place for when it lands,
    # but `GET /me` does not advertise a capability the UI could not use (it would 404).
    boolean built = true;
|};

# The matrix. First match wins; a route that isn't here is denied (default deny).
public final Rule[] & readonly ACTIVITY_MATRIX = [
    // Identity
    {method: "GET", path: "/me", requires: EMPLOYEE, capability: "me.read", useCase: "Own row only; upserts identity.employee"},
    // S1 Campaign
    {method: "GET", path: "/campaigns", requires: EMPLOYEE, capability: "campaigns.read", useCase: "OPEN only (default window 14d); CAN_CAMPAIGN any status"},
    {method: "GET", path: "/campaigns/{id}", requires: EMPLOYEE, capability: "campaigns.read", useCase: "OPEN campaigns only, else 404; CAN_CAMPAIGN any status"},
    {method: "GET", path: "/tags", requires: EMPLOYEE, capability: "catalog.read"},
    {method: "GET", path: "/categories", requires: EMPLOYEE, capability: "catalog.read"},
    {method: "POST", path: "/campaigns", requires: CAN_CAMPAIGN, capability: "campaigns.manage", useCase: "?shareNow=true also triggers amplify-jobs /runs; closes_at default (C7)"},
    {method: "PATCH", path: "/campaigns/{id}", requires: CAN_CAMPAIGN, capability: "campaigns.manage", useCase: "Not on an archived campaign; optimistic lock"},
    {method: "DELETE", path: "/campaigns/{id}", requires: CAN_CAMPAIGN, capability: "campaigns.manage", useCase: "Soft archive only"},
    // S2 Connection
    {method: "POST", path: "/connections/linkedin/start", requires: EMPLOYEE, capability: "linkedin.connect", useCase: "Own; issues state"},
    {method: "POST", path: "/connections/linkedin/complete", requires: EMPLOYEE, capability: "linkedin.connect", useCase: "Own; state matches, unused, unexpired, same employee"},
    {method: "POST", path: "/connections/linkedin/decline", requires: EMPLOYEE, capability: "linkedin.connect", useCase: "Own; records the decline and an optional LinkedIn profile URL"},
    {method: "DELETE", path: "/connections/linkedin", requires: EMPLOYEE, capability: "linkedin.connect", useCase: "Own; revokes the token at LinkedIn, then deletes it"},
    // C1 Sharing
    {method: "POST", path: "/campaigns/{id}/shares", requires: EMPLOYEE, capability: "shares.create", useCase: "Own; campaign OPEN; connection ACTIVE/EXPIRING; one per campaign (retry reuses row, ADR-015); sharing.enabled"},
    {method: "GET", path: "/me/shares", requires: EMPLOYEE, capability: "shares.read_own"},
    // S3 External Sharing
    {method: "POST", path: "/external-shares", requires: EMPLOYEE, capability: "external_shares.submit", useCase: "Own; (evidence_url, action) unique (ADR-017); host allow-list"},
    {method: "GET", path: "/me/external-shares", requires: EMPLOYEE, capability: "external_shares.read_own"},
    {method: "GET", path: "/po/external-shares", requires: CAN_REVIEW_SHARES, capability: "external_shares.review"},
    {method: "POST", path: "/po/external-shares/{id}/approve", requires: CAN_REVIEW_SHARES, capability: "external_shares.review", useCase: "Only while PENDING; not own claim"},
    {method: "POST", path: "/po/external-shares/{id}/reject", requires: CAN_REVIEW_SHARES, capability: "external_shares.review", useCase: "Only while PENDING; reason required; not own claim"},
    {method: "POST", path: "/po/external-shares/{id}/amplified", requires: CAN_REVIEW_SHARES, capability: "external_shares.review", useCase: "Only on APPROVED (C4); once"},
    // C2 Scoring
    {method: "GET", path: "/po/point-rules", requires: CAN_POINT_RULES, capability: "point_rules.manage"},
    {method: "POST", path: "/po/point-rules", requires: CAN_POINT_RULES, capability: "point_rules.manage", useCase: "New version; past awards keep their value"},
    {method: "POST", path: "/po/points/adjustments", requires: CAN_ADJUST_POINTS, capability: "points.adjust", useCase: "Reason required; recognition in the same transaction (B12)"},
    {method: "POST", path: "/po/points/{reference}/reverse", requires: CAN_ADJUST_POINTS, capability: "points.adjust", useCase: "Reason required; not already reversed"},
    // S4 Recognition
    {method: "GET", path: "/leaderboard", requires: EMPLOYEE, capability: "leaderboard.read", useCase: "Top N, personal, My Team (ADR-014)"},
    {method: "GET", path: "/leaderboard/top", requires: EMPLOYEE, capability: "leaderboard.top.read", useCase: "Celebrate top three and My position, this month by default, company wide, monthly totals cached 2 hours (ADR-037)"},
    {method: "GET", path: "/leaderboard/people", requires: EMPLOYEE, capability: "leaderboard.people.read", useCase: "Company, BU or team board; open to every employee (ADR-035)"},
    {method: "GET", path: "/leaderboard/groups", requires: EMPLOYEE, capability: "leaderboard.groups.read", useCase: "Teams or BUs ranked; open to every employee (ADR-035)"},
    {method: "GET", path: "/headcount", requires: EMPLOYEE, capability: "headcount.read", useCase: "Employee count from the people directory, cached 7 days (ADR-035)"},
    {method: "GET", path: "/dashboards/operations", requires: CAN_DASHBOARD, capability: "dashboards.operations.read", useCase: "Operations board (ADR-036)"},
    {method: "GET", path: "/dashboards/campaigns", requires: CAN_DASHBOARD, capability: "dashboards.campaigns.read", useCase: "Campaign performance board"},
    {method: "GET", path: "/dashboards/export", requires: CAN_EXPORT, capability: "dashboards.export.read", useCase: "Raw rows behind the boards for a date range, CSV"},
    {method: "GET", path: "/dashboards/people/{employeeId}", requires: CAN_DASHBOARD, capability: "dashboards.people.read", useCase: "One person's Post Performance popup"},
    {method: "GET", path: "/dashboards/participation", requires: CAN_DASHBOARD, capability: "dashboards.participation.read", useCase: "Participation funnel numbers"},
    {method: "GET", path: "/dashboards/glance", requires: CAN_DASHBOARD, capability: "dashboards.glance.read", useCase: "At a glance numbers"},
    {method: "GET", path: "/dashboards/scorecard", requires: CAN_DASHBOARD, capability: "dashboards.scorecard.read", useCase: "Scorecard against the scorecard.* targets"},
    {method: "GET", path: "/me/points", requires: EMPLOYEE, capability: "points.read_own"},
    {method: "GET", path: "/team", requires: EMPLOYEE, capability: "team.read", useCase: "Roster team or company per ADR-014/ADR-019; CAN_ADJUST_POINTS company"},
    {method: "GET", path: "/team/{employeeId}/history", requires: EMPLOYEE, capability: "team.history.read", useCase: "Without CAN_ADJUST_POINTS: the caller, or a member of the caller's roster team (team.visibility = COMPANY does not widen it, ADR-035), else 403 TEAM_SCOPE (leaderboards.md); CAN_ADJUST_POINTS any (team.history.read_any)"},
    {method: "GET", path: "/po/dashboard", requires: CAN_PO_DASHBOARD, capability: "po.dashboard"},
    {method: "GET", path: "/reports/participation", requires: CAN_REPORTS, capability: "reports.read", useCase: "Phase 2", built: false},
    {method: "GET", path: "/reports/campaigns", requires: CAN_REPORTS, capability: "reports.read", useCase: "Phase 2", built: false},
    // S5 / Admin
    {method: "GET", path: "/admin/announcements", requires: CAN_ADMIN, capability: "admin.announcements"},
    {method: "POST", path: "/admin/announcements/{id}/retry", requires: CAN_ADMIN, capability: "admin.announcements", useCase: "Only while FAILED; announcements.enabled"},
    {method: "GET", path: "/admin/settings", requires: CAN_ADMIN, capability: "admin.settings"},
    {method: "PUT", path: "/admin/settings", requires: CAN_ADMIN, capability: "admin.settings", useCase: "Optimistic lock; Coin settings hidden"},
    {method: "POST", path: "/admin/scheduler/sync", requires: CAN_ADMIN, capability: "admin.settings", useCase: "Pushes the schedule settings to the scheduler (ADR-026)"}
];

# Capabilities checked inside a use case rather than per route. Reported by `GET /me` so the UI can
# show the right controls.
public final Rule[] & readonly USE_CASE_CAPABILITIES = [
    {method: "GET", path: "/campaigns", requires: CAN_CAMPAIGN, capability: "campaigns.read_any_status"},
    {method: "GET", path: "/team/{employeeId}/history", requires: CAN_ADJUST_POINTS, capability: "team.history.read_any"}
];

# Routes that skip authentication: probes only, never published through the proxy.
public final string[] & readonly PUBLIC_PATHS = ["/health", "/ready"];

# Finds the matrix row for a call.
#
# + method - HTTP method
# + segments - Decoded path segments
# + return - The row, or `()` when the route isn't in the matrix
public isolated function findRule(string method, string[] segments) returns Rule? {
    string verb = method.toUpperAscii();
    foreach Rule rule in ACTIVITY_MATRIX {
        if rule.method == verb && matches(rule.path, segments) {
            return rule;
        }
    }
    return ();
}

# Whether the caller's grants allow a row.
#
# + rule - Matrix row
# + grants - The caller's grants (`grantsOf`)
# + return - True when the caller holds the row's grant
public isolated function isAllowed(Rule rule, Access[] grants) returns boolean =>
    grants.indexOf(rule.requires) !is ();

# Capabilities for `GET /me`, derived from the matrix (route rows plus use-case rows).
#
# + grants - The caller's grants (`grantsOf`)
# + return - Distinct capability ids, sorted; rows for routes that are not built yet are left out
public isolated function capabilities(Access[] grants) returns string[] {
    string[] result = [];
    foreach Rule rule in [...ACTIVITY_MATRIX, ...USE_CASE_CAPABILITIES] {
        if rule.built && isAllowed(rule, grants) && result.indexOf(rule.capability) is () {
            result.push(rule.capability);
        }
    }
    return result.sort();
}

# Whether a path is a probe.
#
# + segments - Decoded path segments
# + return - True for `/health` and `/ready`
public isolated function isPublic(string[] segments) returns boolean =>
    segments.length() == 1 && PUBLIC_PATHS.indexOf("/" + segments[0]) !is ();

isolated function matches(string template, string[] segments) returns boolean {
    string[] parts = re `/`.split(template.substring(1));
    if parts.length() != segments.length() {
        return false;
    }
    foreach int i in 0 ..< parts.length() {
        string part = parts[i];
        boolean isParam = part.startsWith("{") && part.endsWith("}");
        if isParam ? segments[i].length() == 0 : part != segments[i] {
            return false;
        }
    }
    return true;
}
