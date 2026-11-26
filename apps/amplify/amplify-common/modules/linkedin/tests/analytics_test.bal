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


// Member post analytics: the Reach authorization URL, the code exchange on the member redirect, the finder's wire
// shape and the parsing (stub on the community port, 18214).

import ballerina/test;

@test:Config {}
function testReachAuthorizationUrlAsksOnlyForPostAnalytics() returns error? {
    CommunityAdapter c = check community();
    string url = check c.memberAuthorizationUrl("s".padEnd(64, "x"), "https://one.wso2.com/amplify/connect/callback");
    test:assertTrue(url.includes("scope=r_member_postAnalytics"), url);
    test:assertFalse(url.includes("rw_organization_admin"), "no page scopes on the Reach connection");
    test:assertTrue(url.includes("redirect_uri=https%3A%2F%2Fone.wso2.com%2Famplify%2Fconnect%2Fcallback"), url);
    test:assertTrue(url.includes("client_id=page-client"), "the Community Management app");
}

@test:Config {}
function testReachCodeExchangeCarriesTheMemberRedirect() returns error? {
    CommunityAdapter c = check community();
    TokenGrant grant = check c.exchangeMemberCode("reach-code", "https://one.wso2.com/amplify/connect/callback");
    test:assertEquals(grant.accessToken, "reach-token");
    test:assertEquals(grant.scopes, ["r_member_postAnalytics"]);
    test:assertTrue(c.exchangeMemberCode("reach-code", "https://one.wso2.com/admin/page-callback") is ProviderError,
            "the page redirect is not the member one");
}

@test:Config {}
function testMemberPostMetricWire() returns error? {
    CommunityAdapter c = check community();
    test:assertEquals(check c.memberPostMetric("reach-token", "urn:li:share:7", IMPRESSION), 1200);
    test:assertEquals(lastPath(), "/rest/memberCreatorPostAnalytics?q=entity&entity=(share:urn%3Ali%3Ashare%3A7)"
        + "&queryType=IMPRESSION&aggregation=TOTAL");
    test:assertEquals(check c.memberPostMetric("reach-token", "urn:li:ugcPost:9", MEMBERS_REACHED), 640);
    test:assertTrue(lastPath().includes("entity=(ugc:urn%3Ali%3AugcPost%3A9)"), lastPath());
    int|ProviderError forbidden = c.memberPostMetric("not-mine", "urn:li:share:7", IMPRESSION);
    test:assertTrue(forbidden is ProviderError && forbidden.detail().code == FORBIDDEN, "another member's post");
    int|ProviderError expired = c.memberPostMetric("old", "urn:li:share:7", IMPRESSION);
    test:assertTrue(expired is ProviderError && expired.detail().code == UNAUTHORIZED);
    int|ProviderError wrongKind = c.memberPostMetric("reach-token", "urn:li:organization:1", IMPRESSION);
    test:assertTrue(wrongKind is ProviderError && wrongKind.detail().code == REJECTED, "only share and ugcPost URNs");
}

@test:Config {}
function testMetricTotalParse() returns error? {
    test:assertEquals(check parseMetricTotal({elements: [{count: 5}, {count: 7}]}), 12);
    test:assertEquals(check parseMetricTotal({elements: []}), 0, "no elements = 0");
    test:assertEquals(check parseMetricTotal({paging: {}}), 0);
    test:assertTrue(parseMetricTotal({elements: [{count: -1}]}) is ProviderError);
    test:assertTrue(parseMetricTotal({elements: [{metricType: "IMPRESSION"}]}) is ProviderError);
    test:assertTrue(parseMetricTotal("x") is ProviderError);
}

@test:Config {}
function testCommunityAdapterIsAMemberAnalyticsPort() returns error? {
    MemberAnalyticsPort port = check community();
    test:assertTrue(port is CommunityAdapter);
}
