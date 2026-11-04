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

// Local people directory stub (D13). Two routes over one `directoryFile` (edit it; it's re-read on every call):
// `POST /graphql` answers the HR Entity `employees(filter, limit, offset)` query, which amplify-api and amplify-jobs
// read for team rosters and the leaver sweep; `GET /employees/basic-info` answers like people-app, which a local
// One WSO2 reads for leaderboard photos and names (CORS).
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

    # The HR Entity `employees` query: filters on `employeeStatus` and pages with `limit` / `offset`, as the service does.
    resource function post graphql(@http:Payload json request) returns http:Response|http:InternalServerError {
        json|error rows = io:fileReadJson(directoryFile);
        if rows !is json[] {
            log:printError("People stub can't read its directory", file = directoryFile);
            return <http:InternalServerError>{body: {message: "directory file is missing or not a JSON array"}};
        }
        json variables = request is map<json> ? request["variables"] : ();
        string[]? statuses = ();
        int 'limit = 1000;
        int offset = 0;
        if variables is map<json> {
            json f = variables["filter"];
            json st = f is map<json> ? f["employeeStatus"] : ();
            if st is json[] {
                statuses = from json x in st where x is string select <string>x;
            }
            json l = variables["limit"];
            json o = variables["offset"];
            'limit = l is int ? l : 1000;
            offset = o is int ? o : 0;
        }
        json[] listed = [];
        foreach json row in rows {
            json status = row is map<json> ? row["employeeStatus"] : ();
            if statuses is string[] && (status !is string || statuses.indexOf(status) is ()) {
                continue;
            }
            listed.push(row);
        }
        int end = int:min(offset + 'limit, listed.length());
        json[] page = offset >= listed.length() ? [] : listed.slice(offset, end);
        // Like the service, answer only the fields asked for: house comes only when the query names it.
        json queryText = request is map<json> ? request["query"] : ();
        if !(queryText is string && queryText.includes("house")) {
            page = from json row in page
                select withoutHouse(row);
        }
        http:Response res = new;
        res.statusCode = 200;
        res.setJsonPayload({data: {employees: page}});
        return res;
    }

    resource function get health() returns json => {status: "UP"};
}

# A row without its house fields.
#
# + row - A directory row
# + return - The row without `house` and `houseId`
isolated function withoutHouse(json row) returns json {
    if row is map<json> {
        map<json> copy = row.clone();
        _ = copy.removeIfHasKey("house");
        _ = copy.removeIfHasKey("houseId");
        return copy;
    }
    return row;
}
