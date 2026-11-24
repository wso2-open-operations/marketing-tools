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

// Commentary with mention tokens. The UI writes `@[<label>](amplify:<ref>)` where the typeahead put a
// mention; `<ref>` is `person:<employeeId>` or `org:<key>`. The token only names who is meant: the jobs
// worker looks the ref up again and writes LinkedIn's annotation from what Amplify holds, never from the
// label or anything else the caller typed.

import ballerina/lang.regexp;

# Most mention tokens in one commentary.
public const int MENTION_MAX_COUNT = 20;
# Mention ref prefix for a colleague, followed by the employee id.
public const string MENTION_PERSON = "person";
# Mention ref prefix for an organization, followed by its configured key.
public const string MENTION_ORG = "org";

# A mention token found in commentary.
public type MentionToken record {|
    # Text the employee saw (only used for length and as plain text when the ref can't be resolved)
    string label;
    # `person:<employeeId>` or `org:<key>`
    string ref;
    # Start of the token in the commentary (code points)
    int startIndex;
    # End of the token, exclusive
    int endIndex;
|};

final regexp:RegExp MENTION_TOKEN = re `@\[([^\[\]\r\n]{1,100})\]\(amplify:((?:person|org):[A-Za-z0-9._@:|+\-]{1,128})\)`;

# Mention tokens in commentary, in order.
#
# + text - Commentary
# + return - Tokens
public isolated function mentionTokens(string text) returns MentionToken[] {
    MentionToken[] tokens = [];
    foreach regexp:Groups groups in MENTION_TOKEN.findAllGroups(text) {
        regexp:Span whole = groups[0];
        regexp:Span? label = groups[1];
        regexp:Span? ref = groups[2];
        if label is regexp:Span && ref is regexp:Span {
            tokens.push({label: label.substring(), ref: ref.substring(), startIndex: whole.startIndex,
                endIndex: whole.endIndex});
        }
    }
    return tokens;
}

# Length of commentary as it shows on LinkedIn, the way the UI counts it: UTF-16 code units (an astral
# character such as Unicode bold counts 2), with each mention token counted as its label only. LinkedIn
# doesn't document how it counts, so both sides use this one rule.
#
# + text - Commentary with mention tokens
# + return - Length
public isolated function commentaryLength(string text) returns int {
    int total = 0;
    int cursor = 0;
    foreach MentionToken token in mentionTokens(text) {
        total += utf16Length(text.substring(cursor, token.startIndex)) + utf16Length(token.label);
        cursor = token.endIndex;
    }
    return total + utf16Length(text.substring(cursor));
}

# Splits a mention ref into its kind and key.
#
# + ref - `person:<employeeId>` or `org:<key>`
# + return - `[kind, key]`, or `()` when the ref has another shape
public isolated function splitMentionRef(string ref) returns [string, string]? {
    int? colon = ref.indexOf(":");
    if colon is () || colon == 0 || colon == ref.length() - 1 {
        return ();
    }
    string kind = ref.substring(0, colon);
    if kind != MENTION_PERSON && kind != MENTION_ORG {
        return ();
    }
    return [kind, ref.substring(colon + 1)];
}

isolated function utf16Length(string text) returns int {
    int units = 0;
    foreach int codePoint in text.toCodePointInts() {
        units += codePoint > 0xFFFF ? 2 : 1;
    }
    return units;
}
