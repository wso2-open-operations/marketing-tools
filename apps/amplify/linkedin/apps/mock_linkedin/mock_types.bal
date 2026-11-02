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

// Types the OpenAPI tool could not generate, or that sit outside the Share API contract.

import ballerina/http;

# 413 for an upload body over `maxUploadBytes`.
public type ErrorPayloadTooLarge record {|
    *http:PayloadTooLarge;
    # Error body, in the shape the rest of the mock returns.
    Error body;
|};

// `CreateUgcPost` from the spec. Written by hand because the OpenAPI tool fails on the
// dotted `com.linkedin.ugc.*` property names in this schema.

# Legacy UGC share request.
public type CreateUgcPost record {
    # Person URN of the member.
    string author;
    # Only `PUBLISHED` is accepted on create
    "PUBLISHED" lifecycleState;
    # Share content
    CreateUgcPost_specificContent specificContent;
    # Who can see the share
    CreateUgcPost_visibility visibility;
};

public type CreateUgcPost_specificContent record {
    CreateUgcPost_shareContent com\.linkedin\.ugc\.ShareContent;
};

public type CreateUgcPost_shareContent record {
    CreateUgcPost_specificContent_com\.linkedin\.ugc\.ShareContent_shareCommentary shareCommentary;
    "NONE"|"ARTICLE"|"IMAGE" shareMediaCategory;
    CreateUgcPost_media[] media?;
};

public type CreateUgcPost_media record {
    "READY" status;
    # Asset URN (`urn:li:digitalmediaAsset:...`) for images.
    string media?;
    string originalUrl?;
    CreateUgcPost_text title?;
    CreateUgcPost_text description?;
};

public type CreateUgcPost_text record {
    string text?;
};

public type CreateUgcPost_visibility record {
    "PUBLIC"|"CONNECTIONS" com\.linkedin\.ugc\.MemberNetworkVisibility;
};

# The member the mock signs in as.
type MockMember readonly & record {|
    # Member id. The person URN is `urn:li:person:{sub}`
    string sub;
    # First name
    string givenName;
    # Last name
    string familyName;
    # Primary email, returned with the `email` scope
    string email;
    # Profile photo URL
    string picture;
    # Locale, for example `en_US`
    string locale;
|};

# OAuth 2.0 access token response.
type AccessTokenResponse record {|
    # Opaque bearer token
    string access_token;
    # Seconds until the token expires
    int expires_in;
    # Comma separated granted scopes
    string scope;
    # Always `Bearer`
    string token_type;
|};

# OAuth 2.0 error body.
type OAuthError record {|
    # OAuth 2.0 error code
    string 'error;
    # Human readable detail
    string error_description;
|};

type AccessTokenResponseOk record {|
    *http:Ok;
    AccessTokenResponse body;
|};

type OAuthErrorBadRequest record {|
    *http:BadRequest;
    OAuthError body;
|};

type OAuthErrorUnauthorized record {|
    *http:Unauthorized;
    OAuthError body;
|};

type ErrorMethodNotAllowed record {|
    *http:MethodNotAllowed;
    Error body;
|};

type ErrorInternalServerError record {|
    *http:InternalServerError;
    Error body;
|};
