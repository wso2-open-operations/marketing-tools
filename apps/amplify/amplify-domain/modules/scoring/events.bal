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

// Events C2 publishes: PointsAwarded / PointsAdjusted / PointsReversed, keyed by ledger reference.
// S4 recognition consumes them in the same transaction (B12).

import amplify_common.events;
import amplify_common.types;

# The points event for a ledger row.
#
# + entry - Appended row
# + return - Outbox row
public isolated function pointsChangedEvent(types:LedgerEntry entry) returns events:OutboxEvent =>
    events:newPointsChanged(entry);
