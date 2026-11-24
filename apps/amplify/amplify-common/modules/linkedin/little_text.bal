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

// Commentary to LinkedIn little text (Posts API `commentary`). Everything the employee typed is escaped,
// except a `#tag`, which becomes `{hashtag|\#|tag}`, and an Amplify mention token whose ref resolved,
// which becomes `@[Name](urn)` with the name and URN Amplify holds.
// Little text format: https://learn.microsoft.com/linkedin/marketing/community-management/shares/little-text-format

import amplify_common.types;

import ballerina/lang.regexp;

# Who a mention points at, as Amplify holds it (never as the caller typed it).
public type MentionTarget record {|
    # Text LinkedIn links. A member mention links when it matches one of the member's names (case sensitive),
    # an organization mention only when it matches the full name; otherwise LinkedIn shows plain text
    string name;
    # `urn:li:person:<id>` or `urn:li:organization:<id>`
    string urn;
|};

final regexp:RegExp TAG_CHAR = re `[\p{L}\p{N}]`;
final regexp:RegExp WORD_CHAR = re `[\p{L}\p{N}_\\&]`;
final regexp:RegExp TARGET_URN = re `urn:li:(?:person|organization):[A-Za-z0-9_\-]{1,64}`;

# Renders commentary as little text.
#
# + text - Commentary with mention tokens
# + targets - Resolved mentions by ref (`person:<employeeId>`, `org:<key>`); a token whose ref is missing
# is written as its label, escaped, with no link
# + return - Little text
public isolated function toLittleText(string text, map<MentionTarget> targets = {}) returns string {
    string[] parts = [];
    int cursor = 0;
    // What the reader sees right before the next stretch of text: a `#` straight after a mention is not at the
    // start of a word.
    string? shownBefore = ();
    foreach types:MentionToken token in types:mentionTokens(text) {
        parts.push(escapeWithHashtags(text.substring(cursor, token.startIndex), shownBefore));
        MentionTarget? target = targets[token.ref];
        string shown;
        if target is MentionTarget && TARGET_URN.isFullMatch(target.urn) && target.name.trim().length() > 0 {
            shown = target.name.trim();
            parts.push(string `@[${escapeLittleText(shown)}](${target.urn})`);
        } else {
            shown = "@" + token.label;
            parts.push(escapeLittleText(shown));
        }
        shownBefore = lastChar(shown);
        cursor = token.endIndex;
    }
    parts.push(escapeWithHashtags(text.substring(cursor), shownBefore));
    return string:'join("", ...parts);
}

# Escapes text, except that a `#` at the start of a word followed by letters or digits becomes LinkedIn's
# hashtag template. `C#`, `#` alone or `#_x` stay escaped.
#
# + text - Plain text
# + precededBy - The character the reader sees right before `text` (for example the end of a mention), or `()`
# when `text` starts the post
# + return - Little text
public isolated function escapeWithHashtags(string text, string? precededBy = ()) returns string {
    string[] parts = [];
    int length = text.length();
    int i = 0;
    int plainStart = 0;
    while i < length {
        string? previous = i == 0 ? precededBy : text.substring(i - 1, i);
        if text.substring(i, i + 1) == "#" && (previous is () || !WORD_CHAR.isFullMatch(previous)) {
            int j = i + 1;
            while j < length && TAG_CHAR.isFullMatch(text.substring(j, j + 1)) {
                j += 1;
            }
            if j > i + 1 {
                parts.push(escapeLittleText(text.substring(plainStart, i)));
                parts.push(string `{hashtag|\#|${text.substring(i + 1, j)}}`);
                i = j;
                plainStart = j;
                continue;
            }
        }
        i += 1;
    }
    parts.push(escapeLittleText(text.substring(plainStart)));
    return string:'join("", ...parts);
}

isolated function lastChar(string text) returns string? =>
    text.length() == 0 ? () : text.substring(text.length() - 1);
