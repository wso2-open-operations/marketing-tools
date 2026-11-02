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

import ballerina/time;

# Derived announcement status (`announcement.announcement_v`). Never stored.
public enum AnnouncementStatus {
    QUEUED,
    SENT,
    FAILED
}

# Announcement aggregate (`announcement.announcement`): one Club card per campaign. PK = `campaignId`,
# so a campaign is announced exactly once.
public type Announcement record {|
    # Campaign (PK)
    string campaignId;
    # Outbox id of the `CampaignRegistered` row
    int? outboxId;
    # `club` or `dev-test`
    string space;
    # `campaign-{id}`
    string threadKey;
    # Name Chat returned
    string? chatMessageName;
    # Thread name Chat returned (`spaces/{space}/threads/{thread}`), when it sent one
    string? chatThreadName = ();
    # Queue time
    time:Utc queuedAt;
    # Sent fact
    time:Utc? sentAt;
    # Failed fact
    time:Utc? failedAt;
    # Last webhook error (never the webhook URL)
    string? lastError;
|};

# What the card needs from the campaign (S1 → S5, Customer/Supplier).
public type CampaignCardSource record {|
    # Campaign id
    string campaignId;
    # Title
    string title;
    # Summary
    string? summary;
    # HTTPS image
    string? imageUrl;
    # Priority flag
    boolean isPriority;
|};

# A campaign announcement for Novera's `POST /internal/notifications` (plain text; Novera builds and escapes the card).
public type NoveraNotification record {|
    # Caller id Novera logs and uses in the card id
    string 'source;
    # Bold title
    string title;
    # One grey line under the title
    string subtitle;
    # Body text
    string body;
    # Icon beside the title (https only), if any
    string iconUrl?;
    # Picture under the title (public https only), if any
    string imageUrl?;
    # The Amplify button: opens the Celebrate page with this campaign's share dialog
    record {|string url; string label;|} button;
|};
