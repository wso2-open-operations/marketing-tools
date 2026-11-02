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

// Egress from amplify-jobs (declared Choreo connections only): LinkedIn REST API and the Google Chat
// webhook. Each has its own pool, breaker and timeout (M9 bulkheads); neither retries at the HTTP level,
// the outbox does (ADR-025).

import amplify_common.crypto;
import amplify_common.googlechat;
import amplify_common.linkedin;

final linkedin:LinkedInAdapter? linkedInAdapter = check newLinkedInAdapter();
final WebhookChat? webhookChat = check newWebhookChat();
final NoveraClient? noveraClient = check newNoveraClient();
final crypto:TokenCipher? tokenCipher = check newTokenCipher();

isolated function newLinkedInAdapter() returns linkedin:LinkedInAdapter?|error {
    if linkedinClientId == "" {
        return ();
    }
    return check new linkedin:LinkedInAdapter({
        apiBaseUrl: linkedinApiBaseUrl,
        authBaseUrl: linkedinAuthBaseUrl,
        clientId: linkedinClientId,
        clientSecret: "",
        redirectUri: "",
        apiVersion: linkedinApiVersion,
        timeoutSeconds: linkedinTimeoutSeconds,
        apiResilience: linkedinApiResilience
    });
}

isolated function newWebhookChat() returns WebhookChat?|error {
    // AMPLIFY_ON_WEBHOOK off: no webhook client, so announcements never reach the space even if a URL is set.
    if !amplifyOnWebhook || chatWebhookUrl.trim() == "" {
        return ();
    }
    return new WebhookChat(check new googlechat:WebhookClient({webhookUrl: chatWebhookUrl,
        allowInsecureHttp: chatAllowInsecureHttp, timeoutSeconds: chatTimeoutSeconds, resilience: chatResilience}),
        chatSpace, chatMinIntervalSeconds);
}

isolated function newNoveraClient() returns NoveraClient?|error {
    // AMPLIFY_ON_NOVERA off, or the URL, token endpoint or credentials not set: Novera is not configured.
    if !amplifyOnNovera || noveraNotifyUrl.trim() == "" || noveraTokenUrl.trim() == "" || noveraClientId == ""
            || noveraClientSecret == "" {
        return ();
    }
    string[] scopes = from string scope in re `,`.split(noveraScopes)
        let string trimmed = scope.trim()
        where trimmed != ""
        select trimmed;
    return check new NoveraClient(noveraNotifyUrl, noveraTokenUrl, noveraClientId, noveraClientSecret, scopes,
        noveraTimeoutSeconds, allowInsecureHttp = noveraAllowInsecureHttp);
}

isolated function newTokenCipher() returns crypto:TokenCipher?|error {
    if tokenKeys.trim() == "" {
        return ();
    }
    crypto:TokenKey[] keys = [];
    foreach string item in re `,`.split(tokenKeys) {
        string[] parts = re `:`.split(item.trim());
        if parts.length() != 2 {
            return error("tokenKeys must be keyId:base64Key pairs");
        }
        keys.push(check crypto:keyFromBase64(parts[0], parts[1]));
    }
    return check new crypto:TokenCipher(keys, tokenCurrentKeyId);
}

# Breaker states for the run log and the `amplify_breaker_state` gauge: database, LinkedIn API, Google
# Chat (`NOT_CONFIGURED` when absent).
#
# + return - State by dependency
isolated function breakerStates() returns map<string> {
    linkedin:LinkedInAdapter? li = linkedInAdapter;
    WebhookChat? chat = webhookChat;
    NoveraClient? novera = noveraClient;
    return {
        database: dbBreaker.state(),
        linkedinApi: li is () ? "NOT_CONFIGURED" : li.breakers()["api"] ?: "CLOSED",
        googleChat: chat is () ? "NOT_CONFIGURED" : chat.breaker(),
        novera: novera is () ? "NOT_CONFIGURED" : novera.breaker()
    };
}

# Production dependencies of a run.
#
# + db - Jobs client
# + lockDb - Dedicated single-connection client for the run's advisory lock
# + return - Dependencies
isolated function productionDeps(PgRunStore db, PgRunLock lockDb) returns Deps => {
    runStore: db,
    runLock: lockDb,
    chat: webhookChat,
    novera: noveraClient,
    linkedIn: linkedInAdapter,
    cipher: tokenCipher,
    config: runConfig(),
    breakers: breakerStates
};

isolated function runConfig() returns RunConfig => {
    batchSize: runBatchSize,
    maxRows: runMaxRows,
    maxSeconds: runMaxSeconds,
    leaseSeconds: runLockLeaseSeconds,
    maxAttempts,
    backoffBaseSeconds,
    backoffMaxSeconds,
    deferSeconds,
    linkedinMaxPostsPerRun,
    linkedinMaxPostsPerDay,
    sharePageBaseUrl,
    chatSpace,
    cardAvatarUrl: chatCardAvatarUrl.trim() == "" ? () : chatCardAvatarUrl.trim(),
    defaultImageUrl: chatDefaultImageUrl.trim() == "" ? () : chatDefaultImageUrl.trim()
};
