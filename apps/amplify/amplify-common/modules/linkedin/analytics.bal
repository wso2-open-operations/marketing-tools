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


// Member post analytics (#1781): an employee's consent, through the Community Management app, to Amplify reading
// the reach of their own posts (scope `r_member_postAnalytics`). `CommunityAdapter` implements the port; the shape
// follows LinkedIn's Member Post Analytics documentation (`memberCreatorPostAnalytics`, finder `entity`, `TOTAL`
// aggregation). Only counts are read; nothing about the people reached.

import ballerina/http;

# Scopes the Reach connection asks for, and only these.
public final string[] & readonly REACH_SCOPES = ["r_member_postAnalytics"];

# Impressions: how many times the post was shown.
public const IMPRESSION = "IMPRESSION";
# Unique members the post reached (LinkedIn supports it with `TOTAL` aggregation only).
public const MEMBERS_REACHED = "MEMBERS_REACHED";

# The post metrics Amplify reads.
public type AnalyticsMetric IMPRESSION|MEMBERS_REACHED;

# Port for an employee's Reach connection and their post analytics. Structural: `CommunityAdapter` satisfies it,
# tests plug in fakes.
public type MemberAnalyticsPort isolated object {
    # Authorization URL for the Reach connection (`REACH_SCOPES` only).
    #
    # + state - Single-use state
    # + redirectUri - Redirect URI registered on the app
    # + return - The URL
    public isolated function memberAuthorizationUrl(string state, string redirectUri) returns string|ProviderError;

    # Exchanges the code.
    #
    # + code - Code from the redirect
    # + redirectUri - Redirect URI of the authorize request
    # + return - The grant, or a provider error
    public isolated function exchangeMemberCode(string code, string redirectUri) returns TokenGrant|ProviderError;

    # Gets a new access token with the refresh token.
    #
    # + refreshToken - Refresh token
    # + return - The grant, or a provider error
    public isolated function refresh(string refreshToken) returns TokenGrant|ProviderError;

    # Revokes a token.
    #
    # + token - Token
    # + return - `()` once LinkedIn confirms, or a provider error
    public isolated function revokeToken(string token) returns ProviderError?;

    # One lifetime metric of the member's own post.
    #
    # + accessToken - Reach token
    # + postUrn - Post URN
    # + metric - Metric
    # + return - The count, or a provider error
    public isolated function memberPostMetric(string accessToken, string postUrn, AnalyticsMetric metric)
            returns int|ProviderError;
};

# The `entity` value of the analytics finder: `(share:{urn})` or `(ugc:{urn})`, the URN Rest.li-encoded.
#
# + postUrn - Post URN
# + return - The value, or `REJECTED` for any other URN
isolated function analyticsEntity(string postUrn) returns string|ProviderError {
    string kind;
    if postUrn.startsWith("urn:li:share:") {
        kind = "share";
    } else if postUrn.startsWith("urn:li:ugcPost:") {
        kind = "ugc";
    } else {
        return providerError(REJECTED, "Post analytics need a share or ugcPost URN", (), (), false);
    }
    return string `(${kind}:${check encodeUrn(postUrn)})`;
}

# The total of an analytics response: the sum of the elements' `count` (one element with `TOTAL`; none = 0).
#
# + body - Response body
# + return - The count, or `BAD_RESPONSE`
isolated function parseMetricTotal(json body) returns int|ProviderError {
    json[] elements = check elementsOf(body, "member post analytics");
    int total = 0;
    foreach json element in elements {
        json count = element is map<json> ? element["count"] : ();
        if count !is int || count < 0 {
            return providerError(BAD_RESPONSE, "LinkedIn member post analytics returned an unexpected element",
                    http:STATUS_OK, (), false);
        }
        total += count;
    }
    return total;
}
