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

// OAuth 2.0 scopes.
const SCOPE_W_MEMBER_SOCIAL = "w_member_social";
const SCOPE_OPENID = "openid";
const SCOPE_PROFILE = "profile";
const SCOPE_EMAIL = "email";
final readonly & string[] SUPPORTED_SCOPES = [SCOPE_W_MEMBER_SOCIAL, SCOPE_OPENID, SCOPE_PROFILE, SCOPE_EMAIL];

// OAuth 2.0 protocol values.
const RESPONSE_TYPE_CODE = "code";
const GRANT_TYPE_AUTHORIZATION_CODE = "authorization_code";
const TOKEN_TYPE_BEARER = "Bearer";
const BEARER_PREFIX = "Bearer ";
const MOCK_CONSENT_DENY = "deny";

// OAuth 2.0 error codes, as LinkedIn returns them.
const OAUTH_INVALID_REQUEST = "invalid_request";
const OAUTH_INVALID_CLIENT = "invalid_client";
const OAUTH_INVALID_REDIRECT_URI = "invalid_redirect_uri";
const OAUTH_UNSUPPORTED_GRANT_TYPE = "unsupported_grant_type";
const OAUTH_UNSUPPORTED_RESPONSE_TYPE = "unsupported_response_type";
const OAUTH_UNAUTHORIZED_SCOPE = "unauthorized_scope_error";
const OAUTH_USER_CANCELLED = "user_cancelled_authorize";

// Request context keys.
const CTX_ACCESS_TOKEN = "accessToken";
const CTX_CORRELATION_ID = "correlationId";

// Headers.
const HEADER_AUTHORIZATION = "Authorization";
const HEADER_LINKEDIN_VERSION = "LinkedIn-Version";
const HEADER_RESTLI_PROTOCOL_VERSION = "X-Restli-Protocol-Version";
const HEADER_RESTLI_ID = "x-restli-id";
const HEADER_LI_UUID = "x-li-uuid";
const HEADER_LOCATION = "Location";
const RESTLI_PROTOCOL_VERSION = "2.0.0";

// URN prefixes.
const PERSON_URN_PREFIX = "urn:li:person:";
const SHARE_URN_PREFIX = "urn:li:share:";
const IMAGE_URN_PREFIX = "urn:li:image:";
const ASSET_URN_PREFIX = "urn:li:digitalmediaAsset:";

// Paths.
const VERSIONED_PATH_PREFIX = "rest";
const UPLOAD_PATH = "dms-uploads";
const MOCK_ADMIN_BASE_PATH = "mock";
final readonly & string[] USERINFO_PATH = ["v2", "userinfo"];

// Admin endpoints. Same header and key length as amplify-jobs' internal key, so one habit covers both.
const ADMIN_KEY_HEADER = "X-Amplify-Internal-Key";
const int MIN_ADMIN_KEY_LENGTH = 32;
const MSG_ADMIN_UNAUTHORIZED = "Unauthorized";

// Generated value shapes.
const OPAQUE_VALUE_PREFIX = "AQ";
const MEDIA_ID_PREFIX = "D4E10AQ";
const HEADER_MEDIA_TYPE_FAMILY = "media-type-family";
const MEDIA_TYPE_FAMILY_STILLIMAGE = "STILLIMAGE";
const HEALTH_STATUS_UP = "UP";

// Post rules.
const decimal DUPLICATE_WINDOW_SECONDS = 600;
const MAX_COMMENTARY_LENGTH = 3000;
const decimal UPLOAD_URL_TTL_SECONDS = 3600;
const UGC_MEDIA_NONE = "NONE";
const UGC_MEDIA_ARTICLE = "ARTICLE";
const UGC_MEDIA_IMAGE = "IMAGE";
const POST_SOURCE_REST = "REST";
const POST_SOURCE_UGC = "UGC";

// LinkedIn-style service error codes. Close to what LinkedIn sends, not guaranteed identical.
const SERVICE_ERROR_INVALID_TOKEN = 65600;
const SERVICE_ERROR_EXPIRED_TOKEN = 65601;
const SERVICE_ERROR_ACCESS_DENIED = 100;
const SERVICE_ERROR_THROTTLED = 101;

// Error messages.
const MSG_INVALID_TOKEN = "Invalid access token";
const MSG_EXPIRED_TOKEN = "The token used in the request has expired";
const MSG_MISSING_TOKEN = "Empty oauth2 access token";
const MSG_VERSION_MISSING = "A version must be present. Please specify a version by adding the LinkedIn-Version header.";
const MSG_PROTOCOL_VERSION = "X-Restli-Protocol-Version header must be 2.0.0";
const MSG_MEMBER_THROTTLED = "Resource level throttle 1 DAY limit for calls to this resource is reached.";
const MSG_APP_THROTTLED = "Application level throttle 1 DAY limit is reached.";
const MSG_INTERNAL_ERROR = "Internal server error";
const MSG_INVALID_REQUEST = "Invalid request. Check the headers, query parameters and body against the API contract.";
const MSG_RESOURCE_NOT_FOUND = "Resource not found";
const MSG_METHOD_NOT_ALLOWED = "Method not allowed";
const MSG_INVALID_UPLOAD_BODY = "Request body must be the image bytes";
const MSG_TOKEN_EXCHANGE_FAILED = "Unable to retrieve access token: appid/redirect uri/code verifier does not match authorization code. Or authorization code expired.";
