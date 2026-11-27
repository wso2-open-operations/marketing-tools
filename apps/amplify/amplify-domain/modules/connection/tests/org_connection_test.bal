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

const string PAGE_URN = "urn:li:organization:1477";

function pageCipher() returns crypto:TokenCipher|error =>
    new ([check crypto:keyFromBase64("k1", "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")], "k1");

@test:Config {}
function testOrgConnectRefreshRevoke() returns error? {
    crypto:TokenCipher cipher = check pageCipher();
    StoredToken access = check sealOrgToken(cipher, "a-1", PAGE_URN, "ACCESS", time:utcAddSeconds(T0, 5184000), T0);
    StoredToken refresh = check sealOrgToken(cipher, "r-1", PAGE_URN, "REFRESH", time:utcAddSeconds(T0, 31536000), T0);
    test:assertEquals(access.ownerType, "ORG");
    test:assertEquals(access.ownerId, PAGE_URN);
    test:assertEquals(check openToken(cipher, access), "a-1", "the AAD binds the page URN");

    OrgConnectionChange connected = connectOrg((), {orgUrn: PAGE_URN, connectedBy: "admin-1",
        scopes: ["r_organization_social_feed", "rw_organization_admin"], access, refresh}, T0);
    OrgConnection c = connected.connection;
    test:assertEquals(c.version, 1);
    test:assertEquals(connected.tokensToInsert.length(), 2);
    test:assertEquals(connected.tokensToDelete.length(), 0);
    test:assertEquals(c.providerApi, types:COMMUNITY_MANAGEMENT);
    test:assertEquals(orgStatus(c, T0), PAGE_CONNECTED);
    test:assertFalse(needsRefresh(c, T0), "60 days left");
    test:assertTrue(needsRefresh(c, time:utcAddSeconds(T0, 5184000 - 3600)), "inside the lead time");

    StoredToken access2 = check sealOrgToken(cipher, "a-2", PAGE_URN, "ACCESS", time:utcAddSeconds(T0, 10000000), T0);
    OrgConnectionChange refreshed = check refreshOrg(c, access2, ());
    test:assertEquals(refreshed.tokensToDelete, [tokenRef(access)], "only the old access row goes");
    test:assertEquals(refreshed.connection.refreshToken, tokenRef(refresh), "the refresh row stays");
    test:assertEquals(refreshed.auditAction, ORG_TOKEN_REFRESHED);

    OrgConnectionChange revoked = revokeOrg(refreshed.connection, T0);
    test:assertEquals(revoked.connection.accessToken, ());
    test:assertEquals(revoked.connection.refreshToken, ());
    test:assertEquals(revoked.tokensToDelete.length(), 2);
    test:assertEquals(orgStatus(revoked.connection, T0), PAGE_REVOKED);
    test:assertTrue(refreshOrg(revoked.connection, access2, ()) is types:DomainError, "no refresh after a disconnect");

    OrgConnectionChange again = connectOrg(revoked.connection, {orgUrn: PAGE_URN, connectedBy: "admin-2", scopes: [],
        access: access2}, T0);
    test:assertEquals(again.connection.version, revoked.connection.version + 1);
    test:assertEquals(again.connection.revokedAt, ());

    // Expired access with no refresh token: EXPIRED.
    test:assertEquals(orgStatus(again.connection, time:utcAddSeconds(T0, 20000000)), PAGE_EXPIRED);
}

@test:Config {}
function testPageOAuthState() returns error? {
    OAuthState s = check newPageOAuthState("admin-1", T0);
    test:assertEquals(s.providerApi, types:COMMUNITY_MANAGEMENT);
    test:assertEquals((check newOAuthState("emp-1", (), (), T0)).providerApi, types:SHARE_ON_LINKEDIN);
}
