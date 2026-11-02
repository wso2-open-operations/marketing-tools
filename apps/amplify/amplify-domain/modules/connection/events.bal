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

// Events S2 publishes. Expiry is time-derived, so there is no ConnectionExpired event.

import amplify_common.events;

import ballerina/time;

# `ConnectionReady` after connect or reconnect.
#
# + connection - The connection
# + return - Outbox row
public isolated function connectionReadyEvent(LinkedInConnection connection) returns events:OutboxEvent =>
    events:newConnectionReady({
        employeeId: connection.employeeId,
        provider: connection.provider,
        memberUrn: connection.memberUrn,
        connectedAt: time:utcToString(connection.connectedAt),
        accessExpiresAt: time:utcToString(connection.accessExpiresAt)
    });

# `ConnectionRevoked` after a LinkedIn 401 or withdrawn consent.
#
# + connection - The connection
# + revokedAt - Revocation time
# + return - Outbox row
public isolated function connectionRevokedEvent(LinkedInConnection connection, time:Utc revokedAt)
        returns events:OutboxEvent =>
    events:newConnectionRevoked({
        employeeId: connection.employeeId,
        provider: connection.provider,
        memberUrn: connection.memberUrn,
        revokedAt: time:utcToString(revokedAt)
    });

# `ConnectionRemoved` after Remove Connection.
#
# + connection - The connection
# + removedAt - Removal time
# + return - Outbox row
public isolated function connectionRemovedEvent(LinkedInConnection connection, time:Utc removedAt)
        returns events:OutboxEvent =>
    events:newConnectionRemoved({
        employeeId: connection.employeeId,
        provider: connection.provider,
        memberUrn: connection.memberUrn,
        removedAt: time:utcToString(removedAt)
    });
