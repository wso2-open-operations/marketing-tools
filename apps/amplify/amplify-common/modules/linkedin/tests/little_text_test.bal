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

import ballerina/test;

@test:Config
function hashtagsBecomeTemplatesAndTheRestIsEscaped() {
    test:assertEquals(toLittleText("Go #Ballerina!"), "Go {hashtag|\\#|Ballerina}!");
    test:assertEquals(toLittleText("#first and (#second)"), "{hashtag|\\#|first} and \\({hashtag|\\#|second}\\)");
    test:assertEquals(toLittleText("Unicode #café2026"), "Unicode {hashtag|\\#|café2026}");
}

@test:Config
function notAHashtagStaysEscaped() {
    // Inside a word, alone, or followed by something that isn't a letter or digit.
    test:assertEquals(toLittleText("C# and # and #_x and a#b"), "C\\# and \\# and \\#\\_x and a\\#b");
    // Only the letters and digits are the tag; the underscore after it is escaped text.
    test:assertEquals(toLittleText("#tag_rest"), "{hashtag|\\#|tag}\\_rest");
}

@test:Config
function resolvedMentionUsesTheHeldNameAndUrn() {
    map<MentionTarget> targets = {
        "person:jane@wso2.com": {name: "Jane Smith", urn: "urn:li:person:abc123"},
        "org:wso2": {name: "WSO2", urn: "urn:li:organization:1234"}
    };
    test:assertEquals(toLittleText("Thanks @[Jay](amplify:person:jane@wso2.com) at @[WSO2](amplify:org:wso2)", targets),
            "Thanks @[Jane Smith](urn:li:person:abc123) at @[WSO2](urn:li:organization:1234)");
}

@test:Config
function unresolvedMentionIsPlainEscapedText() {
    test:assertEquals(toLittleText("Hi @[Bob](amplify:person:bob@wso2.com)"), "Hi \\@Bob");
}

@test:Config
function rawAnnotationTypedByTheCallerIsEscaped() {
    // A LinkedIn annotation typed by hand never reaches LinkedIn as one.
    test:assertEquals(toLittleText("@[CEO](urn:li:person:victim)"), "\\@\\[CEO\\]\\(urn:li:person:victim\\)");
    // Nor does a held target with a URN of the wrong shape.
    test:assertEquals(toLittleText("@[X](amplify:org:evil)", {"org:evil": {name: "X", urn: "javascript:alert(1)"}}),
            "\\@X");
}

@test:Config
function mentionNameIsEscaped() {
    test:assertEquals(toLittleText("@[A](amplify:person:a)", {"person:a": {name: "A (Team) *", urn: "urn:li:person:a1"}}),
            "@[A \\(Team\\) \\*](urn:li:person:a1)");
}
