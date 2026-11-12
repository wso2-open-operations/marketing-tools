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

# Derived announcement status (`announcement_v`). Never stored.
public enum AnnouncementStatus {
    QUEUED,
    SENT,
    FAILED
}

# Announcement aggregate (`announcement`): one Novera announcement per campaign. PK = `campaignId`,
# so a campaign is announced exactly once.
public type Announcement record {|
    # Campaign (PK)
    string campaignId;
    # Outbox id of the `CampaignRegistered` row
    int? outboxId;
    # `novera` (rows from before Novera replaced the Club webhook say `club` or `dev-test`)
    string space;
    # Key sent to Novera as `Idempotency-Key`: `amplify:{campaignId}` (column `thread_key`; older rows hold
    # `campaign-{id}`)
    string idempotencyKey;
    # Delivery marker `novera:{campaignId}` (column `chat_message_name`); Novera returns no message name
    string? messageName;
    # Queue time
    time:Utc queuedAt;
    # Sent fact
    time:Utc? sentAt;
    # Failed fact
    time:Utc? failedAt;
    # Last delivery error (safe text, never a URL or a credential)
    string? lastError;
    # Attempt marker (column `attempted_at`, V022): written before the Novera call and cleared only when the call
    # definitely sent nothing. A queued row that still carries it may already have reached Novera
    time:Utc? attemptedAt = ();
    # Novera's id for the broadcast (column `novera_notification_id`, V023), when Novera returned one; the key for
    # its seen counts
    string? noveraNotificationId = ();
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
    # The Amplify button: opens the configured link (`noveraButtonUrl`) for this campaign
    record {|string url; string label;|} button;
    # The campaign id, so Novera can count who has seen the card (V023). Sent only when seen stats are on: a Novera
    # that predates them refuses unknown fields
    string reference?;
|};

# Who has seen a broadcast, as Novera counts it (`GET /internal/notifications/{id}/stats`).
public type NoveraSeenStats record {|
    # DMs the card went to
    int recipients;
    # Of those, people whose chat was read past the card
    int seen;
|};

# An announcement whose Novera seen counts are due for a refresh.
public type NoveraStatsTarget record {|
    # Campaign
    string campaignId;
    # Novera's broadcast id
    string notificationId;
|};
