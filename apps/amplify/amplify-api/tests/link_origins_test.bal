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

// campaignLinkOrigins parsing: lowercase, trimmed, empty entries dropped, and an empty setting means
// LinkedIn only (an unset descriptor value arrives as "").

import amplify_domain.campaign;

import ballerina/test;

@test:Config
function testLinkOriginsParse() {
    test:assertEquals(linkOrigins(" https://WWW.LinkedIn.com , ,http://localhost:19091 "),
            ["https://www.linkedin.com", "http://localhost:19091"]);
}

@test:Config
function testEmptyLinkOriginsMeanLinkedInOnly() {
    test:assertEquals(linkOrigins(""), campaign:DEFAULT_POST_LINK_ORIGINS);
    test:assertEquals(linkOrigins(" , "), campaign:DEFAULT_POST_LINK_ORIGINS);
}
