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


// Contract tests from openapi.yaml (plan M5): every operation in the spec reaches a resource, its
// `x-access` matches the activity matrix, every matrix route is in the spec, and the main responses
// validate against their schemas (a small validator: required, type, nullable, enum, $ref, items).

import amplify_api.auth;

import ballerina/http;
import ballerina/test;
import ballerina/yaml;

const string SAMPLE_UUID = "01900000-0000-7000-8000-0000000000aa";
final string[] & readonly HTTP_METHODS = ["get", "post", "put", "patch", "delete"];

function spec() returns map<json>|error {
    json doc = check yaml:readFile("openapi.yaml");
    return doc.cloneWithType();
}

function schemas() returns map<json>|error {
    map<json> doc = check spec();
    return (check doc.components.schemas).cloneWithType();
}

# Validates a value against a schema.
#
# + value - Value
# + schema - Schema (may be a `$ref`)
# + all - `components.schemas`
# + at - Location for messages
# + return - Problems found
function validate(json value, json schema, map<json> all, string at = "$") returns string[] {
    if schema !is map<json> {
        return [];
    }
    json ref = schema["$ref"];
    if ref is string {
        string name = ref.substring(ref.lastIndexOf("/") is int ? <int>ref.lastIndexOf("/") + 1 : 0);
        return validate(value, all[name], all, at);
    }
    if value is () {
        return schema["nullable"] == true || !schema.hasKey("type") ? [] : [at + ": null not allowed"];
    }
    string[] errors = [];
    json enumValues = schema["enum"];
    if enumValues is json[] && enumValues.indexOf(value) is () {
        errors.push(string `${at}: ${value.toString()} not in enum`);
    }
    match schema["type"] {
        "object" => {
            if value !is map<json> {
                return [at + ": expected object"];
            }
            json required = schema["required"];
            if required is json[] {
                foreach json r in required {
                    if r is string && !value.hasKey(r) {
                        errors.push(string `${at}.${r}: missing`);
                    }
                }
            }
            json props = schema["properties"];
            if props is map<json> {
                foreach [string, json] [k, v] in value.entries() {
                    if props.hasKey(k) {
                        errors.push(...validate(v, props[k], all, at + "." + k));
                    }
                }
            }
        }
        "array" => {
            if value !is json[] {
                return [at + ": expected array"];
            }
            foreach int i in 0 ..< value.length() {
                errors.push(...validate(value[i], schema["items"], all, string `${at}[${i}]`));
            }
        }
        "string" => {
            if value !is string {
                errors.push(at + ": expected string");
            }
        }
        "integer" => {
            if value !is int {
                errors.push(at + ": expected integer");
            }
        }
        "number" => {
            if value !is int && value !is decimal && value !is float {
                errors.push(at + ": expected number");
            }
        }
        "boolean" => {
            if value !is boolean {
                errors.push(at + ": expected boolean");
            }
        }
    }
    return errors;
}

# Asserts a response body matches a named schema.
#
# + res - Response
# + schemaName - `components.schemas` key
# + return - An error on failure
function assertShape(http:Response res, string schemaName) returns error? {
    map<json> all = check schemas();
    json body = check res.getJsonPayload();
    string[] errors = validate(body, all[schemaName], all);
    test:assertEquals(errors, [], string `${schemaName}: ${body.toJsonString()}`);
}

function operations() returns [string, string, map<json>][]|error {
    map<json> doc = check spec();
    map<json> paths = check doc["paths"].cloneWithType();
    [string, string, map<json>][] ops = [];
    foreach [string, json] [path, item] in paths.entries() {
        map<json> methods = check item.cloneWithType();
        foreach string m in HTTP_METHODS {
            json op = methods[m];
            if op is map<json> {
                ops.push([m.toUpperAscii(), path, op]);
            }
        }
    }
    return ops;
}

function concrete(string template) returns string =>
    re `\{[^}]+\}`.replaceAll(template, SAMPLE_UUID);

function segments(string path) returns string[] => re `/`.split(path.substring(1));

@test:Config
function testEveryOperationInTheSpecHasAResource() returns error? {
    string token = check mint(groupsClaim(PO_GROUP, MARKETING_GROUP, SLT_GROUP, ADMIN_GROUP));
    [string, string, map<json>][] ops = check operations();
    test:assertTrue(ops.length() >= 34, "the contract lists every M5 operation");
    foreach [string, string, map<json>] [method, path, _] in ops {
        http:Response res = check api->execute(method, concrete(path), method == "GET" || method == "DELETE" ? () : {},
                {"x-jwt-assertion": token});
        json|error payload = res.getJsonPayload();
        string detail = "";
        if payload is map<json> {
            detail = (payload["detail"] ?: "").toString();
        }
        test:assertTrue(res.statusCode != 405 && detail != "No such resource" && res.statusCode != 403,
                string `${method} ${path}: ${res.statusCode} ${detail}`);
    }
}

@test:Config
function testSpecAccessMatchesTheActivityMatrix() returns error? {
    [string, string, map<json>][] ops = check operations();
    string[] specRoutes = [];
    foreach [string, string, map<json>] [method, path, op] in ops {
        specRoutes.push(method + " " + path);
        string access = check op["x-access"].ensureType();
        if access == "PUBLIC" {
            test:assertTrue(auth:isPublic(segments(path)), path + " is public in the spec only");
            continue;
        }
        auth:Rule? rule = auth:findRule(method, segments(concrete(path)));
        if rule is () {
            test:assertFail(string `${method} ${path} is missing from the activity matrix`);
        }
        test:assertEquals(access, rule.requires, string `${method} ${path} x-access`);
    }
    foreach auth:Rule rule in auth:ACTIVITY_MATRIX {
        if rule.path.startsWith("/reports/") {
            continue; // phase 2
        }
        test:assertTrue(specRoutes.indexOf(rule.method + " " + rule.path) !is (),
                string `${rule.method} ${rule.path} is in the matrix but not in openapi.yaml`);
    }
}

@test:Config
function testProblemShapeOnErrors() returns error? {
    http:Response res = check api->execute("POST", "/external-shares", "{not json", {
        "x-jwt-assertion": check mint(),
        "Content-Type": "application/json"
    });
    test:assertEquals(res.statusCode, 400);
    test:assertEquals(res.getContentType(), "application/problem+json");
    check assertShape(res, "Problem");
    json body = check res.getJsonPayload();
    test:assertEquals(check body.code, "VALIDATION_FAILED");
}
