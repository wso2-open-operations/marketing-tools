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

// Anti-corruption layer for Google Chat (S5 Announcements): cardsV2 builder and incoming-webhook client.
// Lives in amplify_common (ADR-020) next to the LinkedIn adapter; amplify-jobs sends, amplify-api only
// needs the types for the admin retry view.

import amplify_common.types;

import ballerina/lang.regexp;

# Longest summary shown on a card; longer text is cut with an ellipsis.
public const int CARD_SUMMARY_MAX_LENGTH = 400;
# Longest title shown on a card.
public const int CARD_TITLE_MAX_LENGTH = 120;
# Button label on the Club card.
public const string CARD_BUTTON_TEXT = "Amplify";
# Alt text of the header avatar.
public const string CARD_AVATAR_ALT_TEXT = "WSO2 Amplify";
# Card subtitle.
public const string CARD_SUBTITLE = "WSO2 Amplify · new post to share";
# Card subtitle for a priority campaign.
public const string CARD_SUBTITLE_PRIORITY = "WSO2 Amplify · priority post";

# What the Club card shows for one campaign (domains S5): image, title, summary, and an openLink button to
# One WSO2's Celebrate page with the campaign's share dialog open (incoming webhooks can't take button clicks).
public type CampaignCard record {|
    # Campaign id, used for the card id and thread key
    string campaignId;
    # Campaign title (plain text)
    string title;
    # Campaign summary (plain text)
    string? summary = ();
    # Public HTTPS image URL; the image widget is left out when it's missing or not public HTTPS
    string? imageUrl = ();
    # HTTPS link to One WSO2 Celebrate with this campaign's share dialog (`/amplify/celebrate?share=<id>`)
    string sharePageUrl;
    # Priority flag changes the subtitle
    boolean isPriority = false;
    # Public HTTPS Amplify avatar for the header; left out when missing or not public HTTPS
    string? avatarUrl = ();
    # Public HTTPS image shown when `imageUrl` is missing or not public HTTPS; the image widget is left out
    # when neither qualifies
    string? defaultImageUrl = ();
|};

# Thread key for a campaign's announcement (`announcement.thread_key`).
#
# + campaignId - Campaign id
# + return - `campaign-{id}`
public isolated function threadKey(string campaignId) returns string => "campaign-" + campaignId;

# Builds the cardsV2 message body for a campaign.
#
# + card - Card content
# + return - Chat message JSON, or `INVALID_CAMPAIGN` when the title is blank or the share link isn't HTTPS
public isolated function buildCampaignCard(CampaignCard card) returns json|types:DomainError {
    string title = card.title.trim();
    if title.length() == 0 {
        return types:domainError(types:ERR_INVALID_CAMPAIGN, "Card title is required");
    }
    if !types:isHttpsUrl(card.sharePageUrl) {
        return types:domainError(types:ERR_INVALID_CAMPAIGN, "Card share link must be HTTPS");
    }
    title = truncate(title, CARD_TITLE_MAX_LENGTH);
    json[] widgets = [];
    string? imageUrl = pickImage(card.imageUrl, card.defaultImageUrl);
    if imageUrl is string {
        widgets.push({image: {imageUrl, altText: title}});
    }
    string? summary = types:trimToNil(card.summary);
    if summary is string {
        widgets.push({textParagraph: {text: escapeHtml(truncate(summary, CARD_SUMMARY_MAX_LENGTH))}});
    }
    widgets.push({
        buttonList: {
            buttons: [
                {
                    text: CARD_BUTTON_TEXT,
                    onClick: {openLink: {url: card.sharePageUrl}}
                }
            ]
        }
    });
    return {
        cardsV2: [
            {
                cardId: threadKey(card.campaignId),
                card: {
                    header: header(title, card.isPriority, card.avatarUrl),
                    sections: [{widgets}]
                }
            }
        ]
    };
}

// The campaign's own image when Chat can fetch it, else the default image, else none.
isolated function pickImage(string? imageUrl, string? defaultImageUrl) returns string? {
    if imageUrl is string && isPublicHttpsUrl(imageUrl) {
        return imageUrl;
    }
    if defaultImageUrl is string && isPublicHttpsUrl(defaultImageUrl) {
        return defaultImageUrl;
    }
    return ();
}

isolated function header(string title, boolean isPriority, string? avatarUrl) returns json {
    map<json> header = {title, subtitle: isPriority ? CARD_SUBTITLE_PRIORITY : CARD_SUBTITLE};
    if avatarUrl is string && isPublicHttpsUrl(avatarUrl) {
        header["imageUrl"] = avatarUrl;
        header["imageType"] = "CIRCLE";
        header["imageAltText"] = CARD_AVATAR_ALT_TEXT;
    }
    return header;
}

# Whether Chat's servers can fetch the URL: HTTPS and not a local or private host. Chat fetches card
# images itself, so an intranet or expiring URL renders as a broken image.
#
# + url - Image URL
# + return - `true` when the URL is HTTPS to a public host name
public isolated function isPublicHttpsUrl(string url) returns boolean {
    if !types:isHttpsUrl(url) {
        return false;
    }
    string rest = url.substring(8).toLowerAscii();
    int end = rest.length();
    foreach string sep in ["/", "?", "#"] {
        int? i = rest.indexOf(sep);
        if i is int && i < end {
            end = i;
        }
    }
    string host = rest.substring(0, end);
    int? at = host.lastIndexOf("@");
    if at is int {
        host = host.substring(at + 1);
    }
    if host.startsWith("[") {
        return false; // IPv6 literal: never a public CDN host in practice
    }
    int? colon = host.indexOf(":");
    if colon is int {
        host = host.substring(0, colon);
    }
    if host.endsWith(".") {
        host = host.substring(0, host.length() - 1);
    }
    // Any IP literal form (dotted, decimal, hex, octal) ends in a numeric label; Chat CDNs use names.
    if types:isIpLiteralHost(host) {
        return false;
    }
    return host != "" && host != "localhost" && !host.endsWith(".localhost") && !host.endsWith(".local")
        && !host.endsWith(".internal") && host.includes(".");
}

# Escapes the characters Chat's text widgets read as HTML.
#
# + text - Plain text
# + return - Escaped text
public isolated function escapeHtml(string text) returns string =>
    re `[&<>"]`.replaceAll(text, isolated function(regexp:Groups groups) returns string {
        match groups[0].substring() {
            "&" => {
                return "&amp;";
            }
            "<" => {
                return "&lt;";
            }
            ">" => {
                return "&gt;";
            }
        }
        return "&quot;";
    });

isolated function truncate(string text, int max) returns string =>
    text.length() <= max ? text : text.substring(0, max - 1).trim() + "…";
