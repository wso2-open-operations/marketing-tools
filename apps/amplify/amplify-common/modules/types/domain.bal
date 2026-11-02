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

// Shared kernel: enums and the domain error used by every bounded context in amplify-api and amplify-jobs.
// Enums are const unions (not `enum`) because several contexts reuse the same member names
// (for example `REPOST` is both a share kind and a point action).

import ballerina/time;

// ---- Domain error -------------------------------------------------------------------------------

# Detail of a domain error. `code` is stable and safe to return to API callers.
public type DomainErrorDetail record {|
    # Stable error code, for example `EVIDENCE_ALREADY_CLAIMED`
    string code;
|};

# A rule of the domain was broken. The message is safe to show; it never carries tokens or commentary.
public type DomainError distinct error<DomainErrorDetail>;

# Builds a domain error.
#
# + code - Stable error code
# + message - Human readable message, safe to show
# + return - The error
public isolated function domainError(string code, string message) returns DomainError =>
    error DomainError(message, code = code);

// ---- Providers ----------------------------------------------------------------------------------

# LinkedIn, the only provider in phase 1.
public const LINKEDIN = "linkedin";

# Social platform an aggregate refers to (`provider` column).
public type Provider LINKEDIN;

# Share on LinkedIn (member token, `w_member_social`).
public const SHARE_ON_LINKEDIN = "SHARE_ON_LINKEDIN";
# Community Management API (future phase).
public const COMMUNITY_MANAGEMENT = "COMMUNITY_MANAGEMENT";
# Provider webhook (future phase).
public const WEBHOOK = "WEBHOOK";

# Provider API product used for a call or a fact (`provider_api` column).
public type ProviderApi SHARE_ON_LINKEDIN|COMMUNITY_MANAGEMENT|WEBHOOK;

// ---- Resources ----------------------------------------------------------------------------------

# LinkedIn share (`urn:li:share`).
public const SHARE = "SHARE";
# LinkedIn UGC post (`urn:li:ugcPost`).
public const UGC_POST = "UGC_POST";
# LinkedIn article.
public const ARTICLE = "ARTICLE";
# LinkedIn video.
public const VIDEO = "VIDEO";
# LinkedIn document.
public const DOCUMENT = "DOCUMENT";
# LinkedIn event.
public const EVENT = "EVENT";
# Any other resource, for example an activity URN.
public const OTHER = "OTHER";

# Type of the provider resource a campaign points at (`resource_type` column).
public type ResourceType SHARE|UGC_POST|ARTICLE|VIDEO|DOCUMENT|EVENT|OTHER;

// ---- Share kinds and point actions --------------------------------------------------------------

# Reshare the campaign post.
public const REPOST = "REPOST";
# Reshare the campaign post with the employee's own thoughts.
public const REPOST_COMMENTARY = "REPOST_COMMENTARY";
# New post linking to the campaign post (D5 fallback, B4). `SHARE` is the shared constant above.
public const SHARE_COMMENTARY = "SHARE_COMMENTARY";
# Employee's own post, claimed through External Sharing.
public const OWN_POST = "OWN_POST";
# Own post amplified by WSO2 or a senior leader (T4 top-up, C4).
public const OWN_POST_AMPLIFIED = "OWN_POST_AMPLIFIED";

# A like on an Amplify post on LinkedIn (phase 4, Community Management).
public const REACTION = "REACTION";
# A comment on an Amplify post on LinkedIn (phase 4).
public const COMMENT = "COMMENT";
# Amplify Challenge entry (a PO adjustment until the Challenge has its own flow).
public const CHALLENGE_ENTRY = "CHALLENGE_ENTRY";
# Amplify Challenge winner (a PO adjustment until the Challenge has its own flow).
public const CHALLENGE_WINNER = "CHALLENGE_WINNER";

# What an in-app share does on LinkedIn. The kind sets the tier.
public type ShareKind REPOST|REPOST_COMMENTARY|SHARE|SHARE_COMMENTARY;

# Engagement action. Phase 1 records only in-app share kinds (comments and reactions are a future phase).
public type EngagementAction ShareKind;

# External share action. Phase 1 has only `OWN_POST`.
public type ExternalAction OWN_POST;

# Action a point rule prices and a ledger row records.
public type PointAction ShareKind|OWN_POST|OWN_POST_AMPLIFIED|REACTION|COMMENT|CHALLENGE_ENTRY|CHALLENGE_WINNER;

# Whether a share kind carries the employee's commentary.
#
# + kind - Share kind
# + return - True for `REPOST_COMMENTARY` and `SHARE_COMMENTARY`
public isolated function hasCommentary(ShareKind kind) returns boolean =>
    kind == REPOST_COMMENTARY || kind == SHARE_COMMENTARY;

// ---- Share failures -----------------------------------------------------------------------------

# Connection expired, was revoked or removed. The employee must reconnect.
public const NEEDS_RECONNECT = "NEEDS_RECONNECT";
# LinkedIn refused the post (4xx other than 401).
public const PROVIDER_REJECTED = "PROVIDER_REJECTED";
# Transient errors outlasted the retry budget.
public const RETRIES_EXHAUSTED = "RETRIES_EXHAUSTED";

# Why a share request failed (`failure_reason` column).
public type FailureReason NEEDS_RECONNECT|PROVIDER_REJECTED|RETRIES_EXHAUSTED;

// ---- Engagement origin --------------------------------------------------------------------------

# Recorded by Amplify's own share flow.
public const IN_APP = "IN_APP";
# Recorded by a provider sync (future phase).
public const API_SYNC = "API_SYNC";

# Where an engagement fact came from. `WEBHOOK` is the shared constant above.
public type EngagementOrigin IN_APP|API_SYNC|WEBHOOK;

// ---- Time helpers -------------------------------------------------------------------------------

# Seconds in one day.
public const decimal SECONDS_PER_DAY = 86400;

# Whether `a` is strictly before `b`.
#
# + a - First instant
# + b - Second instant
# + return - True when `a < b`
public isolated function isBefore(time:Utc a, time:Utc b) returns boolean => time:utcDiffSeconds(a, b) < 0d;

# Adds whole days to an instant.
#
# + t - Instant
# + days - Days to add (may be negative)
# + return - The shifted instant
public isolated function addDays(time:Utc t, int days) returns time:Utc =>
    time:utcAddSeconds(t, <decimal>days * SECONDS_PER_DAY);

# Trims a string and returns `()` when nothing is left.
#
# + value - Input, may be `()`
# + return - Trimmed value, or `()` when blank
public isolated function trimToNil(string? value) returns string? {
    if value is () {
        return ();
    }
    string trimmed = value.trim();
    return trimmed.length() == 0 ? () : trimmed;
}
