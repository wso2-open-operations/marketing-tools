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

// amplify-jobs configuration (Config.toml / `BAL_CONFIG_VAR_*`; secrets from Choreo). Run tuning, the
// LinkedIn and Google Chat egress, and the token key ring.

import amplify_common.resilience;

// ---- Run ---------------------------------------------------------------------------------------------

# Outbox rows claimed per batch.
configurable int runBatchSize = 25;
# Most outbox rows one run handles (several batches).
configurable int runMaxRows = 200;
# Wall-clock budget of one run, seconds; must stay below `runLockLeaseSeconds`.
configurable int runMaxSeconds = 240;
# Lock lease on a claimed row, seconds. A row still locked after it is released by the next run.
configurable int runLockLeaseSeconds = 300;
# Attempts before an outbox row is `FAILED`.
configurable int maxAttempts = 8;
# Backoff for attempt 1, seconds; doubles each attempt.
configurable decimal backoffBaseSeconds = 30;
# Longest backoff, seconds.
configurable decimal backoffMaxSeconds = 3600;
# Wait before a deferred row (kill switch, rate ceiling, dependency not configured) is due again, seconds.
configurable decimal deferSeconds = 900;

// ---- LinkedIn ----------------------------------------------------------------------------------------

# REST API base (`mock_linkedin` locally). Empty client id = sharing deferred (not configured).
configurable string linkedinApiBaseUrl = "https://api.linkedin.com";
# OAuth base (unused by jobs today; the adapter needs it).
configurable string linkedinAuthBaseUrl = "https://www.linkedin.com";
# OAuth client id (the adapter needs it; jobs never runs OAuth).
configurable string linkedinClientId = "";
# `LinkedIn-Version` header.
configurable string linkedinApiVersion = "202610";
# Per-call timeout, seconds.
configurable decimal linkedinTimeoutSeconds = 10;
# Breaker, retry (keep 0, ADR-025) and pool for the LinkedIn REST API.
configurable resilience:HttpResilience linkedinApiResilience = {};
# LinkedIn posts per run (app quota protection).
configurable int linkedinMaxPostsPerRun = 50;
# LinkedIn posts per UTC day across runs, counted from published shares (app daily limit budget).
configurable int linkedinMaxPostsPerDay = 1000;

// ---- Google Chat (M6a) -------------------------------------------------------------------------------

# Incoming webhook URL of the target space (Choreo secret; never logged). Empty = announcements deferred.
# Local stack: points at the compose `chat-stub`; set `CHAT_WEBHOOK_URL` in local/.env to the dev test
# space's webhook to see real cards instead (runbook docs/runbooks/google-chat-webhook.md).
configurable string chatWebhookUrl = "";
# Local stack only: accept a plain-http webhook URL (the compose `chat-stub`). Never set in Choreo.
configurable boolean chatAllowInsecureHttp = false;
# Public HTTPS Amplify avatar shown in the card header. Empty = header without an avatar.
configurable string chatCardAvatarUrl = "";
# Public HTTPS image (PNG or JPEG; Chat doesn't render SVG) for cards whose post has no image or an unusable one.
# Chat fetches it anonymously, so it must be a stable, WSO2-controlled URL: host `img/WSO2-Amplify-Poster-Default.png`
# in the WSO2 media/CDN bucket and set its URL here. Do not point this at raw.githubusercontent.com in a deployed
# environment (an untracked third-party host, not a CDN, and it breaks if the fork or path moves). The file in this
# folder is the source asset only. Empty = such cards go out without an image.
configurable string chatDefaultImageUrl = "";
# Announce shares through Novera (feat/amplify_on_novera). Read from `AMPLIFY_ON_NOVERA` in local/.env, default true.
# Not acted on yet: the Novera sender does not exist, so nothing branches on this.
configurable boolean amplifyOnNovera = true;
# Announce shares through the Google Chat webhook above (`AMPLIFY_ON_WEBHOOK`, default false). Not acted on yet: the
# webhook client is still built whenever `chatWebhookUrl` is set, so announcements keep flowing until Novera lands.
configurable boolean amplifyOnWebhook = false;
// ---- Novera (Google Chat assistant) ---------------------------------------------------------------

# Novera's `POST /internal/notifications` URL (the Choreo gateway URL of Novera's API). Empty = Novera not configured.
configurable string noveraNotifyUrl = "";
# OAuth token endpoint for the client-credentials grant (an application subscribed to Novera's API).
configurable string noveraTokenUrl = "";
# Client id of that application.
configurable string noveraClientId = "";
# Client secret of that application (Choreo secret; never logged).
configurable string noveraClientSecret = "";
# Comma-separated scopes for the token; empty = none.
configurable string noveraScopes = "";
# Seconds before a Novera call (token or notification) gives up.
configurable decimal noveraTimeoutSeconds = 10;
# Local stack only: accept a plain-http notify URL (the `local/novera-mock`). Never set in Choreo.
configurable boolean noveraAllowInsecureHttp = false;

# Space label stored on `announcement.space`: `club` or `dev-test`.
configurable string chatSpace = "club";
# Per-call timeout, seconds.
configurable decimal chatTimeoutSeconds = 10;
# Breaker, retry (keep 0, ADR-025) and pool for the webhook.
configurable resilience:HttpResilience chatResilience = {};
# Least time between two posts to the space, seconds (Chat quota: 1 request/second per space).
configurable decimal chatMinIntervalSeconds = 1;
# One WSO2 Celebrate page URL; the card button opens `<url>?share=<campaignId>`, which shows that post's share dialog.
configurable string sharePageBaseUrl = "https://one.wso2.com/amplify/celebrate";

// ---- Token keys ----------------------------------------------------------------------------------------

# Token keys, `keyId:base64Key` comma separated (Choreo secret, same ring as amplify-api).
configurable string tokenKeys = "";
# Key id for new tokens (jobs only decrypts; the cipher still needs it).
configurable string tokenCurrentKeyId = "";
