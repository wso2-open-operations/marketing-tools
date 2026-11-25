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
function mentionTokensAreFoundInOrder() {
    MentionToken[] tokens = mentionTokens("Hi @[Jane Smith](amplify:person:jane@wso2.com) and @[WSO2](amplify:org:wso2)!");
    test:assertEquals(tokens.length(), 2);
    test:assertEquals(tokens[0].label, "Jane Smith");
    test:assertEquals(tokens[0].ref, "person:jane@wso2.com");
    test:assertEquals(tokens[1].ref, "org:wso2");
}

@test:Config
function malformedTokensAreNotMentions() {
    test:assertEquals(mentionTokens("@[x](urn:li:person:1) @[y](amplify:team:z) @[](amplify:person:a) @[a\nb](amplify:person:a)").length(), 0);
}

@test:Config
function lengthCountsUtf16UnitsAndMentionLabels() {
    test:assertEquals(commentaryLength("abc"), 3);
    // Mathematical sans-serif bold is outside the BMP: two UTF-16 units per letter.
    test:assertEquals(commentaryLength("𝗛𝗶"), 4);
    test:assertEquals(commentaryLength("a̶"), 2);
    test:assertEquals(commentaryLength("Hi @[Jane](amplify:person:jane@wso2.com)!"), 8);
}

@test:Config
function mentionRefsSplit() {
    test:assertEquals(splitMentionRef("person:jane@wso2.com"), ["person", "jane@wso2.com"]);
    test:assertEquals(splitMentionRef("org:wso2"), ["org", "wso2"]);
    test:assertEquals(splitMentionRef("team:x"), ());
    test:assertEquals(splitMentionRef("person:"), ());
}
