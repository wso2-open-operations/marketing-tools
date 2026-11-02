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

// In-memory state for the mock. Everything is lost on restart, which is the point.

# A one-time OAuth 2.0 authorization code.
public type AuthorizationCode readonly & record {|
    string code;
    string clientId;
    string redirectUri;
    string[] scopes;
    string memberSub;
    decimal expiresAt;
|};

# An issued access token.
public type AccessToken readonly & record {|
    string value;
    string clientId;
    string memberSub;
    string[] scopes;
    decimal expiresAt;
|};

# A post created through `/rest/posts` or `/v2/ugcPosts`.
public type Post readonly & record {|
    string urn;
    string authorUrn;
    string commentary;
    string lifecycleState;
    boolean reshareDisabled;
    string 'source;
    string? parentUrn = ();
    string? mediaUrn = ();
    string? articleUrl = ();
    # `content.article.title` (shown by `/mock/posts`, so tests can check what a client sent)
    string? articleTitle = ();
    string? callToActionLabel = ();
    string? landingPage = ();
    decimal createdAt;
    decimal? lastModifiedAt = ();
|};

# Fields a PARTIAL_UPDATE can change. `()` keeps the current value.
public type PostChanges readonly & record {|
    string? commentary = ();
    string? lifecycleState = ();
    string? callToActionLabel = ();
    string? landingPage = ();
|};

# Why a post update did not happen.
public enum UpdateFailure {
    POST_NOT_FOUND,
    NOT_POST_AUTHOR
}

# A registered media upload.
public type Upload readonly & record {|
    string uploadId;
    string mediaUrn;
    string ownerUrn;
    decimal expiresAt;
    boolean uploaded;
|};

isolated map<AuthorizationCode> authorizationCodes = {};
isolated map<AccessToken> accessTokens = {};
isolated map<Post> posts = {};
isolated map<Upload> uploads = {};
isolated map<int> requestCounts = {};
isolated int postSequence = 0;

# Stores an authorization code.
#
# + code - Code to store
public isolated function putAuthorizationCode(AuthorizationCode code) {
    lock {
        authorizationCodes[code.code] = code;
    }
}

# Removes and returns an authorization code. Codes are single use.
#
# + code - Code value
# + return - The code, or `()` if it was never issued or was already used
public isolated function takeAuthorizationCode(string code) returns AuthorizationCode? {
    lock {
        return authorizationCodes.removeIfHasKey(code);
    }
}

# Stores an access token. LinkedIn invalidates a member's earlier tokens when the app
# requests a different set of scopes, so those tokens are revoked here.
#
# + token - Token to store
# + return - Number of earlier tokens revoked
public isolated function issueAccessToken(AccessToken token) returns int {
    lock {
        string[] revoked = from AccessToken existing in accessTokens
            where existing.clientId == token.clientId && existing.memberSub == token.memberSub
                && !sameScopes(existing.scopes, token.scopes)
            select existing.value;
        foreach string value in revoked {
            _ = accessTokens.remove(value);
        }
        accessTokens[token.value] = token;
        return revoked.length();
    }
}

# Looks up an access token.
#
# + value - Token value
# + return - The token, or `()` if unknown
public isolated function getAccessToken(string value) returns AccessToken? {
    lock {
        return accessTokens[value];
    }
}

# Forgets an access token (the mock's revoke). Unknown tokens are fine, as RFC 7009 says.
#
# + value - Token value
# + return - True when a token was removed
public isolated function removeAccessToken(string value) returns boolean {
    lock {
        return accessTokens.removeIfHasKey(value) !is ();
    }
}

# Adds one to a request counter and returns the new count.
#
# + key - Counter key, for example the member and UTC day
# + return - Count after this request
public isolated function incrementRequestCount(string key) returns int {
    lock {
        int count = (requestCounts[key] ?: 0) + 1;
        requestCounts[key] = count;
        return count;
    }
}

# Returns the next post sequence number.
#
# + return - Sequence number, unique for the life of the process
public isolated function nextPostSequence() returns int {
    lock {
        postSequence += 1;
        return postSequence;
    }
}

# Stores a new post unless the same author posted the same text recently. The check and the
# insert share one lock so two identical requests can't both get through.
#
# + post - Post to store
# + since - Only posts created at or after this epoch second count as duplicates
# + return - URN of the duplicate, or `()` if the post was stored
public isolated function putPostIfNotDuplicate(Post post, decimal since) returns string? {
    lock {
        if post.commentary.trim() != "" {
            foreach Post existing in posts {
                if existing.authorUrn == post.authorUrn && existing.commentary == post.commentary
                        && existing.createdAt >= since {
                    return existing.urn;
                }
            }
        }
        posts[post.urn] = post;
        return ();
    }
}

# Applies changes to a post the author owns, atomically.
#
# + urn - Post URN
# + authorUrn - Person URN of the caller
# + changes - Fields to change
# + modifiedAt - Epoch second of the change
# + return - The updated post, or why it was not updated
public isolated function updatePost(string urn, string authorUrn, PostChanges changes, decimal modifiedAt)
        returns Post|UpdateFailure {
    lock {
        Post? post = posts[urn];
        if post is () {
            return POST_NOT_FOUND;
        }
        if post.authorUrn != authorUrn {
            return NOT_POST_AUTHOR;
        }
        Post updated = {
            urn: post.urn,
            authorUrn: post.authorUrn,
            reshareDisabled: post.reshareDisabled,
            'source: post.'source,
            parentUrn: post.parentUrn,
            mediaUrn: post.mediaUrn,
            articleUrl: post.articleUrl,
            articleTitle: post.articleTitle,
            createdAt: post.createdAt,
            commentary: changes.commentary ?: post.commentary,
            lifecycleState: changes.lifecycleState ?: post.lifecycleState,
            callToActionLabel: changes.callToActionLabel ?: post.callToActionLabel,
            landingPage: changes.landingPage ?: post.landingPage,
            lastModifiedAt: modifiedAt
        };
        posts[urn] = updated;
        return updated;
    }
}

# Looks up a post.
#
# + urn - Post URN
# + return - The post, or `()` if unknown
public isolated function getPost(string urn) returns Post? {
    lock {
        return posts[urn];
    }
}

# Removes a post.
#
# + urn - Post URN
public isolated function removePost(string urn) {
    lock {
        _ = posts.removeIfHasKey(urn);
    }
}

# Returns every stored post, oldest first.
#
# + return - Posts
public isolated function listPosts() returns Post[] {
    Post[] all;
    lock {
        all = posts.toArray().cloneReadOnly();
    }
    return from Post post in all
        order by post.createdAt ascending
        select post;
}

# Stores or replaces an upload.
#
# + upload - Upload to store
public isolated function putUpload(Upload upload) {
    lock {
        uploads[upload.uploadId] = upload;
    }
}

# Looks up an upload by its id.
#
# + uploadId - Upload id from the upload URL
# + return - The upload, or `()` if unknown
public isolated function getUpload(string uploadId) returns Upload? {
    lock {
        return uploads[uploadId];
    }
}

# Looks up an upload by its media URN.
#
# + mediaUrn - `urn:li:image:...` or `urn:li:digitalmediaAsset:...`
# + return - The upload, or `()` if unknown
public isolated function getUploadByMediaUrn(string mediaUrn) returns Upload? {
    lock {
        foreach Upload upload in uploads {
            if upload.mediaUrn == mediaUrn {
                return upload;
            }
        }
        return ();
    }
}

# Clears all state.
public isolated function reset() {
    lock {
        authorizationCodes.removeAll();
    }
    lock {
        accessTokens.removeAll();
    }
    lock {
        posts.removeAll();
    }
    lock {
        uploads.removeAll();
    }
    lock {
        requestCounts.removeAll();
    }
}

isolated function sameScopes(string[] left, string[] right) returns boolean {
    if left.length() != right.length() {
        return false;
    }
    foreach string scope in left {
        if right.indexOf(scope) is () {
            return false;
        }
    }
    return true;
}
