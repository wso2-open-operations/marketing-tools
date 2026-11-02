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

# Component name used in logs and probe bodies.
const string COMPONENT = "amplify-api";

# Request-context key for the verified caller.
const string PRINCIPAL_KEY = "amplify.principal";
# Correlation header.
const string CORRELATION_HEADER = "X-Correlation-ID";
// Header amplify-jobs requires on every call except its probes (security review, back-office components).
const string INTERNAL_KEY_HEADER = "X-Amplify-Internal-Key";
# Problem details media type.
const string PROBLEM_JSON = "application/problem+json";
# Problem `type` prefix.
const string PROBLEM_TYPE_PREFIX = "urn:wso2:amplify:problem:";

# Route not in the activity matrix (default deny).
const string ROUTE_NOT_PERMITTED = "ROUTE_NOT_PERMITTED";
# Caller's roles don't allow the route.
const string ROLE_NOT_PERMITTED = "ROLE_NOT_PERMITTED";
# Database or another dependency is down.
const string DEPENDENCY_UNAVAILABLE = "DEPENDENCY_UNAVAILABLE";
# Token email already belongs to another employee row.
const string EMAIL_CONFLICT = "EMAIL_CONFLICT";

# Audit action for a denied call.
const string ACCESS_DENIED = "AccessDenied";
# Audit entity type for a denied call.
const string ROUTE_ENTITY = "http.route";
# Actor id when the caller couldn't be authenticated.
const string ANONYMOUS = "anonymous";
# Most denial keys the audit throttle holds; past it, keys older than the window are dropped.
const int DENIAL_THROTTLE_MAX = 1024;
# `GET /me` LinkedIn status when the employee never connected.
const string NOT_CONNECTED = "NOT_CONNECTED";

// ---- M5: request plumbing ------------------------------------------------------------------------

# Request-context key for the correlation id (caller's, or generated).
const string CORRELATION_KEY = "amplify.correlationId";
# Idempotency header.
const string IDEMPOTENCY_HEADER = "Idempotency-Key";
# Set on a replayed response.
const string REPLAYED_HEADER = "Idempotent-Replayed";
# How long an idempotency key is remembered.
const int IDEMPOTENCY_TTL_SECONDS = 86400;

// ---- M5: stable API codes (the domain codes in amplify_common.types pass through unchanged) -------

# Request body, query or path failed validation.
const string VALIDATION_FAILED = "VALIDATION_FAILED";
# Request body is larger than the API accepts (413).
const string PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE";
# Unknown resource, or one the caller may not see.
const string NOT_FOUND = "NOT_FOUND";
# Unexpected failure (details only in the log).
const string INTERNAL_ERROR = "INTERNAL_ERROR";
# Same `Idempotency-Key`, different request.
const string IDEMPOTENCY_KEY_REUSED = "IDEMPOTENCY_KEY_REUSED";
# Same `Idempotency-Key` while the first request still runs.
const string IDEMPOTENCY_IN_PROGRESS = "IDEMPOTENCY_IN_PROGRESS";
# The employee never connected LinkedIn.
const string LINKEDIN_NOT_CONNECTED = "LINKEDIN_NOT_CONNECTED";
# The connection expired, was revoked or removed.
const string NEEDS_RECONNECT = "NEEDS_RECONNECT";
# The campaign isn't open (scheduled, closed or archived).
const string CAMPAIGN_CLOSED = "CAMPAIGN_CLOSED";
# The caller already did this (share queued or published).
const string DUPLICATE_ACTION = "DUPLICATE_ACTION";
# A kill switch is off.
const string FEATURE_DISABLED = "FEATURE_DISABLED";
# OAuth `state` unknown, used, expired or someone else's.
const string OAUTH_STATE_INVALID = "OAUTH_STATE_INVALID";
# The callback page the browser landed on isn't the configured LinkedIn redirect URI.
const string OAUTH_REDIRECT_MISMATCH = "OAUTH_REDIRECT_MISMATCH";
# The route exists but not with this method (dispatcher 405).
const string METHOD_NOT_ALLOWED = "METHOD_NOT_ALLOWED";
# Outside the caller's team scope (leaderboards.md).
const string TEAM_SCOPE = "TEAM_SCOPE";
# Setting key not editable.
const string UNKNOWN_SETTING = "UNKNOWN_SETTING";
# Setting value out of range.
const string INVALID_SETTING = "INVALID_SETTING";

// ---- M5: settings keys (config.app_setting) -------------------------------------------------------

const string SETTING_TOP_N = "leaderboard.top_n";
const string SETTING_TOP_SCOPE = "leaderboard.top_scope";
const string SETTING_TOP_MIN_POINTS = "leaderboard.top_min_points";
const string SETTING_TEAM_VISIBILITY = "team.visibility";
const string SETTING_WINDOW_DAYS = "campaign.default_window_days";
const string SETTING_SLA_HOURS = "po.review_sla_hours";
const string SETTING_POSTS_WINDOW = "posts.window_days";
const string SETTING_REMINDER_DAYS = "connection.reminder_days";
const string SETTING_TOKEN_GRACE_DAYS = "connection.token_grace_days";
const string SETTING_AUDIT_RETENTION = "audit.retention_months";
const string SETTING_SHARING_ENABLED = "sharing.enabled";
const string SETTING_ANNOUNCEMENTS_ENABLED = "announcements.enabled";

// ---- M6b: schedule settings pushed to the scheduler (ADR-026) -------------------------------------

const string SETTING_RUN_SCHEDULE = "run.schedule";
const string SETTING_RUN_ENABLED = "run.enabled";
const string SETTING_MAINTENANCE_SCHEDULE = "maintenance.schedule";
# Scheduler job ids (stable: the upsert key).
const string JOB_RUN = "amplify-run";
const string JOB_MAINTENANCE = "amplify-maintenance-partitions";
# Scheduler unreachable on an explicit sync.
const string SCHEDULER_UNAVAILABLE = "SCHEDULER_UNAVAILABLE";
