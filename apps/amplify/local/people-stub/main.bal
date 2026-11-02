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

// Local people-app directory stub (D13). Answers `GET /employees/basic-info` like people-app: every current
// employee with name, photo, team and sub-team, from `directoryFile` (edit it; it's re-read on every call).
// amplify-api reads it for team rosters; a local One WSO2 reads it for leaderboard photos and names (CORS).
// No auth: never used outside the local stack and tests.

import ballerina/http;
import ballerina/io;
import ballerina/log;

# Listener port.
configurable int port = 9096;
# JSON array of directory rows.
configurable string directoryFile = "directory.json";
# Browser origins allowed to read it (a local One WSO2).
configurable string[] allowOrigins = ["http://localhost:3000"];

listener http:Listener stubListener = new (port);

@display {label: "People stub", id: "amplify/people-stub"}
@http:ServiceConfig {
    cors: {allowOrigins, allowCredentials: true, allowHeaders: ["Authorization", "Content-Type"], maxAge: 600}
}
service / on stubListener {

    resource function get employees/basic\-info() returns json[]|http:InternalServerError {
        json|error rows = io:fileReadJson(directoryFile);
        if rows is json[] {
            return rows;
        }
        log:printError("People stub can't read its directory", file = directoryFile);
        return <http:InternalServerError>{body: {message: "directory file is missing or not a JSON array"}};
    }

    resource function get health() returns json => {status: "UP"};
}
