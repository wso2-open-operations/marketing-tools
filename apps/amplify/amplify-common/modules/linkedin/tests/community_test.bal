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

// Community Management parsing (pure) and the wire contract against a local stub (port 18214).

import ballerina/http;
import ballerina/test;

const int COMMUNITY_STUB_PORT = 18214;
const string PAGE_TOKEN = "page-token";
const string ORG = "urn:li:organization:1477";

isolated string lastCommunityPath = "";

listener http:Listener communityListener = new (COMMUNITY_STUB_PORT);

service / on communityListener {
    resource function get rest/reactions/[string key](http:Request req, @http:Header string Authorization)
            returns json|http:Unauthorized|http:TooManyRequests {
        lock {
            lastCommunityPath = req.rawPath;
        }
        if Authorization == "Bearer slow-down" {
            return <http:TooManyRequests>{body: {status: 429, serviceErrorCode: 101}};
        }
        if Authorization != "Bearer " + PAGE_TOKEN || req.getHeader("LinkedIn-Version") is error
                || req.getHeader("X-Restli-Protocol-Version") != "2.0.0" {
            return <http:Unauthorized>{body: {status: 401}};
        }
        return {
            paging: {'start: 0, count: 10},
            elements: [{id: "urn:li:reaction:(urn:li:person:abc,urn:li:share:1)", reactionType: "LIKE",
                    root: "urn:li:share:1", created: {actor: "urn:li:person:abc", time: 1790272252945}}]
        };
    }

    resource function get rest/socialActions/[string urn]/comments(http:Request req) returns json {
        lock {
            lastCommunityPath = req.rawPath;
        }
        return {elements: []};
    }

    resource function get rest/organizationalEntityNotifications(http:Request req) returns json {
        lock {
            lastCommunityPath = req.rawPath;
        }
        return {elements: []};
    }

    resource function get rest/memberCreatorPostAnalytics(http:Request req, @http:Header string Authorization)
            returns json|http:Unauthorized|http:Forbidden {
        lock {
            lastCommunityPath = req.rawPath;
        }
        if Authorization == "Bearer not-mine" {
            return <http:Forbidden>{body: {status: 403}};
        }
        if Authorization != "Bearer reach-token" {
            return <http:Unauthorized>{body: {status: 401}};
        }
        string queryType = req.getQueryParamValue("queryType") ?: "";
        return {elements: [{count: queryType == "IMPRESSION" ? 1200 : 640,
            metricType: {"com.linkedin.adsexternalapi.memberanalytics.v1.CreatorPostAnalyticsMetricTypeV1": queryType},
            targetEntity: {share: "urn:li:share:7"}}]};
    }

    resource function get rest/organizationAcls(http:Request req) returns json =>
        {elements: [{role: "ADMINISTRATOR", state: "APPROVED", organization: ORG, roleAssignee: "urn:li:person:abc"}]};

    resource function post oauth/v2/accessToken(http:Request req) returns json|http:BadRequest|error {
        map<string> form = check req.getFormParams();
        if form["grant_type"] == "refresh_token" && form["refresh_token"] == "r-1" && form["client_secret"] == "page-secret" {
            return {access_token: "a-2", expires_in: 5184000, refresh_token: "r-1", refresh_token_expires_in: 31536000,
                scope: "r_organization_social_feed,rw_organization_admin"};
        }
        if form["grant_type"] == "authorization_code" && form["code"] == "reach-code"
                && form["redirect_uri"] == "https://one.wso2.com/amplify/connect/callback" {
            return {access_token: "reach-token", expires_in: 5184000, scope: "r_member_postAnalytics"};
        }
        if form["grant_type"] == "authorization_code" && form["code"] == "page-code" {
            return {access_token: "a-1", expires_in: 5184000, refresh_token: "r-1", refresh_token_expires_in: 31536000,
                scope: "r_organization_social_feed,rw_organization_admin"};
        }
        return <http:BadRequest>{body: {'error: "invalid_request"}};
    }
}

function community() returns CommunityAdapter|error => new ({
    apiBaseUrl: string `http://localhost:${COMMUNITY_STUB_PORT}`,
    authBaseUrl: string `http://localhost:${COMMUNITY_STUB_PORT}`,
    clientId: "page-client",
    clientSecret: "page-secret",
    redirectUri: "https://one.wso2.com/admin/page-callback"
});

function lastPath() returns string {
    lock {
        return lastCommunityPath;
    }
}

@test:Config {}
function testReactionsParse() returns error? {
    ReactionPage page = check parseReactions({
        paging: {'start: 0, count: 10, total: 3},
        elements: [
            {id: "urn:li:reaction:(urn:li:person:abc,urn:li:ugcPost:75)", reactionType: "PRAISE",
                root: "urn:li:ugcPost:75", created: {actor: "urn:li:person:abc", time: 1790272252945}},
            // No root: taken from the reaction id.
            {id: "urn:li:reaction:(urn:li:organization:2414183,urn:li:ugcPost:75)", reactionType: "LIKE",
                created: {actor: "urn:li:organization:2414183", impersonator: "urn:li:person:x", time: 1}},
            // No time: counted, left out.
            {id: "urn:li:reaction:(urn:li:person:zzz,urn:li:ugcPost:75)", created: {actor: "urn:li:person:zzz"}}
        ]
    });
    test:assertEquals(page.fetched, 3);
    test:assertEquals(page.items.length(), 2);
    test:assertEquals(page.items[0], {actorUrn: "urn:li:person:abc", rootUrn: "urn:li:ugcPost:75",
        reactionType: "PRAISE", createdAtMs: 1790272252945});
    test:assertEquals(page.items[1].rootUrn, "urn:li:ugcPost:75");
    test:assertFalse(isPersonUrn(page.items[1].actorUrn), "a page's own reaction is not a member");
    test:assertEquals((check parseReactions({paging: {'start: 0}})).fetched, 0, "no elements = an empty page");
    test:assertTrue(parseReactions([1, 2]) is ProviderError, "not a collection");
}

@test:Config {}
function testCommentsParseWithoutText() returns error? {
    CommentPage page = check parseComments({
        elements: [
            {actor: "urn:li:person:abc", agent: "urn:li:person:abc", id: "7508993488256962561",
                commentUrn: "urn:li:comment:(urn:li:ugcPost:75,7508993488256962561)",
                created: {actor: "urn:li:person:abc", time: 1790283557954}, 'object: "urn:li:ugcPost:75",
                message: {attributes: [], text: "secret words"}},
            // No commentUrn: built from object and id.
            {actor: "urn:li:person:def", id: "42", 'object: "urn:li:share:9", created: {time: 5}}
        ]
    });
    test:assertEquals(page.fetched, 2);
    test:assertEquals(page.items[0], {actorUrn: "urn:li:person:abc",
        commentUrn: "urn:li:comment:(urn:li:ugcPost:75,7508993488256962561)", objectUrn: "urn:li:ugcPost:75",
        createdAtMs: 1790283557954});
    test:assertEquals(page.items[1].commentUrn, "urn:li:comment:(urn:li:share:9,42)");
    test:assertFalse(page.items.toString().includes("secret words"), "comment text is never kept");
}

@test:Config {}
function testShareNotificationsParse() returns error? {
    NotificationPage page = check parseShareNotifications({
        elements: [
            {action: "SHARE", generatedActivity: "urn:li:activity:900", sourcePost: "urn:li:share:1",
                lastModifiedAt: 1593021467000, organizationalEntity: ORG,
                decoratedGeneratedActivity: {share: {owner: "urn:li:person:abc", entity: "urn:li:share:901",
                        text: "My thoughts"}}},
            {action: "SHARE", generatedActivity: "urn:li:activity:902", sourcePost: "urn:li:share:1",
                lastModifiedAt: 1593021468000, decoratedGeneratedActivity: {share: {owner: "urn:li:person:def", text: "  "}}},
            // No source post: left out.
            {action: "SHARE_MENTION", generatedActivity: "urn:li:activity:903", lastModifiedAt: 1,
                decoratedGeneratedActivity: {share: {owner: "urn:li:person:x"}}}
        ]
    });
    test:assertEquals(page.fetched, 3);
    test:assertEquals(page.items.length(), 2);
    test:assertEquals(page.items[0], {action: "SHARE", activityUrn: "urn:li:activity:900", actorUrn: "urn:li:person:abc",
        hasCommentary: true, sourcePostUrn: "urn:li:share:1", occurredAtMs: 1593021467000});
    test:assertFalse(page.items[1].hasCommentary, "blank text is no commentary");
    test:assertFalse(page.items.toString().includes("My thoughts"), "the text is reduced to a flag");
}

@test:Config {}
function testAdminAcl() returns error? {
    test:assertTrue(check isApprovedAdmin({elements: [{role: "ADMINISTRATOR", state: "APPROVED", organization: ORG}]}, ORG));
    test:assertTrue(check isApprovedAdmin({elements: [{role: "ADMINISTRATOR", state: "APPROVED",
        organizationTarget: ORG}]}, ORG), "the older field name");
    test:assertFalse(check isApprovedAdmin({elements: [{role: "ADMINISTRATOR", state: "REQUESTED", organization: ORG}]}, ORG));
    test:assertFalse(check isApprovedAdmin({elements: [{role: "CONTENT_ADMINISTRATOR", state: "APPROVED",
        organization: ORG}]}, ORG));
    test:assertFalse(check isApprovedAdmin({elements: [{role: "ADMINISTRATOR", state: "APPROVED",
        organization: "urn:li:organization:9"}]}, ORG), "another page");
    test:assertFalse(check isApprovedAdmin({elements: []}, ORG));
}

@test:Config {}
function testCommunityWireContract() returns error? {
    CommunityAdapter adapter = check community();
    string url = check adapter.authorizationUrl("s-123");
    test:assertTrue(url.includes("scope=r_organization_social_feed%20rw_organization_admin")
            || url.includes("scope=r_organization_social_feed+rw_organization_admin"), url);
    test:assertFalse(url.includes("w_member_social"), "page scopes only");

    ReactionPage reactions = check adapter.listReactions(PAGE_TOKEN, "urn:li:share:1", 0, 500);
    test:assertEquals(reactions.items.length(), 1);
    test:assertTrue(lastPath().startsWith("/rest/reactions/(entity:urn%3Ali%3Ashare%3A1)?q=entity"), lastPath());
    test:assertTrue(lastPath().includes("count=100"), "page size capped");

    _ = check adapter.listComments(PAGE_TOKEN, "urn:li:ugcPost:75", 10, 50);
    test:assertEquals(lastPath(), "/rest/socialActions/urn%3Ali%3AugcPost%3A75/comments?start=10&count=50");

    _ = check adapter.listShareNotifications(PAGE_TOKEN, ORG, 1000, 2000);
    test:assertEquals(lastPath(), "/rest/organizationalEntityNotifications?q=criteria&actions=List(SHARE,SHARE_MENTION)"
        + "&organizationalEntity=urn%3Ali%3Aorganization%3A1477&timeRange=(start:1000,end:2000)&start=0&count=50");

    test:assertTrue(check adapter.isAdmin(PAGE_TOKEN, ORG));
    test:assertFalse(check adapter.isAdmin(PAGE_TOKEN, "urn:li:organization:2"));

    ReactionPage|ProviderError limited = adapter.listReactions("slow-down", "urn:li:share:1", 0, 10);
    test:assertTrue(limited is ProviderError && limited.detail().code == RATE_LIMITED);

    TokenGrant grant = check adapter.exchangeCode("page-code");
    test:assertEquals(grant.refreshToken, "r-1");
    test:assertEquals(grant.refreshExpiresInSeconds, 31536000);
    TokenGrant refreshed = check adapter.refresh("r-1");
    test:assertEquals(refreshed.accessToken, "a-2");
    test:assertTrue(adapter.refresh("unknown") is ProviderError);
}
