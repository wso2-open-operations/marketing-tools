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

// Contract drift guard: every response enum and the stable problem codes in openapi.yaml must match what the
// code can emit, both ways. The api's own value sets are read from the Ballerina source (`type X "A"|"B"`
// singleton unions and `const string X = "..."` codes), so a value added on one side only fails the build
// (the earlier `schedulerSync` drift: the code emitted PENDING, the spec didn't list it). Domain enums from
// amplify_domain / amplify_common are checked through their constants and `is` tests.

import amplify_api.auth;
import amplify_common.types;
import amplify_domain.announcements;
import amplify_domain.campaign;
import amplify_domain.connection;
import amplify_domain.external_sharing;
import amplify_domain.sharing;

import ballerina/file;
import ballerina/io;
import ballerina/test;

# Every `.bal` source of the package (root and modules), tests excluded.
#
# + return - Concatenated source
function packageSource() returns string|error {
    string text = "";
    string[] dirs = ["."];
    foreach file:MetaData m in check file:readDir("modules") {
        if m.dir {
            dirs.push(m.absPath);
        }
    }
    foreach string dir in dirs {
        foreach file:MetaData m in check file:readDir(dir) {
            if !m.dir && m.absPath.endsWith(".bal") {
                text += check io:fileReadString(m.absPath) + "\n";
            }
        }
    }
    return text;
}

# Values of a singleton-union type defined in the package (`type Name "A"|"B"|other:Type;`), following
# references to other singleton unions of the package (`scheduler:UpsertResult`).
#
# + src - Package source
# + name - Type name
# + return - The string literals
function unionValues(string src, string name) returns string[]|error {
    int? at = src.indexOf("type " + name + " ");
    if at is () {
        return error("no type " + name + " in the package source");
    }
    int end = <int>src.indexOf(";", at);
    string body = src.substring(at + 5 + name.length(), end).trim();
    string[] values = [];
    foreach string part in re `\|`.split(body) {
        string p = part.trim();
        if p.startsWith("\"") {
            values.push(p.substring(1, p.length() - 1));
        } else {
            string ref = p.includes(":") ? p.substring(<int>p.indexOf(":") + 1) : p;
            values.push(...check unionValues(src, ref));
        }
    }
    return values;
}

# The `enum` of a schema property, following `$ref` and array `items`.
#
# + path - Schema name then property names (`items` steps into an array)
# + return - The enum values
function specEnum(string... path) returns string[]|error {
    map<json> all = check schemas();
    json node = all[path[0]];
    foreach string step in path.slice(1) {
        node = resolve(node, all);
        if step == "items" {
            node = check node.items;
        } else {
            map<json> props = check (check node.properties).ensureType();
            node = props[step];
        }
    }
    node = resolve(node, all);
    // OAS 3.0: a nullable field's `enum` must list `null` itself to allow it. `null` is not a value of the
    // Ballerina type, so it is left out of the comparison.
    json[] values = check (check node.'enum).cloneWithType();
    return from json v in values
        where v !is ()
        select v.toString();
}

function resolve(json node, map<json> all) returns json {
    if node is map<json> && node["$ref"] is string {
        string ref = <string>node["$ref"];
        return all[ref.substring(<int>ref.lastIndexOf("/") + 1)];
    }
    return node;
}

function assertSameSet(string[] spec, string[] code, string what) {
    test:assertEquals(spec.sort(), code.sort(), string `${what}: openapi enum vs code`);
}

@test:Config {groups: ["contract"]}
function testApiEnumsMatchTheirBallerinaTypes() returns error? {
    string src = check packageSource();
    [string[], string][] cases = [
        [["SettingList", "schedulerSync"], "SyncStatus"],
        [["SchedulerSync", "schedulerSync"], "SyncStatus"],
        [["SchedulerSync", "jobs", "items", "result"], "JobResult"],
        [["Leaderboard", "teamStatus"], "TeamStatus"],
        [["TeamPage", "teamStatus"], "TeamStatus"],
        [["TeamPage", "scope"], "TeamScope"],
        [["CampaignRegistration", "run"], "RunTrigger"],
        [["BreakerState"], "BreakerReport"],
        [["ReadyStatus", "breakers", "jobs"], "BreakerReport"]
    ];
    foreach [string[], string] [path, typeName] in cases {
        assertSameSet(check specEnum(...path), check unionValues(src, typeName), string:'join(".", ...path));
    }
}

@test:Config {groups: ["contract"]}
function testDomainEnumsMatchTheSpec() returns error? {
    [string[], string[]][] cases = [
        [["CampaignStatus"], [campaign:SCHEDULED, campaign:OPEN, campaign:CLOSED, campaign:ARCHIVED]],
        [["ConnectionStatus"], [connection:ACTIVE, connection:EXPIRING, connection:NEEDS_RECONNECT, connection:REMOVED,
            NOT_CONNECTED]],
        [["ShareKind"], [types:REPOST, types:REPOST_COMMENTARY, types:SHARE, types:SHARE_COMMENTARY]],
        [["PointAction"], [types:REPOST, types:REPOST_COMMENTARY, types:SHARE, types:SHARE_COMMENTARY, types:OWN_POST,
            types:OWN_POST_AMPLIFIED, types:REACTION, types:COMMENT, types:CHALLENGE_ENTRY, types:CHALLENGE_WINNER]],
        [["Share", "status"], [sharing:QUEUED, sharing:PUBLISHED, sharing:FAILED]],
        [["Share", "failureReason"], [types:NEEDS_RECONNECT, types:PROVIDER_REJECTED, types:RETRIES_EXHAUSTED]],
        [["ExternalShare", "status"], [external_sharing:PENDING, external_sharing:APPROVED, external_sharing:REJECTED,
            external_sharing:AMPLIFIED]],
        [["Announcement", "status"], [announcements:QUEUED, announcements:SENT, announcements:FAILED]],
        [["PoDashboard", "campaigns", "items", "announcement"], [announcements:QUEUED, announcements:SENT,
            announcements:FAILED]],
        [["LedgerEntry", "sourceType"], [types:ENGAGEMENT, types:EXTERNAL_SHARE, types:ADJUSTMENT, types:REVERSAL]],
        [["LedgerEntry", "status"], [types:HELD, types:PAID]],
        [["Me", "grants", "items"], [auth:EMPLOYEE, auth:CAN_CAMPAIGN, auth:CAN_DASHBOARD, auth:CAN_EXPORT,
            auth:CAN_REVIEW_SHARES, auth:CAN_POINT_RULES, auth:CAN_ADJUST_POINTS, auth:CAN_PO_DASHBOARD, auth:CAN_REPORTS,
            auth:CAN_ADMIN]]
    ];
    foreach [string[], string[]] [path, values] in cases {
        assertSameSet(check specEnum(...path), values, string:'join(".", ...path));
    }
    // The other direction for the domain types: every spec value is a member of the Ballerina type.
    foreach string v in check specEnum("CampaignStatus") {
        test:assertTrue(v is campaign:CampaignStatus, v);
    }
    foreach string v in check specEnum("PointAction") {
        test:assertTrue(v is types:PointAction, v);
    }
    foreach string v in check specEnum("ExternalShare", "status") {
        test:assertTrue(v is external_sharing:ExternalShareStatus, v);
    }
    foreach string v in check specEnum("LedgerEntry", "sourceType") {
        test:assertTrue(v is types:LedgerSourceType, v);
    }
}

// Upper-snake constants in constants.bal that are statuses or values, not problem codes.
final readonly & string[] NOT_PROBLEM_CODES = [NOT_CONNECTED];
// Auth constants that never reach a response (KEYS_UNAVAILABLE is answered as DEPENDENCY_UNAVAILABLE; RS256
// is the pinned algorithm).
final readonly & string[] AUTH_INTERNAL = [auth:KEYS_UNAVAILABLE, "RS256"];
// Domain codes the api renames before answering (problem.bal `apiCode`).
final readonly & string[] RENAMED = [types:ERR_CAMPAIGN_NOT_OPEN, types:ERR_CONNECTION_NEEDS_RECONNECT,
    types:ERR_SHARE_ALREADY_QUEUED, types:ERR_SHARE_ALREADY_PUBLISHED];

# Every domain code amplify_common defines (they pass through `failure()` unchanged unless renamed).
#
# + return - Codes
function domainCodes() returns string[] => [types:ERR_INVALID_EMPLOYEE_ID, types:ERR_INVALID_EMAIL,
    types:ERR_INVALID_MEMBER_URN, types:ERR_INVALID_POST_URN, types:ERR_INVALID_EVIDENCE_URL,
    types:ERR_EVIDENCE_URL_NOT_HTTPS, types:ERR_EVIDENCE_URL_TOO_LONG, types:ERR_EVIDENCE_URL_CREDENTIALS,
    types:ERR_EVIDENCE_URL_IP_HOST, types:ERR_INVALID_LEDGER_REFERENCE, types:ERR_INVALID_UUID,
    types:ERR_VERSION_CONFLICT, types:ERR_NOT_FOUND, types:ERR_CAMPAIGN_ALREADY_REGISTERED, types:ERR_NOT_WSO2_RESOURCE,
    types:ERR_INVALID_CAMPAIGN, types:ERR_INVALID_WINDOW, types:ERR_CAMPAIGN_ARCHIVED, types:ERR_POST_HAS_ACTIVITY,
    types:ERR_CAMPAIGN_NOT_OPEN,
    types:ERR_MISSING_SCOPE, types:ERR_MEMBER_ALREADY_LINKED, types:ERR_CONNECTION_REMOVED,
    types:ERR_CONNECTION_NEEDS_RECONNECT, types:ERR_SHARE_ALREADY_QUEUED, types:ERR_SHARE_ALREADY_PUBLISHED,
    types:ERR_SHARE_NOT_QUEUED, types:ERR_COMMENTARY_REQUIRED, types:ERR_COMMENTARY_NOT_ALLOWED,
    types:ERR_COMMENTARY_TOO_LONG, types:ERR_CERTIFICATION_REQUIRED, types:ERR_EVIDENCE_ALREADY_CLAIMED,
    types:ERR_NOT_PENDING, types:ERR_SELF_REVIEW, types:ERR_REASON_REQUIRED, types:ERR_NOT_APPROVED,
    types:ERR_ALREADY_AMPLIFIED, types:ERR_RULE_NOT_FOUND, types:ERR_RULE_VERSION_EXISTS, types:ERR_RULE_BACKDATED,
    types:ERR_INVALID_POINTS, types:ERR_TOP_UP_NOT_POSITIVE, types:ERR_ALREADY_REVERSED,
    types:ERR_CANNOT_REVERSE_REVERSAL, types:ERR_PAID_NOT_ALLOWED, types:ERR_ALREADY_ANNOUNCED,
    types:ERR_ANNOUNCEMENT_NOT_QUEUED, types:ERR_ANNOUNCEMENT_NOT_FAILED];

# `const string NAME = "VALUE";` values in a source file whose value is UPPER_SNAKE.
#
# + path - Source file
# + return - Values
function upperSnakeConstants(string path) returns string[]|error {
    string text = check io:fileReadString(path);
    string[] values = [];
    foreach string line in re `\n`.split(text) {
        string l = line.trim();
        if (l.startsWith("const string ") || l.startsWith("public const string ")) && l.includes("= \"") {
            string v = l.substring(<int>l.indexOf("= \"") + 3, <int>l.lastIndexOf("\""));
            if re `[A-Z][A-Z0-9_]+`.isFullMatch(v) {
                values.push(v);
            }
        }
    }
    return values;
}

@test:Config {groups: ["contract"]}
function testStableCodesMatchWhatTheCodeEmits() returns error? {
    string[] emitted = [];
    foreach string c in check upperSnakeConstants("constants.bal") {
        if NOT_PROBLEM_CODES.indexOf(c) is () {
            emitted.push(c);
        }
    }
    foreach string c in check upperSnakeConstants("modules/auth/token.bal") {
        if AUTH_INTERNAL.indexOf(c) is () {
            emitted.push(c);
        }
    }
    foreach string c in domainCodes() {
        if RENAMED.indexOf(c) is () && emitted.indexOf(c) is () {
            emitted.push(c);
        }
    }
    map<json> all = check schemas();
    map<json> code = check (check all["Problem"].properties.code).ensureType();
    string[] stable = check code["x-stable-codes"].cloneWithType();
    string[] missing = from string c in emitted where stable.indexOf(c) is () select c;
    string[] unknown = from string c in stable where emitted.indexOf(c) is () select c;
    test:assertEquals(missing, [], "codes the api can answer that openapi x-stable-codes doesn't list");
    test:assertEquals(unknown, [], "x-stable-codes nothing in the code emits");
    test:assertEquals(stable.length(), (from string c in stable group by c select c).length(), "no duplicates");
}
