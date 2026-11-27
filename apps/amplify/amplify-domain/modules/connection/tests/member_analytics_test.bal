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


import amplify_common.crypto;
import amplify_common.types;

import ballerina/test;
import ballerina/time;

@test:Config {}
function testReachConnectRefreshAndStatus() returns error? {
    crypto:TokenCipher cipher = check pageCipher();
    StoredToken access = check sealReachToken(cipher, "a-1", "emp-1", "ACCESS", time:utcAddSeconds(T0, 5184000), T0);
    StoredToken refresh = check sealReachToken(cipher, "r-1", "emp-1", "REFRESH", time:utcAddSeconds(T0, 31536000), T0);
    test:assertEquals(access.ownerType, "MEMBER_ANALYTICS");
    test:assertEquals(access.ownerId, "emp-1");
    test:assertEquals(check openToken(cipher, access), "a-1");

    ReachChange connected = connectReach((), "emp-1", ["r_member_postAnalytics"], access, refresh, T0);
    ReachConnection c = connected.connection;
    test:assertEquals(c.version, 1);
    test:assertEquals(connected.tokensToInsert.length(), 2);
    test:assertEquals(connected.tokensToDelete.length(), 0);
    test:assertEquals(connected.auditAction, REACH_CONNECTED_AUDIT);
    test:assertEquals(reachStatus(c, T0), REACH_CONNECTED);
    test:assertFalse(needsReachRefresh(c, T0));
    test:assertTrue(needsReachRefresh(c, time:utcAddSeconds(T0, 5184000 - 3600)), "inside the 7-day lead");

    StoredToken access2 = check sealReachToken(cipher, "a-2", "emp-1", "ACCESS", time:utcAddSeconds(T0, 9000000), T0);
    ReachChange renewed = refreshReach(c, access2, ());
    test:assertEquals(renewed.connection.version, 2);
    test:assertEquals(renewed.tokensToDelete, [c.accessToken], "only the old access row goes");
    test:assertEquals(renewed.connection.refreshToken, c.refreshToken);
    test:assertEquals(renewed.auditAction, REACH_TOKEN_REFRESHED);

    StoredToken refresh2 = check sealReachToken(cipher, "r-2", "emp-1", "REFRESH", time:utcAddSeconds(T0, 40000000), T0);
    ReachChange both = refreshReach(c, access2, refresh2);
    test:assertEquals(both.tokensToDelete.length(), 2);
    test:assertEquals(both.connection.refreshExpiresAt, refresh2.expiresAt);

    ReachChange again = connectReach(c, "emp-1", ["r_member_postAnalytics"], access2, (), T0);
    test:assertEquals(again.connection.version, 2);
    test:assertEquals(again.tokensToDelete, reachTokenRefs(c), "a reconnect replaces both rows");
    test:assertEquals(reachStatus(again.connection, time:utcAddSeconds(T0, 9000001)), REACH_EXPIRED,
            "expired with no refresh token");
    test:assertEquals(reachStatus(c, time:utcAddSeconds(T0, 6000000)), REACH_CONNECTED, "the refresh token renews it");
}

@test:Config {}
function testReachOAuthStateIsItsOwnFlow() returns error? {
    OAuthState s = check newReachOAuthState("emp-1", T0);
    test:assertEquals(s.purpose, REACH);
    test:assertEquals(s.providerApi, types:COMMUNITY_MANAGEMENT);
    test:assertTrue(s.state.startsWith(REACH_STATE_PREFIX));
    test:assertTrue(s.state.length() <= 128);
    test:assertEquals((check newPageOAuthState("admin-1", T0)).purpose, PAGE);
    test:assertEquals((check newOAuthState("emp-1", (), (), T0)).purpose, CONNECT);
}
