// Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
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

import ballerina/test;

@test:Config {}
function profileUrlAcceptsLinkedInMemberUrls() {
    test:assertTrue(isProfileUrl("https://www.linkedin.com/in/scott-bechtel"));
    test:assertTrue(isProfileUrl("https://linkedin.com/in/scott-bechtel/"));
    test:assertTrue(isProfileUrl("https://www.linkedin.com/in/jos%C3%A9-garc%C3%ADa-123"));
}

@test:Config {}
function profileUrlRejectsEverythingElse() {
    test:assertFalse(isProfileUrl(""));
    test:assertFalse(isProfileUrl("http://www.linkedin.com/in/scott-bechtel"));
    test:assertFalse(isProfileUrl("https://www.linkedin.com/company/wso2"));
    test:assertFalse(isProfileUrl("https://www.linkedin.com.evil.com/in/scott-bechtel"));
    test:assertFalse(isProfileUrl("https://evil.com/?https://www.linkedin.com/in/scott-bechtel"));
    test:assertFalse(isProfileUrl("https://www.linkedin.com/in/scott-bechtel?utm=1"));
    test:assertFalse(isProfileUrl("https://www.linkedin.com/in/ab"));
}

@test:Config {}
function profileUrlRejectsABarePercent() {
    // `%` only counts as an escape when two hex digits follow it.
    test:assertFalse(isProfileUrl("https://www.linkedin.com/in/%zz-garcia"));
    test:assertFalse(isProfileUrl("https://www.linkedin.com/in/scott%"));
    test:assertFalse(isProfileUrl("https://www.linkedin.com/in/scott%0"));
    // A complete escape is accepted, whatever it decodes to; the pattern only checks the shape.
    test:assertTrue(isProfileUrl("https://www.linkedin.com/in/scott%C3%A9"));
}
