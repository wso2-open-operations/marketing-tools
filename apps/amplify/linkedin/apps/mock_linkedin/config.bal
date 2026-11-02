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

# Interface both listeners bind to. Use `0.0.0.0` in a container.
configurable string listenerHost = "localhost";

# Port for the `api.linkedin.com` host (Share API, userinfo).
configurable int apiPort = 9090;

# Port for the `www.linkedin.com` host (OAuth 2.0 and image uploads).
configurable int wwwPort = 9091;

# Public base URL of the `www` listener. Used to build image upload URLs.
configurable string wwwBaseUrl = "http://localhost:9091";

# OAuth client the mock accepts.
configurable string clientId = ?;
@display {label: "Client secret", kind: "password"}
configurable string clientSecret = ?;

# Redirect URIs registered for the OAuth client. Must match exactly.
configurable readonly & string[] redirectUris = ?;

# Access token lifetime. LinkedIn self-serve tokens last 60 days.
configurable int tokenTtlSeconds = 5184000;

# Authorization code lifetime. LinkedIn codes last 30 minutes.
configurable int authorizationCodeTtlSeconds = 1800;

# Requests allowed per member per UTC day.
configurable int memberDailyLimit = 150;

# Requests allowed per app per UTC day.
configurable int appDailyLimit = 100000;

# Largest image body `PUT /dms-uploads` accepts, in bytes. The body is read in chunks and refused as
# soon as it passes this, so an oversized upload is never buffered in full. LinkedIn's own image
# upload ceiling is 10 MB.
configurable int maxUploadBytes = 10485760;

# Exposes the mock admin endpoints (`/mock/posts`, `/mock/reset`). Keep off outside local testing.
configurable boolean enableMockAdmin = false;

# Shared key the admin endpoints require in `X-Amplify-Internal-Key`. Required when `enableMockAdmin`
# is true: with the flag on and no key set, the endpoints are not attached at all.
@display {label: "Mock admin key", kind: "password"}
configurable string mockAdminKey = "";

# The member every authorization signs in as.
configurable MockMember member = {
    sub: "782bbtaQ",
    givenName: "Avery",
    familyName: "Mock",
    email: "avery.mock@example.com",
    picture: "https://media.licdn.com/dms/image/mock/profile-displayphoto.jpg",
    locale: "en_US"
};
