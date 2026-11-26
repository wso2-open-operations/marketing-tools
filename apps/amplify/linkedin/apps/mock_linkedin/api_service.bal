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
import mock_linkedin.store;

import ballerina/http;
import ballerina/log;

# Listener for the `api.linkedin.com` host.
listener http:Listener apiListener = new (apiPort, host = listenerHost);

# Mock of the Share on LinkedIn (`w_member_social`) API, built from
# `apps/amplify/linkedin/resources/openapi/openapi/w-member-social.openapi.yaml`. Image byte
# uploads live on the `www` host, so that operation is in `www_service.bal`.
@display {
    label: "Mock LinkedIn Share API",
    id: "linkedin/mock-share-api"
}
service http:InterceptableService / on apiListener {

    # Request and response interceptors. The response interceptors come first so they
    # also see responses the request interceptor returns.
    #
    # + return - Interceptor pipeline
    public isolated function createInterceptors() returns http:Interceptor[] =>
        [new ResponseInterceptor(), new ErrorInterceptor(), new CorrelationInterceptor(), new RequestInterceptor()];

    # Get the signed-in member (OpenID Connect).
    #
    # + ctx - Request context
    # + return - Member profile claims, or an error
    isolated resource function get v2/userinfo(http:RequestContext ctx) returns UserInfo|ErrorUnauthorized|ErrorForbidden {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_OPENID, SCOPE_PROFILE], "GET /v2/userinfo");
        if token !is store:AccessToken {
            return token;
        }
        UserInfo info = {
            sub: member.sub,
            name: string `${member.givenName} ${member.familyName}`,
            given_name: member.givenName,
            family_name: member.familyName,
            picture: member.picture,
            locale: member.locale
        };
        if token.scopes.indexOf(SCOPE_EMAIL) !is () {
            info.email = member.email;
            info.email_verified = true;
        }
        return info;
    }

    # Create a post, or reshare one, as the member.
    #
    # + ctx - Request context
    # + LinkedIn\-Version - API version, checked by the request interceptor
    # + X\-Restli\-Protocol\-Version - Rest.li protocol version, checked by the request interceptor
    # + payload - Post to create
    # + return - 201 with the post URN in `x-restli-id`, or an error
    isolated resource function post rest/posts(http:RequestContext ctx, @http:Header string LinkedIn\-Version,
            @http:Header "2.0.0" X\-Restli\-Protocol\-Version, @http:Payload CreatePost payload)
            returns http:Created|ErrorBadRequest|ErrorUnauthorized|ErrorForbidden|ErrorUnprocessableEntity|ErrorTooManyRequests {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_W_MEMBER_SOCIAL], "POST /rest/posts");
        if token !is store:AccessToken {
            return token;
        }
        ErrorForbidden? notMember = checkIsMember(payload.author, token);
        if notMember is ErrorForbidden {
            return notMember;
        }
        ErrorBadRequest|ErrorForbidden? invalid = validateCreatePost(payload, token);
        if invalid !is () {
            return invalid;
        }
        string urn = newShareUrn();
        string? duplicateOf = store:putPostIfNotDuplicate({
            urn,
            authorUrn: payload.author,
            commentary: payload.commentary,
            lifecycleState: payload.lifecycleState,
            reshareDisabled: payload.isReshareDisabledByAuthor,
            'source: POST_SOURCE_REST,
            parentUrn: payload.reshareContext?.parent,
            mediaUrn: payload.content?.media?.id,
            articleUrl: payload.content?.article?.'source,
            articleTitle: payload.content?.article?.title,
            createdAt: nowSeconds()
        }, nowSeconds() - DUPLICATE_WINDOW_SECONDS);
        if duplicateOf is string {
            return unprocessable(string `Content is a duplicate of ${duplicateOf}`);
        }
        log:printInfo("Post created", correlationId = correlationId(ctx), postUrn = urn,
                reshare = payload.reshareContext !is ());
        return {headers: {[HEADER_RESTLI_ID]: urn}};
    }

    # Edit a post (PARTIAL_UPDATE).
    #
    # + ctx - Request context
    # + postUrn - URN of the post
    # + LinkedIn\-Version - API version, checked by the request interceptor
    # + X\-Restli\-Protocol\-Version - Rest.li protocol version, checked by the request interceptor
    # + X\-RestLi\-Method - Must be `PARTIAL_UPDATE`
    # + payload - Fields to change
    # + return - 204, or an error
    isolated resource function post rest/posts/[string postUrn](http:RequestContext ctx, @http:Header string LinkedIn\-Version,
            @http:Header "2.0.0" X\-Restli\-Protocol\-Version, @http:Header "PARTIAL_UPDATE" X\-RestLi\-Method,
            @http:Payload PostPatch payload)
            returns http:NoContent|ErrorBadRequest|ErrorUnauthorized|ErrorForbidden|ErrorNotFound {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_W_MEMBER_SOCIAL], "POST /rest/posts/{postUrn}");
        if token !is store:AccessToken {
            return token;
        }
        PostPatch_patch_set changes = payload.patch.\$set;
        string? commentary = changes.commentary;
        if commentary is string && commentary.length() > MAX_COMMENTARY_LENGTH {
            return badRequest(string `commentary must be ${MAX_COMMENTARY_LENGTH} characters or fewer`);
        }
        store:Post|store:UpdateFailure updated = store:updatePost(postUrn, personUrn(token.memberSub), {
            commentary,
            lifecycleState: changes.lifecycleState,
            callToActionLabel: changes.contentCallToActionLabel,
            landingPage: changes.contentLandingPage
        }, nowSeconds());
        if updated is store:POST_NOT_FOUND {
            return notFound(string `Post ${postUrn} not found`);
        }
        if updated is store:NOT_POST_AUTHOR {
            return forbidden(string `Member is not the author of ${postUrn}`);
        }
        log:printInfo("Post updated", correlationId = correlationId(ctx), postUrn = postUrn);
        return http:NO_CONTENT;
    }

    # Delete a post. Idempotent.
    #
    # + ctx - Request context
    # + postUrn - URN of the post
    # + LinkedIn\-Version - API version, checked by the request interceptor
    # + X\-Restli\-Protocol\-Version - Rest.li protocol version, checked by the request interceptor
    # + X\-RestLi\-Method - Optional, `DELETE`
    # + return - 204, or an error
    isolated resource function delete rest/posts/[string postUrn](http:RequestContext ctx, @http:Header string LinkedIn\-Version,
            @http:Header "2.0.0" X\-Restli\-Protocol\-Version, @http:Header "DELETE"? X\-RestLi\-Method)
            returns http:NoContent|ErrorUnauthorized|ErrorForbidden {
        return deletePost(ctx, postUrn, "DELETE /rest/posts/{postUrn}");
    }

    # Register an image upload.
    #
    # + ctx - Request context
    # + LinkedIn\-Version - API version, checked by the request interceptor
    # + X\-Restli\-Protocol\-Version - Rest.li protocol version, checked by the request interceptor
    # + action - Must be `initializeUpload`
    # + payload - Upload owner
    # + return - Upload URL and image URN, or an error
    isolated resource function post rest/images(http:RequestContext ctx, @http:Header string LinkedIn\-Version,
            @http:Header "2.0.0" X\-Restli\-Protocol\-Version, "initializeUpload" action,
            @http:Payload InitializeImageUploadRequest payload)
            returns InitializeImageUploadResponseOk|ErrorUnauthorized|ErrorForbidden {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_W_MEMBER_SOCIAL], "POST /rest/images");
        if token !is store:AccessToken {
            return token;
        }
        string owner = payload.initializeUploadRequest.owner;
        ErrorForbidden? notMember = checkIsMember(owner, token);
        if notMember is ErrorForbidden {
            return notMember;
        }
        store:Upload upload = registerUpload(IMAGE_URN_PREFIX, owner);
        log:printInfo("Image upload registered", correlationId = correlationId(ctx), image = upload.mediaUrn);
        return <InitializeImageUploadResponseOk>{
            body: {
                value: {
                    uploadUrl: uploadUrl(upload.uploadId),
                    uploadUrlExpiresAt: <int>(upload.expiresAt * 1000),
                    image: upload.mediaUrn
                }
            }
        };
    }

    # Share on LinkedIn (legacy UGC Post).
    #
    # + ctx - Request context
    # + X\-Restli\-Protocol\-Version - Rest.li protocol version, checked by the request interceptor
    # + payload - Share to create
    # + return - 201 with the share URN in `x-restli-id`, or an error
    isolated resource function post v2/ugcPosts(http:RequestContext ctx, @http:Header "2.0.0" X\-Restli\-Protocol\-Version,
            @http:Payload CreateUgcPost payload)
            returns http:Created|ErrorBadRequest|ErrorUnauthorized|ErrorForbidden|ErrorConflict|ErrorUnprocessableEntity|ErrorTooManyRequests {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_W_MEMBER_SOCIAL], "POST /v2/ugcPosts");
        if token !is store:AccessToken {
            return token;
        }
        ErrorForbidden? notMember = checkIsMember(payload.author, token);
        if notMember is ErrorForbidden {
            return notMember;
        }
        CreateUgcPost_shareContent share = payload.specificContent.com\.linkedin\.ugc\.ShareContent;
        ErrorBadRequest|ErrorForbidden? invalid = validateUgcShare(share, token);
        if invalid !is () {
            return invalid;
        }
        string commentary = share.shareCommentary.text ?: "";
        CreateUgcPost_media[] media = share.media ?: [];
        string urn = newShareUrn();
        string? duplicateOf = store:putPostIfNotDuplicate({
            urn,
            authorUrn: payload.author,
            commentary,
            lifecycleState: payload.lifecycleState,
            reshareDisabled: false,
            'source: POST_SOURCE_UGC,
            mediaUrn: media.length() > 0 ? media[0].media : (),
            articleUrl: media.length() > 0 ? media[0].originalUrl : (),
            createdAt: nowSeconds()
        }, nowSeconds() - DUPLICATE_WINDOW_SECONDS);
        if duplicateOf is string {
            return unprocessable(string `Content is a duplicate of ${duplicateOf}`);
        }
        log:printInfo("UGC share created", correlationId = correlationId(ctx), postUrn = urn);
        return {headers: {[HEADER_RESTLI_ID]: urn}};
    }

    # Delete a legacy UGC post.
    #
    # + ctx - Request context
    # + ugcPostUrn - URN of the post
    # + X\-Restli\-Protocol\-Version - Rest.li protocol version, checked by the request interceptor
    # + return - 204, or an error
    isolated resource function delete v2/ugcPosts/[string ugcPostUrn](http:RequestContext ctx,
            @http:Header "2.0.0" X\-Restli\-Protocol\-Version) returns http:NoContent|ErrorUnauthorized|ErrorForbidden {
        return deletePost(ctx, ugcPostUrn, "DELETE /v2/ugcPosts/{ugcPostUrn}");
    }

    # Register an image or video upload (legacy Assets API).
    #
    # + ctx - Request context
    # + X\-Restli\-Protocol\-Version - Rest.li protocol version, checked by the request interceptor
    # + action - Must be `registerUpload`
    # + payload - Upload owner and recipe
    # + return - Upload URL and asset URN, or an error
    isolated resource function post v2/assets(http:RequestContext ctx, @http:Header "2.0.0" X\-Restli\-Protocol\-Version,
            "registerUpload" action, @http:Payload RegisterAssetUploadRequest payload)
            returns RegisterAssetUploadResponseOk|ErrorUnauthorized|ErrorForbidden {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_W_MEMBER_SOCIAL], "POST /v2/assets");
        if token !is store:AccessToken {
            return token;
        }
        string owner = payload.registerUploadRequest.owner;
        ErrorForbidden? notMember = checkIsMember(owner, token);
        if notMember is ErrorForbidden {
            return notMember;
        }
        store:Upload upload = registerUpload(ASSET_URN_PREFIX, owner);
        log:printInfo("Asset upload registered", correlationId = correlationId(ctx), asset = upload.mediaUrn);
        return <RegisterAssetUploadResponseOk>{
            body: {
                value: {
                    uploadMechanism: {
                        com\.linkedin\.digitalmedia\.uploading\.MediaUploadHttpRequest: {
                            uploadUrl: uploadUrl(upload.uploadId),
                            headers: {[HEADER_MEDIA_TYPE_FAMILY]: MEDIA_TYPE_FAMILY_STILLIMAGE}
                        }
                    },
                    mediaArtifact: string `urn:li:digitalmediaMediaArtifact:(${upload.mediaUrn},urn:li:digitalmediaMediaArtifactClass:feedshare-uploadedImage)`,
                    asset: upload.mediaUrn
                }
            }
        };
    }

    // ---- Community Management (page connection and engagement reads) -------------------------------

    # Reactions on a post (`q=entity`). Newest first unless `sort=(value:CHRONOLOGICAL)`.
    #
    # + ctx - Request context
    # + key - `(entity:{urn})`
    # + q - Must be `entity`
    # + sort - `(value:CHRONOLOGICAL)` or `(value:REVERSE_CHRONOLOGICAL)` (default)
    # + 'start - Offset
    # + count - Page size
    # + return - The reactions, or an error
    isolated resource function get rest/reactions/[string key](http:RequestContext ctx, "entity" q, string? sort,
            int 'start = 0, int count = 10) returns json|ErrorBadRequest|ErrorUnauthorized|ErrorForbidden {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_R_ORGANIZATION_SOCIAL_FEED], "GET /rest/reactions");
        if token !is store:AccessToken {
            return token;
        }
        string? entity = entityOfKey(key);
        if entity is () {
            return badRequest("The key must be (entity:{urn})");
        }
        store:Engagement[] all = store:listEngagements(ENGAGEMENT_REACTION, entity);
        if sort != "(value:CHRONOLOGICAL)" {
            all = all.reverse();
        }
        json[] elements = from store:Engagement e in pageOf(all, 'start, count)
            let int time = epochMillis(e.createdAt)
            select {
                id: string `urn:li:reaction:(${e.actorUrn},${e.targetUrn})`,
                reactionType: "LIKE",
                root: e.targetUrn,
                created: {actor: e.actorUrn, time},
                lastModified: {actor: e.actorUrn, time}
            };
        return collection(elements, 'start, count, all.length());
    }

    # Top-level comments on a post, oldest first. The mock keeps no comment text.
    #
    # + ctx - Request context
    # + socialActionUrn - Post URN
    # + 'start - Offset
    # + count - Page size
    # + return - The comments, or an error
    isolated resource function get rest/socialActions/[string socialActionUrn]/comments(http:RequestContext ctx,
            int 'start = 0, int count = 10) returns json|ErrorUnauthorized|ErrorForbidden {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_R_ORGANIZATION_SOCIAL_FEED], "GET /rest/socialActions/{urn}/comments");
        if token !is store:AccessToken {
            return token;
        }
        string target = decoded(socialActionUrn);
        store:Engagement[] all = store:listEngagements(ENGAGEMENT_COMMENT, target);
        json[] elements = from store:Engagement e in pageOf(all, 'start, count)
            let int time = epochMillis(e.createdAt), string id = e.activityUrn ?: "0"
            select {
                actor: e.actorUrn,
                agent: e.actorUrn,
                id,
                commentUrn: string `urn:li:comment:(${target},${id})`,
                'object: target,
                created: {actor: e.actorUrn, time},
                lastModified: {actor: e.actorUrn, time},
                message: {attributes: [], text: "(mock comment)"}
            };
        return collection(elements, 'start, count, all.length());
    }

    # The page's share notifications (`q=criteria`): reshares of its posts in a time range.
    #
    # + ctx - Request context
    # + q - Must be `criteria`
    # + actions - `List(SHARE,...)` (the listener splits a query value on commas, so it arrives in parts)
    # + organizationalEntity - The page URN
    # + timeRange - `(start:{ms},end:{ms})`, in parts like `actions`
    # + 'start - Offset
    # + count - Page size
    # + return - The notifications, or an error
    isolated resource function get rest/organizationalEntityNotifications(http:RequestContext ctx, "criteria" q,
            string[] actions, string organizationalEntity, string[] timeRange, int 'start = 0, int count = 10)
            returns json|ErrorBadRequest|ErrorUnauthorized|ErrorForbidden {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_R_ORGANIZATION_SOCIAL_FEED], "GET /rest/organizationalEntityNotifications");
        if token !is store:AccessToken {
            return token;
        }
        string org = decoded(organizationalEntity);
        if org != organizationUrn {
            return forbidden(string `Member is not an administrator of ${org}`);
        }
        [int, int]? range = parseTimeRange(decoded(string:'join(",", ...timeRange)));
        if range is () {
            return badRequest("timeRange must be (start:{ms},end:{ms})");
        }
        if !decoded(string:'join(",", ...actions)).includes(NOTIFICATION_SHARE) {
            return collection([], 'start, count, 0);
        }
        store:Engagement[] all = from store:Engagement e in store:listEngagements(ENGAGEMENT_RESHARE)
            let int at = epochMillis(e.createdAt)
            where at >= range[0] && at <= range[1]
            select e;
        json[] elements = from store:Engagement e in pageOf(all, 'start, count)
            let string activity = e.activityUrn ?: ""
            select {
                action: NOTIFICATION_SHARE,
                organizationalEntity: org,
                sourcePost: e.targetUrn,
                generatedActivity: activity,
                lastModifiedAt: epochMillis(e.createdAt),
                decoratedGeneratedActivity: {
                    share: e.hasCommentary
                        ? {owner: e.actorUrn, entity: activity, text: "(mock commentary)"}
                        : {owner: e.actorUrn, entity: activity}
                }
            };
        return collection(elements, 'start, count, all.length());
    }

    # Lifetime analytics of a post the signed-in member authored (`q=entity`, member post analytics). The mock answers
    # stable counts from the post's engagement: impressions 100 + 25 per reaction, comment or reshare, members reached
    # 60 + 15 per engagement. Only `TOTAL` aggregation; `MEMBERS_REACHED` supports nothing else at LinkedIn either.
    #
    # + ctx - Request context
    # + q - Must be `entity`
    # + entity - `(share:{urn})` or `(ugc:{urn})`, the URN encoded
    # + queryType - `IMPRESSION`, `MEMBERS_REACHED`, `REACTION`, `COMMENT` or `RESHARE`
    # + aggregation - `TOTAL` (default) or `DAILY`
    # + return - One element with the count, or an error (404 unknown post, 403 another member's post)
    isolated resource function get rest/memberCreatorPostAnalytics(http:RequestContext ctx, "entity" q, string entity,
            string queryType, string? aggregation) returns json|ErrorBadRequest|ErrorUnauthorized|ErrorForbidden|ErrorNotFound {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_R_MEMBER_POST_ANALYTICS], "GET /rest/memberCreatorPostAnalytics");
        if token !is store:AccessToken {
            return token;
        }
        string value = decoded(entity);
        string? urn = analyticsEntityUrn(value);
        if urn is () {
            return badRequest("entity must be (share:{urn}) or (ugc:{urn})");
        }
        if ["IMPRESSION", "MEMBERS_REACHED", "REACTION", "COMMENT", "RESHARE"].indexOf(queryType) is () {
            return badRequest("Unknown queryType");
        }
        if aggregation is string && aggregation != "TOTAL" && (aggregation != "DAILY" || queryType == "MEMBERS_REACHED") {
            return badRequest("Unsupported aggregation");
        }
        store:Post? post = store:getPost(urn);
        if post is () {
            return notFound(string `Post ${urn} not found`);
        }
        if post.authorUrn != personUrn(token.memberSub) {
            return forbidden("Analytics are only available for the member's own posts");
        }
        int reactions = store:listEngagements(ENGAGEMENT_REACTION, urn).length();
        int comments = store:listEngagements(ENGAGEMENT_COMMENT, urn).length();
        int reshares = (from store:Engagement e in store:listEngagements(ENGAGEMENT_RESHARE)
            where e.targetUrn == urn
            select e).length();
        int engagement = reactions + comments + reshares;
        int count = queryType == "IMPRESSION" ? 100 + 25 * engagement
            : queryType == "MEMBERS_REACHED" ? 60 + 15 * engagement
            : queryType == "REACTION" ? reactions : queryType == "COMMENT" ? comments : reshares;
        string key = urn.startsWith("urn:li:ugcPost:") ? "ugc" : "share";
        return collection([{
            count,
            metricType: {"com.linkedin.adsexternalapi.memberanalytics.v1.CreatorPostAnalyticsMetricTypeV1": queryType},
            targetEntity: {[key]: urn}
        }], 0, 10, 1);
    }

    # The signed-in member's roles on organizations (`q=roleAssignee`). The configured member is an approved
    # administrator of `organizationUrn`.
    #
    # + ctx - Request context
    # + q - `roleAssignee`
    # + role - Only this role
    # + state - Only this state
    # + return - The ACLs, or an error
    isolated resource function get rest/organizationAcls(http:RequestContext ctx, "roleAssignee" q, string? role,
            string? state) returns json|ErrorUnauthorized|ErrorForbidden {
        store:AccessToken|ErrorUnauthorized|ErrorForbidden token =
            authorize(ctx, [SCOPE_RW_ORGANIZATION_ADMIN], "GET /rest/organizationAcls");
        if token !is store:AccessToken {
            return token;
        }
        json[] elements = [];
        if (role is () || role == ROLE_ADMINISTRATOR) && (state is () || state == STATE_APPROVED) {
            elements.push({roleAssignee: personUrn(token.memberSub), role: ROLE_ADMINISTRATOR, state: STATE_APPROVED,
                organization: organizationUrn});
        }
        return collection(elements, 0, 10, elements.length());
    }
}

# Deletes a post the member owns. Unknown posts return 204 because delete is idempotent.
#
# + ctx - Request context
# + postUrn - URN of the post
# + operation - Operation name for error messages
# + return - 204, or an error
isolated function deletePost(http:RequestContext ctx, string postUrn, string operation)
        returns http:NoContent|ErrorUnauthorized|ErrorForbidden {
    store:AccessToken|ErrorUnauthorized|ErrorForbidden token = authorize(ctx, [SCOPE_W_MEMBER_SOCIAL], operation);
    if token !is store:AccessToken {
        return token;
    }
    store:Post? post = store:getPost(postUrn);
    if post is () {
        log:printDebug("Delete of unknown post", correlationId = correlationId(ctx), postUrn = postUrn);
        return http:NO_CONTENT;
    }
    ErrorForbidden? notMember = checkIsMember(post.authorUrn, token);
    if notMember is ErrorForbidden {
        return notMember;
    }
    store:removePost(postUrn);
    log:printInfo("Post deleted", correlationId = correlationId(ctx), postUrn = postUrn);
    return http:NO_CONTENT;
}

# Registers a pending upload.
#
# + urnPrefix - `urn:li:image:` or `urn:li:digitalmediaAsset:`
# + ownerUrn - Person URN of the owner
# + return - The upload
isolated function registerUpload(string urnPrefix, string ownerUrn) returns store:Upload {
    string uploadId = randomMediaId();
    store:Upload upload = {
        uploadId,
        mediaUrn: urnPrefix + uploadId,
        ownerUrn,
        expiresAt: nowSeconds() + UPLOAD_URL_TTL_SECONDS,
        uploaded: false
    };
    store:putUpload(upload);
    return upload;
}

# Applies the rules LinkedIn enforces on a versioned post.
#
# + payload - Post to create
# + token - Access token of the caller
# + return - A 400 or 403 response if the post is invalid
isolated function validateCreatePost(CreatePost payload, store:AccessToken token) returns ErrorBadRequest|ErrorForbidden? {
    if payload.commentary.length() > MAX_COMMENTARY_LENGTH {
        return badRequest(string `commentary must be ${MAX_COMMENTARY_LENGTH} characters or fewer`);
    }
    PostContent? content = payload.content;
    ReshareContext? reshare = payload.reshareContext;
    if content is () && reshare is () && payload.commentary.trim() == "" {
        return badRequest("commentary is required when the post has no content or reshareContext");
    }
    if content !is () {
        PostContent_media? media = content.media;
        PostContent_article? article = content.article;
        if media !is () && article !is () {
            return badRequest("content can have media or article, not both");
        }
        if media !is () {
            ErrorBadRequest|ErrorForbidden? mediaError = checkMedia(media.id, token);
            if mediaError !is () {
                return mediaError;
            }
        }
        if article !is () && !isHttpUrl(article.'source) {
            return badRequest(string `content.article.source ${article.'source} is not a valid URL`);
        }
        // The real Posts API refuses an article without a title (it doesn't scrape the link), so the mock
        // does too: a client that drops the title fails here instead of only in production.
        if article !is () && (article.title ?: "").trim() == "" {
            return badRequest("content.article.title is required");
        }
    }
    if reshare !is () {
        if !isPostUrn(reshare.parent) {
            return badRequest(string `reshareContext.parent ${reshare.parent} is not a post URN`);
        }
        // Parents not in the store are treated as real LinkedIn posts the mock never saw.
        store:Post? parent = store:getPost(reshare.parent);
        if parent !is () && parent.reshareDisabled {
            return forbidden(string `Resharing ${reshare.parent} is disabled by the author`);
        }
    }
    return ();
}

# Applies the rules LinkedIn enforces on a legacy UGC share.
#
# + share - Share content
# + token - Access token of the caller
# + return - A 400 or 403 response if the share is invalid
isolated function validateUgcShare(CreateUgcPost_shareContent share, store:AccessToken token)
        returns ErrorBadRequest|ErrorForbidden? {
    string commentary = share.shareCommentary.text ?: "";
    if commentary.length() > MAX_COMMENTARY_LENGTH {
        return badRequest(string `shareCommentary.text must be ${MAX_COMMENTARY_LENGTH} characters or fewer`);
    }
    CreateUgcPost_media[] media = share.media ?: [];
    match share.shareMediaCategory {
        UGC_MEDIA_NONE => {
            if media.length() > 0 {
                return badRequest("media must be empty when shareMediaCategory is NONE");
            }
            if commentary.trim() == "" {
                return badRequest("shareCommentary.text is required when shareMediaCategory is NONE");
            }
        }
        UGC_MEDIA_ARTICLE => {
            if media.length() == 0 {
                return badRequest("media is required when shareMediaCategory is ARTICLE");
            }
            foreach CreateUgcPost_media item in media {
                string? originalUrl = item.originalUrl;
                if originalUrl is () || !isHttpUrl(originalUrl) {
                    return badRequest("media.originalUrl must be a valid URL for ARTICLE shares");
                }
            }
        }
        UGC_MEDIA_IMAGE => {
            if media.length() == 0 {
                return badRequest("media is required when shareMediaCategory is IMAGE");
            }
            foreach CreateUgcPost_media item in media {
                string? asset = item.media;
                if asset is () {
                    return badRequest("media.media must be an asset URN for IMAGE shares");
                }
                ErrorBadRequest|ErrorForbidden? mediaError = checkMedia(asset, token);
                if mediaError !is () {
                    return mediaError;
                }
            }
        }
    }
    return ();
}
