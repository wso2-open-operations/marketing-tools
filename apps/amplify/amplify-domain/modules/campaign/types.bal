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

import amplify_common.events;
import amplify_common.types;

import ballerina/time;

# Derived campaign status (`campaign.campaign_v`). Never stored.
public enum CampaignStatus {
    SCHEDULED,
    OPEN,
    CLOSED,
    ARCHIVED
}

# Longest campaign title.
public const int TITLE_MAX_LENGTH = 200;
# Longest tag.
public const int TAG_MAX_LENGTH = 50;
# Longest summary (`campaign.campaign.summary` CHECK).
public const int SUMMARY_MAX_LENGTH = 2000;
# Default active window in days when `closesAt` isn't given (C7, `campaign.default_window_days`).
public const int DEFAULT_WINDOW_DAYS = 30;

# Where a campaign's post link may point: LinkedIn only. Dev and demo environments add the mock's origin.
public final string[] & readonly DEFAULT_POST_LINK_ORIGINS = ["https://www.linkedin.com", "https://linkedin.com"];

# Campaign aggregate (`campaign.campaign` + `campaign.campaign_tag`): one WSO2 company-page resource to amplify.
public type Campaign record {|
    # UUIDv7
    string id;
    # Provider of the resource
    types:Provider provider;
    # Resource URN, unique per provider
    types:PostUrn resourceUrn;
    # Derived from the URN
    types:ResourceType resourceType;
    # Organization that owns the resource; must be the WSO2 page
    types:OrganizationUrn ownerUrn;
    # Public URL of the resource
    string? resourceUrl;
    # Title shown on the Posts page and the Club card
    string title;
    # Summary shown on the card
    string? summary;
    # HTTPS image for the card
    string? imageUrl;
    # `campaign.category.code`
    string categoryCode;
    # Priority flag
    boolean isPriority;
    # Lowercase, unique tags
    string[] tags;
    # Window start
    time:Utc opensAt;
    # Window end, after `opensAt`
    time:Utc closesAt;
    # Soft delete ("Delete" archives)
    time:Utc? archivedAt;
    # `amplify_marketing` or `amplify_po` who registered it
    types:EmployeeId createdBy;
    # Insert time
    time:Utc createdAt;
    # Last change
    time:Utc updatedAt;
    # Optimistic lock
    int version;
|};

# Input to register a campaign.
public type CampaignDraft record {|
    # Resource URN, for example `urn:li:share:7123`
    string resourceUrn;
    # Owner organization URN, from the resource lookup
    string ownerUrn;
    # Public URL of the resource
    string? resourceUrl = ();
    # Title
    string title;
    # Summary
    string? summary = ();
    # HTTPS image
    string? imageUrl = ();
    # Category code
    string categoryCode;
    # Priority flag
    boolean isPriority = false;
    # Tags (normalized to lowercase, unique)
    string[] tags = [];
    # Window start; defaults to now
    time:Utc? opensAt = ();
    # Window end; defaults to `opensAt` + the default window (C7)
    time:Utc? closesAt = ();
|};

# Fields a campaign edit may change. `()` keeps the current value. The post id (`resourceUrn`) may change only
# while nothing has been recorded against the campaign (`POST_HAS_ACTIVITY` otherwise); the link may always change.
public type CampaignPatch record {|
    # New post id (`urn:li:...`); same rules as registration
    string? resourceUrn = ();
    # New public link to the post; same origin rules as registration. A blank value clears it
    string? resourceUrl = ();
    # New title
    string? title = ();
    # New summary
    string? summary = ();
    # New image
    string? imageUrl = ();
    # New category
    string? categoryCode = ();
    # New priority flag
    boolean? isPriority = ();
    # Replacement tags
    string[]? tags = ();
    # New window start
    time:Utc? opensAt = ();
    # New window end
    time:Utc? closesAt = ();
|};

# Settings the campaign rules depend on.
public type CampaignPolicy record {|
    # The WSO2 company page URN; campaigns must point at its resources
    types:OrganizationUrn wso2OrganizationUrn;
    # `campaign.default_window_days`
    int defaultWindowDays = DEFAULT_WINDOW_DAYS;
    # Origins (`scheme://host[:port]`, lowercase) a post link may use; the link is shown on every employee's card
    string[] postLinkOrigins = DEFAULT_POST_LINK_ORIGINS;
|};

# Persistence port for the `campaign` schema. M3 implements it with SQL; tests use an in-memory one.
# Each write stores the aggregate and its outbox events in one transaction.
public type CampaignRepository isolated object {
    # Finds a campaign by id.
    #
    # + id - Campaign id
    # + return - The campaign, `()` if none, or an error
    public isolated function findById(string id) returns Campaign|error?;

    # Finds a campaign by its provider resource.
    #
    # + provider - Provider
    # + resourceUrn - Resource URN
    # + return - The campaign, `()` if none, or an error
    public isolated function findByResource(types:Provider provider, types:PostUrn resourceUrn) returns Campaign|error?;

    # Inserts a new campaign with its events.
    #
    # + campaign - New campaign
    # + outbox - Events to write in the same transaction
    # + return - An error on failure
    public isolated function insert(Campaign campaign, events:OutboxEvent[] outbox) returns error?;

    # Updates a campaign if its stored version still equals `expectedVersion`.
    #
    # + campaign - Changed campaign
    # + expectedVersion - Version read before the change
    # + return - `VERSION_CONFLICT` if someone else changed it, or another error
    public isolated function update(Campaign campaign, int expectedVersion) returns error?;

    # Whether anything has been recorded against the campaign: a share request, an engagement, an external
    # share or a points ledger row, matched by campaign id (and, except for the ledger, by the post id). Read-only, across contexts (like the reporting reads).
    #
    # + id - Campaign id
    # + resourceUrn - The campaign's stored post id
    # + return - True when there is recorded activity, or an error
    public isolated function hasActivity(string id, string resourceUrn) returns boolean|error;
};
