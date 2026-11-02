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

// Events S1 publishes. Opening and closing are time-derived, so there is no CampaignOpened/Closed event.

import amplify_common.events;

import ballerina/time;

# `CampaignRegistered` for a newly saved campaign.
#
# + campaign - The campaign
# + shareNow - Save & Share Now
# + return - Outbox row
public isolated function campaignRegisteredEvent(Campaign campaign, boolean shareNow) returns events:OutboxEvent =>
    events:newCampaignRegistered({
        campaignId: campaign.id,
        provider: campaign.provider,
        resourceUrn: campaign.resourceUrn,
        title: campaign.title,
        isPriority: campaign.isPriority,
        shareNow,
        opensAt: time:utcToString(campaign.opensAt)
    });
