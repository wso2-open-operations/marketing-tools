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
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

// lang.string only lower-cases ASCII (`toLowerAscii`), so `ÉQUIPE` and `équipe` would differ. Java's
// String.toLowerCase with Locale.ROOT folds every script the same way on every host (no Turkish-locale surprises).
import ballerina/jballerina.java;

# Lower-cases `text` in every script, not only ASCII (`ÉQUIPE` → `équipe`), the same on every host.
#
# + text - Text
# + return - The lower-cased text
public isolated function lowerCase(string text) returns string =>
    java:toString(stringToLowerCase(java:fromString(text), localeRoot())) ?: "";

isolated function stringToLowerCase(handle receiver, handle locale) returns handle = @java:Method {
    'class: "java.lang.String",
    name: "toLowerCase",
    paramTypes: ["java.util.Locale"]
} external;

isolated function localeRoot() returns handle = @java:FieldGet {
    'class: "java.util.Locale",
    name: "ROOT"
} external;
