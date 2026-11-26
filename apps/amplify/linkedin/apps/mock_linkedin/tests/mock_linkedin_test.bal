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
import ballerina/http;
import ballerina/test;
import ballerina/url;
import ballerina/uuid;

const TEST_CLIENT_ID = "test-client-id";
const TEST_CLIENT_SECRET = "test-client-secret";
const TEST_REDIRECT_URI = "http://localhost:3000/callback";
const TEST_VERSION = "202610";
const TEST_AUTHOR = "urn:li:person:782bbtaQ";
# Same value as `mockAdminKey` in tests/Config.toml.
const TEST_ADMIN_KEY = "test-admin-key-for-mock-linkedin-0123456789";
# Free port for listeners these tests create themselves; the package's own listeners use 19090/19091.
const TEST_LISTENER_PORT = 19190;

final http:Client apiClient = check new ("http://localhost:19090");
final http:Client wwwClient = check new ("http://localhost:19091");

@test:BeforeEach
function resetState() returns error? {
    http:Response res = check apiClient->post("/mock/reset", (), adminHeaders());
    test:assertEquals(res.statusCode, http:STATUS_NO_CONTENT);
}

// OAuth 2.0

@test:Config
function testAuthorizationRedirectsWithCodeAndState() returns error? {
    http:Response res = check authorizeRequest("openid profile w_member_social", "xyz123");
    test:assertEquals(res.statusCode, http:STATUS_FOUND);
    string location = check res.getHeader(HEADER_LOCATION);
    test:assertTrue(location.startsWith(TEST_REDIRECT_URI + "?code=AQ"));
    test:assertTrue(location.endsWith("&state=xyz123"));
}

@test:Config
function testAuthorizationRejectsUnknownRedirectUri() returns error? {
    http:Response res = check wwwClient->get(string `/oauth/v2/authorization?response_type=code&client_id=${TEST_CLIENT_ID}&redirect_uri=http%3A%2F%2Fevil.example.com&scope=openid`);
    test:assertEquals(res.statusCode, http:STATUS_BAD_REQUEST);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.'error, OAUTH_INVALID_REDIRECT_URI);
}

@test:Config
function testAuthorizationRejectsUnknownClient() returns error? {
    http:Response res = check wwwClient->get(string `/oauth/v2/authorization?response_type=code&client_id=other&redirect_uri=${TEST_REDIRECT_URI}&scope=openid`);
    test:assertEquals(res.statusCode, http:STATUS_BAD_REQUEST);
}

@test:Config
function testAuthorizationRejectsUnsupportedScope() returns error? {
    http:Response res = check authorizeRequest("w_member_social r_member_social", ());
    test:assertEquals(res.statusCode, http:STATUS_FOUND);
    string location = check res.getHeader(HEADER_LOCATION);
    test:assertTrue(location.includes("error=unauthorized_scope_error"));
    test:assertFalse(location.includes("code="));
}

@test:Config
function testAuthorizationConsentDenied() returns error? {
    http:Response res = check wwwClient->get(string `/oauth/v2/authorization?response_type=code&client_id=${TEST_CLIENT_ID}&redirect_uri=${TEST_REDIRECT_URI}&scope=w_member_social&mock_consent=deny`);
    string location = check res.getHeader(HEADER_LOCATION);
    test:assertTrue(location.includes("error=user_cancelled_authorize"));
}

@test:Config
function testTokenExchangeReturnsTokenAndCodeIsSingleUse() returns error? {
    string code = check authorizationCode("openid profile w_member_social");
    http:Response first = check tokenRequest(code, TEST_CLIENT_SECRET);
    test:assertEquals(first.statusCode, http:STATUS_OK);
    json body = check first.getJsonPayload();
    test:assertEquals(check body.token_type, TOKEN_TYPE_BEARER);
    test:assertEquals(check body.expires_in, 5184000);
    test:assertEquals(check body.scope, "openid,profile,w_member_social");

    http:Response second = check tokenRequest(code, TEST_CLIENT_SECRET);
    test:assertEquals(second.statusCode, http:STATUS_BAD_REQUEST);
}

@test:Config
function testTokenExchangeRejectsRedirectUriMismatch() returns error? {
    string code = check authorizationCode("w_member_social");
    string form = string `grant_type=authorization_code&code=${code}&redirect_uri=http://localhost:3000/other&client_id=${TEST_CLIENT_ID}&client_secret=${TEST_CLIENT_SECRET}`;
    http:Response res = check wwwClient->post("/oauth/v2/accessToken", form, mediaType = "application/x-www-form-urlencoded");
    test:assertEquals(res.statusCode, http:STATUS_BAD_REQUEST);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.'error, OAUTH_INVALID_REQUEST);
}

@test:Config
function testTokenExchangeRejectsWrongSecret() returns error? {
    string code = check authorizationCode("w_member_social");
    http:Response res = check tokenRequest(code, "wrong-secret");
    test:assertEquals(res.statusCode, http:STATUS_UNAUTHORIZED);
}

@test:Config
function testNewScopeSetRevokesEarlierToken() returns error? {
    string oldToken = check accessToken("w_member_social");
    _ = check accessToken("openid profile w_member_social");
    http:Response res = check createPost(oldToken, uniqueText());
    test:assertEquals(res.statusCode, http:STATUS_UNAUTHORIZED);
}

// Identity

@test:Config
function testUserInfoReturnsMemberWithEmail() returns error? {
    string token = check accessToken("openid profile email");
    http:Response res = check apiClient->get("/v2/userinfo", bearer(token));
    test:assertEquals(res.statusCode, http:STATUS_OK);
    UserInfo info = check (check res.getJsonPayload()).cloneWithType();
    test:assertEquals(info.sub, "782bbtaQ");
    test:assertEquals(info.email, "avery.mock@example.com");
}

@test:Config
function testUserInfoRequiresProfileScope() returns error? {
    string token = check accessToken("w_member_social");
    http:Response res = check apiClient->get("/v2/userinfo", bearer(token));
    test:assertEquals(res.statusCode, http:STATUS_FORBIDDEN);
}

// Posts

@test:Config
function testCreatePostReturnsShareUrn() returns error? {
    string token = check accessToken("openid profile w_member_social");
    http:Response res = check createPost(token, uniqueText());
    test:assertEquals(res.statusCode, http:STATUS_CREATED);
    string urn = check res.getHeader(HEADER_RESTLI_ID);
    test:assertTrue(isPostUrn(urn));
    test:assertTrue((check res.getHeader(HEADER_LI_UUID)).length() > 0);
}

@test:Config
function testCreatePostWithoutTokenIsUnauthorized() returns error? {
    http:Response res = check apiClient->post("/rest/posts", textPost(uniqueText()), restliHeaders());
    test:assertEquals(res.statusCode, http:STATUS_UNAUTHORIZED);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.serviceErrorCode, SERVICE_ERROR_INVALID_TOKEN);
}

@test:Config
function testCreatePostWithoutWriteScopeIsForbidden() returns error? {
    string token = check accessToken("openid profile");
    http:Response res = check createPost(token, uniqueText());
    test:assertEquals(res.statusCode, http:STATUS_FORBIDDEN);
}

@test:Config
function testCreatePostAsAnotherMemberIsForbidden() returns error? {
    string token = check accessToken("w_member_social");
    json post = textPost(uniqueText(), author = "urn:li:person:someoneElse");
    http:Response res = check apiClient->post("/rest/posts", post, restliHeaders(token));
    test:assertEquals(res.statusCode, http:STATUS_FORBIDDEN);
}

@test:Config
function testCreatePostWithoutVersionHeaderIsBadRequest() returns error? {
    string token = check accessToken("w_member_social");
    map<string> headers = {
        [HEADER_AUTHORIZATION]: BEARER_PREFIX + token,
        [HEADER_RESTLI_PROTOCOL_VERSION]: RESTLI_PROTOCOL_VERSION
    };
    http:Response res = check apiClient->post("/rest/posts", textPost(uniqueText()), headers);
    test:assertEquals(res.statusCode, http:STATUS_BAD_REQUEST);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.message, MSG_VERSION_MISSING);
}

@test:Config
function testCreatePostWithBadPayloadIsBadRequest() returns error? {
    string token = check accessToken("w_member_social");
    http:Response res = check apiClient->post("/rest/posts", {author: TEST_AUTHOR}, restliHeaders(token));
    test:assertEquals(res.statusCode, http:STATUS_BAD_REQUEST);
    json body = check res.getJsonPayload();
    test:assertEquals(check body.status, http:STATUS_BAD_REQUEST);
}

// RC-03: the real Posts API needs `content.article.title`; so does the mock.
@test:Config
function testArticlePostNeedsATitle() returns error? {
    string token = check accessToken("w_member_social");
    map<json> post = <map<json>>textPost(uniqueText());
    post["content"] = {article: {'source: "https://choreolabs.com/blog/x"}};
    http:Response untitled = check apiClient->post("/rest/posts", post, restliHeaders(token));
    test:assertEquals(untitled.statusCode, http:STATUS_BAD_REQUEST);
    test:assertEquals(check (check untitled.getJsonPayload()).message, "content.article.title is required");
    post["content"] = {article: {'source: "https://choreolabs.com/blog/x", title: "  "}};
    http:Response blank = check apiClient->post("/rest/posts", post, restliHeaders(token));
    test:assertEquals(blank.statusCode, http:STATUS_BAD_REQUEST);
    post["commentary"] = uniqueText();
    post["content"] = {article: {'source: "https://choreolabs.com/blog/x", title: "Choreo Labs blog"}};
    http:Response titled = check apiClient->post("/rest/posts", post, restliHeaders(token));
    test:assertEquals(titled.statusCode, http:STATUS_CREATED);
}

@test:Config
function testDuplicatePostIsUnprocessable() returns error? {
    string token = check accessToken("w_member_social");
    string text = uniqueText();
    http:Response first = check createPost(token, text);
    test:assertEquals(first.statusCode, http:STATUS_CREATED);
    http:Response second = check createPost(token, text);
    test:assertEquals(second.statusCode, http:STATUS_UNPROCESSABLE_ENTITY);
}

@test:Config
function testReshareOfExternalPost() returns error? {
    string token = check accessToken("w_member_social");
    json post = check textPost("Why this matters to us").mergeJson({
        reshareContext: {parent: "urn:li:share:6957408550713184256"}
    });
    http:Response res = check apiClient->post("/rest/posts", post, restliHeaders(token));
    test:assertEquals(res.statusCode, http:STATUS_CREATED);
}

@test:Config
function testReshareDisabledByAuthorIsForbidden() returns error? {
    string token = check accessToken("w_member_social");
    json original = textPost(uniqueText(), reshareDisabled = true);
    http:Response created = check apiClient->post("/rest/posts", original, restliHeaders(token));
    string parent = check created.getHeader(HEADER_RESTLI_ID);

    json reshare = check textPost(uniqueText()).mergeJson({reshareContext: {parent}});
    http:Response res = check apiClient->post("/rest/posts", reshare, restliHeaders(token));
    test:assertEquals(res.statusCode, http:STATUS_FORBIDDEN);
}

@test:Config
function testUpdateThenDeletePost() returns error? {
    string token = check accessToken("w_member_social");
    http:Response created = check createPost(token, uniqueText());
    string urn = check created.getHeader(HEADER_RESTLI_ID);
    string path = "/rest/posts/" + re `:`.replaceAll(urn, "%3A");

    map<string> updateHeaders = restliHeaders(token);
    updateHeaders["X-RestLi-Method"] = "PARTIAL_UPDATE";
    http:Response updated = check apiClient->post(path, {patch: {"$set": {commentary: "Updated text"}}}, updateHeaders);
    test:assertEquals(updated.statusCode, http:STATUS_NO_CONTENT);

    json stored = check apiClient->get("/mock/posts", adminHeaders());
    json[] posts = check stored.ensureType();
    test:assertEquals(check posts[0].commentary, "Updated text");

    http:Response deleted = check apiClient->delete(path, headers = restliHeaders(token));
    test:assertEquals(deleted.statusCode, http:STATUS_NO_CONTENT);
    http:Response deletedAgain = check apiClient->delete(path, headers = restliHeaders(token));
    test:assertEquals(deletedAgain.statusCode, http:STATUS_NO_CONTENT);

    http:Response missing = check apiClient->post(path, {patch: {"$set": {commentary: "Gone"}}}, updateHeaders);
    test:assertEquals(missing.statusCode, http:STATUS_NOT_FOUND);
}

@test:Config
function testCommentaryOverLimitIsBadRequest() returns error? {
    string token = check accessToken("w_member_social");
    string longText = "";
    foreach int _ in 0 ... MAX_COMMENTARY_LENGTH {
        longText += "a";
    }
    http:Response res = check createPost(token, longText);
    test:assertEquals(res.statusCode, http:STATUS_BAD_REQUEST);
}

@test:Config
function testLowercaseBearerSchemeIsAccepted() returns error? {
    string token = check accessToken("w_member_social");
    map<string> headers = restliHeaders();
    headers[HEADER_AUTHORIZATION] = "bearer " + token;
    http:Response res = check apiClient->post("/rest/posts", textPost(uniqueText()), headers);
    test:assertEquals(res.statusCode, http:STATUS_CREATED);
}

// Images

@test:Config
function testImageUploadThenPost() returns error? {
    string token = check accessToken("w_member_social");
    http:Response init = check apiClient->post("/rest/images?action=initializeUpload",
            {initializeUploadRequest: {owner: TEST_AUTHOR}}, restliHeaders(token));
    test:assertEquals(init.statusCode, http:STATUS_OK);
    InitializeImageUploadResponse upload = check (check init.getJsonPayload()).cloneWithType();
    string uploadUrl = upload.value?.uploadUrl ?: "";
    string image = upload.value?.image ?: "";
    test:assertTrue(image.startsWith(IMAGE_URN_PREFIX));

    json post = check textPost(uniqueText()).mergeJson({content: {media: {id: image, altText: "Alt"}}});
    http:Response early = check apiClient->post("/rest/posts", post, restliHeaders(token));
    test:assertEquals(early.statusCode, http:STATUS_BAD_REQUEST);

    http:Response put = check wwwClient->put(uploadUrl.substring("http://localhost:19091".length()),
            [1, 2, 3, 4], bearer(token));
    test:assertEquals(put.statusCode, http:STATUS_CREATED);

    http:Response res = check apiClient->post("/rest/posts", post, restliHeaders(token));
    test:assertEquals(res.statusCode, http:STATUS_CREATED);
}

// Legacy UGC

@test:Config
function testLegacyUgcShareThenDelete() returns error? {
    string token = check accessToken("w_member_social");
    json share = {
        author: TEST_AUTHOR,
        lifecycleState: "PUBLISHED",
        specificContent: {
            "com.linkedin.ugc.ShareContent": {
                shareCommentary: {text: uniqueText()},
                shareMediaCategory: "ARTICLE",
                media: [{status: "READY", originalUrl: "https://example.com/post", title: {text: "Post title"}}]
            }
        },
        visibility: {"com.linkedin.ugc.MemberNetworkVisibility": "PUBLIC"}
    };
    map<string> headers = {[HEADER_AUTHORIZATION]: BEARER_PREFIX + token, [HEADER_RESTLI_PROTOCOL_VERSION]: RESTLI_PROTOCOL_VERSION};
    http:Response res = check apiClient->post("/v2/ugcPosts", share, headers);
    test:assertEquals(res.statusCode, http:STATUS_CREATED);
    string urn = check res.getHeader(HEADER_RESTLI_ID);

    http:Response deleted = check apiClient->delete("/v2/ugcPosts/" + re `:`.replaceAll(urn, "%3A"), headers = headers);
    test:assertEquals(deleted.statusCode, http:STATUS_NO_CONTENT);
    json stored = check apiClient->get("/mock/posts", adminHeaders());
    json[] posts = check stored.ensureType();
    test:assertEquals(posts.length(), 0);
}

@test:Config
function testLegacyImageShareNeedsUploadedAsset() returns error? {
    string token = check accessToken("w_member_social");
    json share = {
        author: TEST_AUTHOR,
        lifecycleState: "PUBLISHED",
        specificContent: {
            "com.linkedin.ugc.ShareContent": {
                shareCommentary: {text: uniqueText()},
                shareMediaCategory: "IMAGE",
                media: [{status: "READY", media: "urn:li:digitalmediaAsset:NEVERUPLOADED"}]
            }
        },
        visibility: {"com.linkedin.ugc.MemberNetworkVisibility": "PUBLIC"}
    };
    map<string> headers = {[HEADER_AUTHORIZATION]: BEARER_PREFIX + token, [HEADER_RESTLI_PROTOCOL_VERSION]: RESTLI_PROTOCOL_VERSION};
    http:Response res = check apiClient->post("/v2/ugcPosts", share, headers);
    test:assertEquals(res.statusCode, http:STATUS_BAD_REQUEST);
}

@test:Config
function testUploadToUnknownUrlIsNotFound() returns error? {
    string token = check accessToken("w_member_social");
    http:Response res = check wwwClient->put("/dms-uploads/UNKNOWN/uploaded-image/0", [1, 2, 3], bearer(token));
    test:assertEquals(res.statusCode, http:STATUS_NOT_FOUND);
    test:assertTrue((check res.getHeader(HEADER_LI_UUID)).length() > 0);
}

@test:Config
function testLegacyAssetRegistration() returns error? {
    string token = check accessToken("w_member_social");
    json request = {
        registerUploadRequest: {
            recipes: ["urn:li:digitalmediaRecipe:feedshare-image"],
            owner: TEST_AUTHOR,
            serviceRelationships: [{relationshipType: "OWNER", identifier: "urn:li:userGeneratedContent"}]
        }
    };
    map<string> headers = {[HEADER_AUTHORIZATION]: BEARER_PREFIX + token, [HEADER_RESTLI_PROTOCOL_VERSION]: RESTLI_PROTOCOL_VERSION};
    http:Response res = check apiClient->post("/v2/assets?action=registerUpload", request, headers);
    test:assertEquals(res.statusCode, http:STATUS_OK);
    RegisterAssetUploadResponse body = check (check res.getJsonPayload()).cloneWithType();
    test:assertTrue((body.value?.asset ?: "").startsWith(ASSET_URN_PREFIX));
}

@test:Config
function testHealth() returns error? {
    map<string> status = check apiClient->get("/health");
    test:assertEquals(status["status"], "UP");
}

// Admin endpoints (local only)

@test:Config
function testAdminEndpointsRejectMissingAndWrongKey() returns error? {
    http:Response missing = check apiClient->get("/mock/posts");
    test:assertEquals(missing.statusCode, http:STATUS_UNAUTHORIZED);
    test:assertEquals(check (check missing.getJsonPayload()).message, MSG_ADMIN_UNAUTHORIZED);

    http:Response wrong = check apiClient->get("/mock/posts", {[ADMIN_KEY_HEADER]: "not-the-admin-key"});
    test:assertEquals(wrong.statusCode, http:STATUS_UNAUTHORIZED);

    http:Response resetWithoutKey = check apiClient->post("/mock/reset", ());
    test:assertEquals(resetWithoutKey.statusCode, http:STATUS_UNAUTHORIZED);
}

@test:Config
function testAdminEndpointsAcceptTheKey() returns error? {
    string token = check accessToken("w_member_social");
    http:Response created = check createPost(token, uniqueText());
    test:assertEquals(created.statusCode, http:STATUS_CREATED);

    http:Response posts = check apiClient->get("/mock/posts", adminHeaders());
    test:assertEquals(posts.statusCode, http:STATUS_OK);
    json[] stored = check (check posts.getJsonPayload()).ensureType();
    test:assertEquals(stored.length(), 1);

    http:Response reset = check apiClient->post("/mock/reset", (), adminHeaders());
    test:assertEquals(reset.statusCode, http:STATUS_NO_CONTENT);
}

@test:Config
function testAdminEndpointsAreAbsentWhenDisabled() returns error? {
    http:Listener probe = check new (TEST_LISTENER_PORT);
    http:Client probeClient = check new (string `http://localhost:${TEST_LISTENER_PORT}`);
    check attachMockAdmin(probe, false, TEST_ADMIN_KEY);
    check probe.start();
    http:Response res = check probeClient->get("/mock/posts", adminHeaders());
    test:assertEquals(res.statusCode, http:STATUS_NOT_FOUND);
    check probe.gracefulStop();
}

@test:Config
function testAdminEndpointsAreNotAttachedWithoutAKey() returns error? {
    http:Listener probe = check new (TEST_LISTENER_PORT);
    http:Client probeClient = check new (string `http://localhost:${TEST_LISTENER_PORT}`);
    check attachMockAdmin(probe, true, "");
    check probe.start();
    http:Response res = check probeClient->get("/mock/posts", adminHeaders());
    test:assertEquals(res.statusCode, http:STATUS_NOT_FOUND, "enabled with no key must not serve the endpoints");
    check probe.gracefulStop();
}

// Upload body limit

@test:Config
function testUploadOverTheBodyLimitIsRejected() returns error? {
    string token = check accessToken("w_member_social");
    http:Response init = check apiClient->post("/rest/images?action=initializeUpload",
            {initializeUploadRequest: {owner: TEST_AUTHOR}}, restliHeaders(token));
    InitializeImageUploadResponse upload = check (check init.getJsonPayload()).cloneWithType();
    string uploadUrl = upload.value?.uploadUrl ?: "";

    byte[] tooBig = [];
    int i = 0;
    while i <= maxUploadBytes {
        tooBig.push(1);
        i += 1;
    }
    http:Response res = check wwwClient->put(uploadUrl.substring("http://localhost:19091".length()), tooBig, bearer(token));
    test:assertEquals(res.statusCode, http:STATUS_PAYLOAD_TOO_LARGE);
}

// Helpers

function authorizeRequest(string scope, string? state) returns http:Response|error {
    string query = string `response_type=code&client_id=${TEST_CLIENT_ID}&redirect_uri=${TEST_REDIRECT_URI}&scope=${re ` `.replaceAll(scope, "%20")}`;
    if state is string {
        query += "&state=" + state;
    }
    return wwwClient->get("/oauth/v2/authorization?" + query);
}

function authorizationCode(string scope) returns string|error {
    http:Response res = check authorizeRequest(scope, ());
    string location = check res.getHeader(HEADER_LOCATION);
    string[] parts = re `code=`.split(location);
    return re `&`.split(parts[1])[0];
}

function tokenRequest(string code, string secret) returns http:Response|error {
    string form = string `grant_type=authorization_code&code=${code}&redirect_uri=${TEST_REDIRECT_URI}&client_id=${TEST_CLIENT_ID}&client_secret=${secret}`;
    return wwwClient->post("/oauth/v2/accessToken", form, mediaType = "application/x-www-form-urlencoded");
}

function accessToken(string scope) returns string|error {
    http:Response res = check tokenRequest(check authorizationCode(scope), TEST_CLIENT_SECRET);
    json body = check res.getJsonPayload();
    return (check body.access_token).ensureType();
}

function bearer(string token) returns map<string> => {[HEADER_AUTHORIZATION]: BEARER_PREFIX + token};

function adminHeaders() returns map<string> => {[ADMIN_KEY_HEADER]: TEST_ADMIN_KEY};

function restliHeaders(string? token = ()) returns map<string> {
    map<string> headers = {
        [HEADER_LINKEDIN_VERSION]: TEST_VERSION,
        [HEADER_RESTLI_PROTOCOL_VERSION]: RESTLI_PROTOCOL_VERSION
    };
    if token is string {
        headers[HEADER_AUTHORIZATION] = BEARER_PREFIX + token;
    }
    return headers;
}

function textPost(string commentary, string author = TEST_AUTHOR, boolean reshareDisabled = false) returns json => {
    author,
    commentary,
    visibility: "PUBLIC",
    distribution: {feedDistribution: "MAIN_FEED", targetEntities: [], thirdPartyDistributionChannels: []},
    lifecycleState: "PUBLISHED",
    isReshareDisabledByAuthor: reshareDisabled
};

function createPost(string token, string commentary) returns http:Response|error {
    return apiClient->post("/rest/posts", textPost(commentary), restliHeaders(token));
}

function uniqueText() returns string => "Mock post " + uuid:createType4AsString();

// Community Management: page connection, refresh grant and the engagement finders

const PAGE_SCOPE = "r_organization_social_feed rw_organization_admin";
const TEST_ORG = "urn:li:organization:1477";

@test:Config
function testPageGrantHasARefreshTokenAndKeepsTheShareToken() returns error? {
    string shareToken = check accessToken("openid profile w_member_social");
    http:Response res = check tokenRequest(check authorizationCode(PAGE_SCOPE), TEST_CLIENT_SECRET);
    json body = check res.getJsonPayload();
    string refresh = check body.refresh_token;
    int refreshTtl = check body.refresh_token_expires_in;
    test:assertTrue(refreshTtl > 30000000);
    // The page grant is another product: the member's share token still works.
    http:Response me = check apiClient->get("/v2/userinfo", bearer(shareToken));
    test:assertEquals(me.statusCode, http:STATUS_OK);

    http:Response refreshed = check wwwClient->post("/oauth/v2/accessToken",
            string `grant_type=refresh_token&refresh_token=${refresh}&client_id=${TEST_CLIENT_ID}&client_secret=${TEST_CLIENT_SECRET}`,
            mediaType = "application/x-www-form-urlencoded");
    test:assertEquals(refreshed.statusCode, http:STATUS_OK);
    json again = check refreshed.getJsonPayload();
    test:assertEquals(check again.refresh_token, refresh, "the same refresh token");
    test:assertNotEquals(check again.access_token, check body.access_token);
    http:Response unknown = check wwwClient->post("/oauth/v2/accessToken",
            string `grant_type=refresh_token&refresh_token=nope&client_id=${TEST_CLIENT_ID}&client_secret=${TEST_CLIENT_SECRET}`,
            mediaType = "application/x-www-form-urlencoded");
    test:assertEquals(unknown.statusCode, http:STATUS_BAD_REQUEST);
}

@test:Config
function testOrganizationAclSaysTheMemberIsAdministrator() returns error? {
    string token = check accessToken(PAGE_SCOPE);
    http:Response res = check apiClient->get("/rest/organizationAcls?q=roleAssignee&role=ADMINISTRATOR&state=APPROVED",
            restliHeaders(token));
    test:assertEquals(res.statusCode, http:STATUS_OK);
    json body = check res.getJsonPayload();
    json[] elements = check (check body.elements).ensureType();
    test:assertEquals(check elements[0].organization, TEST_ORG);
    test:assertEquals(check elements[0].roleAssignee, TEST_AUTHOR);
    // The share token can't read ACLs.
    http:Response denied = check apiClient->get("/rest/organizationAcls?q=roleAssignee",
            restliHeaders(check accessToken("openid profile w_member_social")));
    test:assertEquals(denied.statusCode, http:STATUS_FORBIDDEN);
}

@test:Config
function testInjectedEngagementIsServedByTheFinders() returns error? {
    string post = "urn:li:share:7100";
    foreach json e in [
        {kind: "REACTION", targetUrn: post, actorUrn: TEST_AUTHOR},
        {kind: "COMMENT", targetUrn: post, actorUrn: TEST_AUTHOR, commentary: "kept nowhere"},
        {kind: "RESHARE", targetUrn: post, actorUrn: TEST_AUTHOR, commentary: "my words"}
    ] {
        http:Response added = check apiClient->post("/mock/engagement", e, adminHeaders());
        test:assertEquals(added.statusCode, http:STATUS_CREATED);
    }
    http:Response noKey = check apiClient->post("/mock/engagement", {kind: "REACTION", targetUrn: post,
        actorUrn: TEST_AUTHOR});
    test:assertEquals(noKey.statusCode, http:STATUS_UNAUTHORIZED);

    string token = check accessToken(PAGE_SCOPE);
    http:Response reactions = check apiClient->get(
            "/rest/reactions/(entity:urn%3Ali%3Ashare%3A7100)?q=entity&sort=(value:CHRONOLOGICAL)&start=0&count=10",
            restliHeaders(token));
    test:assertEquals(reactions.statusCode, http:STATUS_OK, (check reactions.getTextPayload()));
    json r = check reactions.getJsonPayload();
    json[] re = check (check r.elements).ensureType();
    test:assertEquals(re.length(), 1);
    test:assertEquals(check re[0].root, post);
    test:assertEquals(check re[0].created.actor, TEST_AUTHOR);

    http:Response comments = check apiClient->get("/rest/socialActions/urn%3Ali%3Ashare%3A7100/comments?start=0&count=10",
            restliHeaders(token));
    json c = check comments.getJsonPayload();
    json[] ce = check (check c.elements).ensureType();
    test:assertEquals(ce.length(), 1);
    test:assertFalse(c.toJsonString().includes("kept nowhere"), "no comment text kept");

    int now = <int>(nowSeconds() * 1000d);
    http:Response shares = check apiClient->get(string `/rest/organizationalEntityNotifications?q=criteria&actions=List(SHARE,SHARE_MENTION)&organizationalEntity=urn%3Ali%3Aorganization%3A1477&timeRange=(start:${now - 60000},end:${now + 60000})`,
            restliHeaders(token));
    test:assertEquals(shares.statusCode, http:STATUS_OK);
    json n = check shares.getJsonPayload();
    json[] ne = check (check n.elements).ensureType();
    test:assertEquals(ne.length(), 1);
    test:assertEquals(check ne[0].sourcePost, post);
    test:assertEquals(check ne[0].decoratedGeneratedActivity.share.owner, TEST_AUTHOR);
    test:assertTrue((check ne[0].generatedActivity).toString().startsWith("urn:li:activity:"));

    http:Response outside = check apiClient->get(string `/rest/organizationalEntityNotifications?q=criteria&actions=List(SHARE)&organizationalEntity=urn%3Ali%3Aorganization%3A1477&timeRange=(start:0,end:1000)`,
            restliHeaders(token));
    json o = check outside.getJsonPayload();
    json[] oe = check (check o.elements).ensureType();
    test:assertEquals(oe.length(), 0, "outside the time range");
    http:Response otherPage = check apiClient->get(string `/rest/organizationalEntityNotifications?q=criteria&actions=List(SHARE)&organizationalEntity=urn%3Ali%3Aorganization%3A9&timeRange=(start:0,end:1000)`,
            restliHeaders(token));
    test:assertEquals(otherPage.statusCode, http:STATUS_FORBIDDEN);
}

// Pre-coin verification reads (Amplify V027): one reaction, one comment, one post; and a removed engagement is 404.

@test:Config
function testVerificationReadsSeeAnEngagementUntilItIsRemoved() returns error? {
    string post = "urn:li:share:7200";
    http:Response reacted = check apiClient->post("/mock/engagement",
            {kind: "REACTION", targetUrn: post, actorUrn: TEST_AUTHOR}, adminHeaders());
    test:assertEquals(reacted.statusCode, http:STATUS_CREATED);
    http:Response commented = check apiClient->post("/mock/engagement",
            {kind: "COMMENT", targetUrn: post, actorUrn: TEST_AUTHOR}, adminHeaders());
    string commentId = check (check commented.getJsonPayload()).activityUrn;
    http:Response reshared = check apiClient->post("/mock/engagement",
            {kind: "RESHARE", targetUrn: post, actorUrn: TEST_AUTHOR}, adminHeaders());
    string reshareUrn = check (check reshared.getJsonPayload()).activityUrn;

    string page = check accessToken(PAGE_SCOPE);
    string reactionPath = "/rest/reactions/(actor:urn%3Ali%3Aperson%3A782bbtaQ,entity:urn%3Ali%3Ashare%3A7200)";
    string commentPath = "/rest/socialActions/urn%3Ali%3Ashare%3A7200/comments/" + commentId;
    string resharePath = "/rest/posts/" + check url:encode(reshareUrn, "UTF-8");
    http:Response reaction = check apiClient->get(reactionPath, restliHeaders(page));
    test:assertEquals(reaction.statusCode, http:STATUS_OK);
    test:assertEquals(check (check reaction.getJsonPayload()).root, post);
    http:Response other = check apiClient->get(
            "/rest/reactions/(actor:urn%3Ali%3Aperson%3Asomeone,entity:urn%3Ali%3Ashare%3A7200)", restliHeaders(page));
    test:assertEquals(other.statusCode, http:STATUS_NOT_FOUND);
    http:Response comment = check apiClient->get(commentPath, restliHeaders(page));
    test:assertEquals(comment.statusCode, http:STATUS_OK);
    http:Response reshare = check apiClient->get(resharePath, restliHeaders(page));
    test:assertEquals(reshare.statusCode, http:STATUS_OK);
    http:Response noQ = check apiClient->get("/rest/reactions/(entity:urn%3Ali%3Ashare%3A7200)", restliHeaders(page));
    test:assertEquals(noQ.statusCode, http:STATUS_BAD_REQUEST, "the finder still needs q=entity");

    foreach string kind in ["REACTION", "COMMENT", "RESHARE"] {
        http:Response removed = check apiClient->post("/mock/engagement/remove",
                {kind, targetUrn: post, actorUrn: TEST_AUTHOR}, adminHeaders());
        test:assertEquals(removed.statusCode, http:STATUS_OK, kind);
    }
    foreach string path in [reactionPath, commentPath, resharePath] {
        http:Response gone = check apiClient->get(path, restliHeaders(page));
        test:assertEquals(gone.statusCode, http:STATUS_NOT_FOUND, path);
    }
    http:Response again = check apiClient->post("/mock/engagement/remove",
            {kind: "REACTION", targetUrn: post, actorUrn: TEST_AUTHOR}, adminHeaders());
    test:assertEquals(again.statusCode, http:STATUS_NOT_FOUND);
    http:Response noKey = check apiClient->post("/mock/engagement/remove",
            {kind: "REACTION", targetUrn: post, actorUrn: TEST_AUTHOR});
    test:assertEquals(noKey.statusCode, http:STATUS_UNAUTHORIZED);
}

@test:Config
function testReadPostWithTheMemberTokenUntilDeleted() returns error? {
    string token = check accessToken("openid profile w_member_social");
    http:Response created = check createPost(token, uniqueText());
    string urn = check created.getHeader(HEADER_RESTLI_ID);
    string path = "/rest/posts/" + check url:encode(urn, "UTF-8");
    http:Response read = check apiClient->get(path, restliHeaders(token));
    test:assertEquals(read.statusCode, http:STATUS_OK);
    json body = check read.getJsonPayload();
    test:assertEquals(check body.id, urn);
    test:assertEquals(check body.author, TEST_AUTHOR);
    http:Response deleted = check apiClient->delete(path, headers = restliHeaders(token));
    test:assertEquals(deleted.statusCode, http:STATUS_NO_CONTENT);
    http:Response gone = check apiClient->get(path, restliHeaders(token));
    test:assertEquals(gone.statusCode, http:STATUS_NOT_FOUND);
    http:Response anonymous = check apiClient->get(path, restliHeaders(()));
    test:assertEquals(anonymous.statusCode, http:STATUS_UNAUTHORIZED);
    // Last: a new scope set revokes the member's earlier token.
    http:Response noScope = check apiClient->get(path, restliHeaders(check accessToken("openid profile")));
    test:assertEquals(noScope.statusCode, http:STATUS_FORBIDDEN);
}
