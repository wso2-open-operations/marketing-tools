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

import amplify_common.types;

import ballerina/http;
import ballerina/test;

const int CHAT_STUB_PORT = 18211;

isolated string lastQuery = "";
// Raw request target of the last call, to prove the key and token reach Chat unchanged
isolated string lastTarget = "";

listener http:Listener chatListener = new (CHAT_STUB_PORT);

service /v1/spaces on chatListener {
    resource function post [string space]/messages(http:Request req, @http:Payload json body)
            returns http:Ok|http:BadRequest|http:TooManyRequests|http:ServiceUnavailable {
        map<string[]> params = req.getQueryParams();
        lock {
            lastTarget = req.rawPath;
        }
        lock {
            lastQuery = string `${params["key"].toString()}|${params["threadKey"].toString()}|${
                params["messageReplyOption"].toString()}`;
        }
        if space == "busy" {
            return <http:TooManyRequests>{};
        }
        if space == "down" {
            return <http:ServiceUnavailable>{};
        }
        json|error cards = body.cardsV2;
        if cards !is json[] {
            return <http:BadRequest>{};
        }
        if space == "noname" {
            return <http:Ok>{body: {thread: {}}};
        }
        return <http:Ok>{body: {name: string `spaces/${space}/messages/m1`, thread: {name: string `spaces/${space}/threads/t1`}}};
    }
}

// Snapshot of the Club card (domains S5). Update deliberately if the card design changes.
final json & readonly EXPECTED_CARD = {
    cardsV2: [
        {
            cardId: "campaign-0192f0c4-0000-7000-8000-000000000001",
            card: {
                header: {
                    title: "WSO2 named a Leader <again>",
                    subtitle: "WSO2 Amplify · priority post",
                    imageUrl: "https://media.wso2.com/amplify-avatar.png",
                    imageType: "CIRCLE",
                    imageAltText: "WSO2 Amplify"
                },
                sections: [
                    {
                        widgets: [
                            {image: {imageUrl: "https://media.wso2.com/leader.png", altText: "WSO2 named a Leader <again>"}},
                            {textParagraph: {text: "Read why &amp; share it &lt;today&gt;"}},
                            {
                                buttonList: {
                                    buttons: [
                                        {
                                            text: "Amplify",
                                            onClick: {
                                                openLink: {
                                                    url: "https://one.wso2.com/amplify/campaigns/0192f0c4-0000-7000-8000-000000000001"
                                                }
                                            }
                                        }
                                    ]
                                }
                            }
                        ]
                    }
                ]
            }
        }
    ]
};

@test:Config
function campaignCardSnapshot() returns error? {
    json card = check buildCampaignCard({
        campaignId: "0192f0c4-0000-7000-8000-000000000001",
        title: "  WSO2 named a Leader <again> ",
        summary: "Read why & share it <today>",
        imageUrl: "https://media.wso2.com/leader.png",
        sharePageUrl: "https://one.wso2.com/amplify/campaigns/0192f0c4-0000-7000-8000-000000000001",
        isPriority: true,
        avatarUrl: "https://media.wso2.com/amplify-avatar.png"
    });
    test:assertEquals(card, EXPECTED_CARD);
}

@test:Config
function cardDropsNonHttpsImageAndBlankSummary() returns error? {
    json card = check buildCampaignCard({campaignId: "c1", title: "T", summary: "  ", imageUrl: "http://x.com/a.png",
        sharePageUrl: "https://one.wso2.com/s/c1", avatarUrl: "https://localhost/a.png"});
    test:assertEquals(card, {
        cardsV2: [
            {
                cardId: "campaign-c1",
                card: {
                    header: {title: "T", subtitle: CARD_SUBTITLE},
                    sections: [
                        {
                            widgets: [
                                {buttonList: {buttons: [{text: "Amplify", onClick: {openLink: {url: "https://one.wso2.com/s/c1"}}}]}}
                            ]
                        }
                    ]
                }
            }
        ]
    });
}

@test:Config
function cardTruncatesLongSummary() returns error? {
    string long = "";
    foreach int i in 0 ..< 500 {
        long += "x";
    }
    json card = check buildCampaignCard({campaignId: "c1", title: "T", summary: long, sharePageUrl: "https://a.com/s"});
    json[] cards = <json[]>check card.cardsV2;
    json[] sections = <json[]>check cards[0].card.sections;
    json[] widgets = <json[]>check sections[0].widgets;
    string text = <string>check widgets[0].textParagraph.text;
    test:assertEquals(text.length(), CARD_SUMMARY_MAX_LENGTH);
    test:assertTrue(text.endsWith("…"));
}

@test:Config
function cardNeedsTitleAndHttpsLink() {
    json|types:DomainError noTitle = buildCampaignCard({campaignId: "c1", title: " ", sharePageUrl: "https://a.com"});
    test:assertTrue(noTitle is types:DomainError);
    json|types:DomainError httpLink = buildCampaignCard({campaignId: "c1", title: "T", sharePageUrl: "http://a.com/x"});
    test:assertTrue(httpLink is types:DomainError);
}

@test:Config
function webhookPostsThreadedAndReturnsMessageName() returns error? {
    WebhookClient chat = check new ({
        webhookUrl: string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/club/messages?key=k1&token=t1`
    });
    json card = check buildCampaignCard({campaignId: "c1", title: "T", sharePageUrl: "https://a.com/s"});
    ChatMessage message = check chat.post(card, threadKey("c1"));
    test:assertEquals(message, {name: "spaces/club/messages/m1", threadName: "spaces/club/threads/t1"});
    string query;
    lock {
        query = lastQuery;
    }
    test:assertEquals(query, "[\"k1\"]|[\"campaign-c1\"]|[\"REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD\"]");
}

@test:Config
function webhookRateLimitIsRetryable() returns error? {
    WebhookClient chat = check new ({webhookUrl: string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/busy/messages?key=k`});
    ChatMessage|ChatError result = chat.post({text: "x"}, "campaign-c1");
    if result !is ChatError {
        test:assertFail("expected a rate limit error");
    }
    test:assertEquals(result.detail().code, "RATE_LIMITED");
    test:assertTrue(result.detail().retryable);
    test:assertFalse(result.message().includes("key="), "never echo the webhook URL");
}

@test:Config
function webhookRefusesPlainHttpRemote() {
    WebhookClient|error chat = new ({webhookUrl: "http://chat.googleapis.com/v1/spaces/x/messages"});
    test:assertTrue(chat is ChatError);
}

@test:Config
function cardOmitsNonPublicImages() returns error? {
    foreach string url in ["https://localhost/a.png", "https://10.1.2.3/a.png", "https://192.168.0.4/a.png",
            "https://172.20.0.1/a.png", "https://intranet/a.png", "https://user@127.0.0.1:8443/a.png",
            "https://[::1]/a.png", ""] {
        test:assertFalse(isPublicHttpsUrl(url), url);
        json card = check buildCampaignCard({campaignId: "c1", title: "T", imageUrl: url,
            sharePageUrl: "https://a.com/s"});
        test:assertFalse(card.toJsonString().includes("\"image\""), "image widget left out for " + url);
    }
    test:assertTrue(isPublicHttpsUrl("https://media.licdn.com/dms/image/x.png?e=1&v=beta"));
    test:assertFalse(isPublicHttpsUrl("https://172.32.0.1/a.png"), "IP literals are never card image hosts");
}

@test:Config
function webhookBadCardIsRejectedNotRetryable() returns error? {
    WebhookClient chat = check new ({webhookUrl: string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/club/messages?key=k&token=SECRET`});
    ChatMessage|ChatError result = chat.post({text: "no cardsV2"}, "campaign-c1");
    if result !is ChatError {
        test:assertFail("expected a rejection");
    }
    test:assertEquals(result.detail(), {code: "REJECTED", httpStatus: 400, retryable: false});
}

@test:Config
function webhookServerErrorAndNoResponseAreRetryable() returns error? {
    WebhookClient down = check new ({webhookUrl: string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/down/messages?key=k&token=SECRET`});
    ChatMessage|ChatError result = down.post({text: "x"}, "campaign-c1");
    if result !is ChatError {
        test:assertFail("expected an outage");
    }
    test:assertEquals(result.detail(), {code: "UNAVAILABLE", httpStatus: 503, retryable: true});

    WebhookClient gone = check new ({webhookUrl: "http://localhost:1/v1/spaces/x/messages?key=k&token=SECRET",
        timeoutSeconds: 2});
    ChatMessage|ChatError none = gone.post({text: "x"}, "campaign-c1");
    if none !is ChatError {
        test:assertFail("expected no response");
    }
    test:assertEquals(none.detail(), {code: "UNAVAILABLE", httpStatus: (), retryable: true});
}

// The webhook URL carries the space key and token: no error the client returns may echo any of it, so
// a caller that logs or stores the error (`announcement.last_error`) can't leak it.
@test:Config
function webhookErrorsNeverCarryTheUrl() returns error? {
    string[] urls = [
        string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/busy/messages?key=KEY123&token=TOKEN456`,
        string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/down/messages?key=KEY123&token=TOKEN456`,
        string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/club/messages?key=KEY123&token=TOKEN456`,
        "http://localhost:1/v1/spaces/x/messages?key=KEY123&token=TOKEN456"
    ];
    foreach string url in urls {
        WebhookClient chat = check new ({webhookUrl: url, timeoutSeconds: 2});
        ChatMessage|ChatError result = chat.post({text: "bad"}, "campaign-c1");
        if result !is ChatError {
            test:assertFail("expected an error for " + url);
        }
        string seen = result.message() + result.detail().toString() + result.toString();
        foreach string secret in ["KEY123", "TOKEN456", "/v1/spaces/", "localhost"] {
            test:assertFalse(seen.includes(secret), string `error leaks ${secret}`);
        }
    }
    WebhookClient|error bad = new ({webhookUrl: "http://chat.googleapis.com/v1/spaces/x/messages?token=TOKEN456"});
    test:assertTrue(bad is error && !bad.toString().includes("TOKEN456"));
}

@test:Config
function webhookInsecureHttpOnlyWhenAllowed() {
    WebhookClient|error stub = new ({webhookUrl: "http://chat-stub:9095/v1/spaces/local/messages", allowInsecureHttp: true});
    test:assertTrue(stub is WebhookClient);
}

// Regression (deep review RC-04): a prefix check let `http://localhost.<anything>` through, so the webhook
// key and token went out in clear text to a remote host.
@test:Config
function webhookPlainHttpOnlyForExactLoopbackHosts() {
    foreach string url in ["http://localhost.attacker.example/v1/spaces/x/messages?key=k",
            "http://127.0.0.1.nip.io/v1/spaces/x/messages?key=k", "http://localhostevil.com/v1/spaces/x/messages",
            "http://localhost@evil.example/v1/spaces/x/messages"] {
        WebhookClient|error chat = new ({webhookUrl: url});
        test:assertTrue(chat is ChatError, url);
    }
    foreach string url in ["http://localhost:8080/v1/spaces/x/messages", "http://127.0.0.1/v1/spaces/x/messages",
            "http://user@localhost:1/x"] {
        WebhookClient|error chat = new ({webhookUrl: url});
        test:assertTrue(chat is WebhookClient, url);
    }
}

// Regression (deep review RC-05): a trailing-dot local name and hex / decimal IP forms counted as public.
@test:Config
function cardImageRejectsTrailingDotAndNumericHosts() {
    foreach string url in ["https://localhost./a.png", "https://0x7f.0.0.1/a.png", "https://127.1/a.png",
            "https://2130706433/a.png", "https://8.8.8.8/a.png", "https://foo.internal./a.png"] {
        test:assertFalse(isPublicHttpsUrl(url), url);
    }
    test:assertTrue(isPublicHttpsUrl("https://cdn.wso2.com./logo.png"), "a fully qualified public name is fine");
    // A numeric *first* label is a name, not an IP literal: the old private-range regex dropped it.
    test:assertTrue(isPublicHttpsUrl("https://10.cdn.example.com/logo.png"));
}

@test:Config
function cardTruncatesLongTitle() returns error? {
    string long = "";
    foreach int i in 0 ..< 200 {
        long += "t";
    }
    json card = check buildCampaignCard({campaignId: "c1", title: long, sharePageUrl: "https://a.com/s"});
    json[] cards = <json[]>check card.cardsV2;
    string title = <string>check cards[0].card.header.title;
    test:assertEquals(title.length(), CARD_TITLE_MAX_LENGTH);
    test:assertTrue(title.endsWith("…"));
}

@test:Config
function escapeHtmlCoversQuotes() {
    test:assertEquals(escapeHtml("a \"b\" <c> & d"), "a &quot;b&quot; &lt;c&gt; &amp; d");
}

@test:Config
function webhookBadResponseBodyAndBreakerState() returns error? {
    WebhookClient chat = check new ({webhookUrl: string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/noname/messages?key=k`});
    test:assertEquals(chat.breaker(), "CLOSED");
    ChatMessage|ChatError result = chat.post({cardsV2: []}, "campaign-c1");
    if result !is ChatError {
        test:assertFail("expected BAD_RESPONSE");
    }
    test:assertEquals(result.detail(), {code: "BAD_RESPONSE", httpStatus: 200, retryable: false});
}

const string DEFAULT_IMAGE = "https://media.wso2.com/amplify-default.png";

@test:Config
function cardUsesTheDefaultImageWhenThePostHasNone() returns error? {
    foreach string? url in [(), "", "http://x.com/a.png", "https://intranet/a.png", "https://localhost/a.png"] {
        json card = check buildCampaignCard({campaignId: "c1", title: "T", imageUrl: url,
            sharePageUrl: "https://a.com/s", defaultImageUrl: DEFAULT_IMAGE});
        test:assertTrue(card.toJsonString().includes(string `"image":{"imageUrl":"${DEFAULT_IMAGE}", "altText":"T"}`),
            "default image for " + url.toString());
    }
}

@test:Config
function cardKeepsThePostImageOverTheDefault() returns error? {
    json card = check buildCampaignCard({campaignId: "c1", title: "T", imageUrl: "https://media.wso2.com/leader.png",
        sharePageUrl: "https://a.com/s", defaultImageUrl: DEFAULT_IMAGE});
    string text = card.toJsonString();
    test:assertTrue(text.includes("https://media.wso2.com/leader.png"));
    test:assertFalse(text.includes(DEFAULT_IMAGE));
}

@test:Config
function cardLeavesImageOutWhenTheDefaultIsUnusable() returns error? {
    json card = check buildCampaignCard({campaignId: "c1", title: "T", sharePageUrl: "https://a.com/s",
        defaultImageUrl: "http://localhost/default.png"});
    test:assertFalse(card.toJsonString().includes("\"image\""));
}

// The transport is the JDK client (transport.bal), so the key and token must still arrive in the query,
// intact, next to the thread parameters.
@test:Config
function webhookKeyAndTokenReachChatUnchanged() returns error? {
    WebhookClient chat = check new ({
        webhookUrl: string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/club/messages?key=TESTKEY456&token=TESTTOKEN123`
    });
    ChatMessage|ChatError result = chat.post({cardsV2: []}, "campaign-c1", "corr-1");
    test:assertTrue(result is ChatMessage, "post should succeed");
    string target;
    lock {
        target = lastTarget;
    }
    test:assertTrue(target.includes("key=TESTKEY456&token=TESTTOKEN123"), "key and token sent as given");
    test:assertTrue(target.includes("threadKey=campaign-c1"));
}

// Guard against the leak that came with `ballerina/http`: its client spans carry the request URL as
// `http.url`. The webhook client must hold no `http:Client`, and the sending code must stay in
// transport.bal (scripts/check-chat-transport.sh enforces the same on the sources).
@test:Config
function webhookFailureTextsAreFixedStrings() returns error? {
    string[] urls = [
        "http://localhost:1/v1/spaces/x/messages?key=TESTKEY456&token=TESTTOKEN123",
        string `http://localhost:${CHAT_STUB_PORT}/v1/spaces/busy/messages?key=TESTKEY456&token=TESTTOKEN123`
    ];
    foreach string url in urls {
        WebhookClient chat = check new ({webhookUrl: url, timeoutSeconds: 2});
        ChatMessage|ChatError result = chat.post({cardsV2: []}, "t");
        if result !is ChatError {
            test:assertFail("expected an error");
        }
        // stack trace frames and causes count too
        string seen = result.toString() + result.stackTrace().toString() + (result.cause() is error ? (<error>result.cause()).toString() : "none");
        foreach string secret in ["TESTKEY456", "TESTTOKEN123", "token=", "key="] {
            test:assertFalse(seen.includes(secret), string `error leaks ${secret}`);
        }
    }
}

// The breaker went with the `ballerina/http` client: refused calls open it, then it refuses without calling.
@test:Config
function webhookBreakerOpensAfterRepeatedFailures() returns error? {
    WebhookClient chat = check new ({
        webhookUrl: "http://localhost:1/v1/spaces/x/messages?key=TESTKEY456&token=TESTTOKEN123",
        timeoutSeconds: 2,
        resilience: {requestVolumeThreshold: 2, failureThreshold: 0.5, resetTimeSeconds: 30}
    });
    test:assertEquals(chat.breaker(), "CLOSED");
    foreach int _ in 0 ..< 2 {
        ChatMessage|ChatError r = chat.post({cardsV2: []}, "t");
        test:assertTrue(r is ChatError && r.message() == "Chat webhook call failed: no response");
    }
    test:assertEquals(chat.breaker(), "OPEN");
    ChatMessage|ChatError open = chat.post({cardsV2: []}, "t");
    test:assertTrue(open is ChatError && open.message() == "Chat webhook breaker is open" && open.detail().retryable);
}
