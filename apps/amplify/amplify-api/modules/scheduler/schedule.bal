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

// Pure parts of the akornatskyy/scheduler client (ADR-026): schedule validation that mirrors the
// scheduler's own parser (robfig/cron `ParseStandard`, UTC), Go duration strings, and the job payload
// built within the scheduler's field limits so a bad value fails here, before any call.

# Shortest and longest schedule string the scheduler accepts.
const int SCHEDULE_MIN_LENGTH = 6;
const int SCHEDULE_MAX_LENGTH = 64;
# Scheduler field limits (`internal/shared/rule/validation.go`, v1.7.8).
const int ID_MIN = 3;
const int ID_MAX = 36;
const int NAME_MIN = 3;
const int NAME_MAX = 64;
const int URI_MIN = 8;
const int URI_MAX = 256;
const int BODY_MAX = 1024;
const int HEADER_NAME_MIN = 5;
const int HEADER_NAME_MAX = 32;
const int HEADER_VALUE_MAX = 256;
const int RETRY_COUNT_MAX = 10;
# The scheduler refuses request bodies over 4096 bytes on create and patch.
const int PAYLOAD_MAX = 4096;

final string:RegExp ID_PATTERN = re `^[A-Za-z0-9][A-Za-z0-9_-]*$`;

final readonly & string[] DESCRIPTORS = ["@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight",
    "@hourly"];

# One cron field: allowed range and names.
type CronField record {|
    # Field name for messages
    string label;
    # Smallest value
    int min;
    # Largest value
    int max;
    # Names allowed instead of numbers (months, weekdays)
    map<int> names = {};
|};

final readonly & CronField[] CRON_FIELDS = [
    {label: "minute", min: 0, max: 59},
    {label: "hour", min: 0, max: 23},
    {label: "day of month", min: 1, max: 31},
    {
        label: "month",
        min: 1,
        max: 12,
        names: {JAN: 1, FEB: 2, MAR: 3, APR: 4, MAY: 5, JUN: 6, JUL: 7, AUG: 8, SEP: 9, OCT: 10, NOV: 11, DEC: 12}
    },
    {label: "day of week", min: 0, max: 6, names: {SUN: 0, MON: 1, TUE: 2, WED: 3, THU: 4, FRI: 5, SAT: 6}}
];

# Checks a schedule string the way the scheduler will parse it: a 5-field cron (UTC), a descriptor such as
# `@daily`, or `@every <Go duration>`. Time-zone prefixes (`CRON_TZ=`, `TZ=`) are refused: schedules are UTC.
#
# + schedule - Schedule string
# + minEverySeconds - Smallest `@every` interval allowed
# + return - `()` when valid, else a message for the caller
public isolated function checkSchedule(string schedule, int minEverySeconds = 1) returns string? {
    string s = schedule.trim();
    if s != schedule || s.length() < SCHEDULE_MIN_LENGTH || s.length() > SCHEDULE_MAX_LENGTH {
        return string `must be ${SCHEDULE_MIN_LENGTH}-${SCHEDULE_MAX_LENGTH} characters with no surrounding spaces`;
    }
    if s.startsWith("CRON_TZ=") || s.startsWith("TZ=") {
        return "must not set a time zone (schedules run in UTC)";
    }
    if s.startsWith("@every ") {
        decimal|error seconds = parseGoDuration(s.substring(7).trim());
        if seconds is error {
            return "@every needs a duration such as 30s, 5m or 1h30m";
        }
        if seconds < <decimal>minEverySeconds {
            return string `@every must be at least ${minEverySeconds}s`;
        }
        return ();
    }
    if s.startsWith("@") {
        return DESCRIPTORS.indexOf(s) is () ? string `unknown descriptor; use one of ${string:'join(", ", ...DESCRIPTORS)} or @every` : ();
    }
    string[] fields = from string f in re ` +`.split(s) where f != "" select f;
    if fields.length() != 5 {
        return "must be 5 cron fields (minute hour day-of-month month day-of-week), a descriptor or @every";
    }
    foreach int i in 0 ..< 5 {
        string? problem = checkCronField(fields[i], CRON_FIELDS[i]);
        if problem is string {
            return problem;
        }
    }
    return ();
}

isolated function checkCronField(string cronField, CronField spec) returns string? {
    foreach string item in re `,`.split(cronField) {
        string expr = item;
        int? slash = item.indexOf("/");
        if slash is int {
            int|error step = int:fromString(item.substring(slash + 1));
            if step is error || step < 1 {
                return string `${spec.label}: step must be a positive number`;
            }
            expr = item.substring(0, slash);
        }
        if expr == "*" || expr == "?" {
            continue;
        }
        string[] bounds = re `-`.split(expr);
        if bounds.length() > 2 {
            return string `${spec.label}: '${item}' is not a value, range or step`;
        }
        int[] values = [];
        foreach string b in bounds {
            int? v = cronValue(b, spec);
            if v is () {
                return string `${spec.label}: '${b}' must be ${spec.min}-${spec.max}`;
            }
            values.push(v);
        }
        if values.length() == 2 && values[0] > values[1] {
            return string `${spec.label}: range '${expr}' runs backwards`;
        }
    }
    return ();
}

isolated function cronValue(string token, CronField spec) returns int? {
    int? named = spec.names[token.toUpperAscii()];
    if named is int {
        return named;
    }
    int|error v = int:fromString(token);
    return v is int && v >= spec.min && v <= spec.max ? v : ();
}

# Parses a Go duration (`300s`, `5m0s`, `1h30m`, `1.5h`, `250ms`) into seconds.
#
# + text - Duration text
# + return - Seconds, or an error when the text isn't a positive duration
public isolated function parseGoDuration(string text) returns decimal|error {
    if text == "" || text == "0" {
        return error("empty duration");
    }
    decimal total = 0;
    int i = 0;
    int n = text.length();
    while i < n {
        int begin = i;
        while i < n && (isDigit(text[i]) || text[i] == ".") {
            i += 1;
        }
        if begin == i {
            return error(string `bad duration: ${text}`);
        }
        decimal amount = check decimal:fromString(text.substring(begin, i));
        int unitStart = i;
        while i < n && !isDigit(text[i]) && text[i] != "." {
            i += 1;
        }
        decimal factor = check unitSeconds(text.substring(unitStart, i));
        total += amount * factor;
    }
    if total <= 0d {
        return error("duration must be positive");
    }
    return total;
}

isolated function isDigit(string c) returns boolean => c >= "0" && c <= "9";

isolated function unitSeconds(string unit) returns decimal|error {
    match unit {
        "h" => {
            return 3600;
        }
        "m" => {
            return 60;
        }
        "s" => {
            return 1;
        }
        "ms" => {
            return 0.001;
        }
        "us"|"µs"|"μs" => {
            return 0.000001;
        }
        "ns" => {
            return 0.000000001;
        }
    }
    return error(string `unknown duration unit '${unit}'`);
}

# Seconds as a Go duration string the scheduler parses (`300s`).
#
# + seconds - Whole seconds
# + return - Duration text
public isolated function goDuration(int seconds) returns string => seconds.toString() + "s";

# One request header the scheduler sends.
public type Header record {|
    # Header name (5-32 characters)
    string name;
    # Header value (up to 256 characters)
    string value;
|};

# The job the scheduler should hold: what to call, when, and how hard to retry.
public type JobSpec record {|
    # Stable job id, for example `amplify-run` (3-36 URL-safe characters)
    string id;
    # Display name in the scheduler UI (3-64 characters)
    string name;
    # Cron, descriptor or `@every`
    string schedule;
    # `false` keeps the job but stops it firing
    boolean enabled = true;
    # HTTP verb
    "GET"|"POST"|"PUT"|"PATCH"|"DELETE"|"HEAD" method = "POST";
    # Absolute http(s) URI (8-256 characters)
    string uri;
    # Request body (up to 1024 characters)
    string body = "";
    # Request headers
    Header[] headers = [];
    # Retries after a failure (0-10). The scheduler doesn't retry 400/401/403/404/422.
    int retryCount = 0;
    # Wait between retries, seconds
    int retryIntervalSeconds = 30;
    # Overall deadline for the call and its retries, seconds. Also how long the scheduler's job lock is held,
    # so it must be longer than the slowest successful call (amplify-jobs `runMaxSeconds`).
    int deadlineSeconds = 60;
|};

# Builds the scheduler's job JSON, checking every field against the scheduler's limits first.
#
# + collectionId - Collection the job belongs to
# + spec - Desired job
# + return - Payload for `POST /jobs` and `PATCH /jobs/{id}`, or an error naming the field
public isolated function jobPayload(string collectionId, JobSpec spec) returns map<json>|error {
    check checkId("id", spec.id);
    check checkId("collectionId", collectionId);
    check checkLength("name", spec.name.trim(), NAME_MIN, NAME_MAX);
    string? scheduleProblem = checkSchedule(spec.schedule);
    if scheduleProblem is string {
        return error(string `schedule ${scheduleProblem}`);
    }
    check checkLength("uri", spec.uri, URI_MIN, URI_MAX);
    if !spec.uri.startsWith("http://") && !spec.uri.startsWith("https://") {
        return error("uri must begin with http:// or https://");
    }
    check checkLength("body", spec.body, 0, BODY_MAX);
    foreach Header h in spec.headers {
        check checkLength("header name", h.name, HEADER_NAME_MIN, HEADER_NAME_MAX);
        check checkLength("header value", h.value, 1, HEADER_VALUE_MAX);
    }
    if spec.retryCount < 0 || spec.retryCount > RETRY_COUNT_MAX {
        return error(string `retryCount must be 0-${RETRY_COUNT_MAX}`);
    }
    if spec.retryIntervalSeconds < 1 || spec.deadlineSeconds < 1 {
        return error("retryIntervalSeconds and deadlineSeconds must be positive");
    }
    map<json> payload = {
        id: spec.id,
        name: spec.name,
        collectionId,
        state: spec.enabled ? "enabled" : "disabled",
        schedule: spec.schedule,
        action: {
            'type: "HTTP",
            request: {
                method: spec.method,
                uri: spec.uri,
                // Sent even when empty: PATCH merges into the stored job, so an omitted field would keep its old value.
                headers: from Header h in spec.headers select {name: h.name, value: h.value},
                body: spec.body
            },
            retryPolicy: {
                retryCount: spec.retryCount,
                retryInterval: goDuration(spec.retryIntervalSeconds),
                deadline: goDuration(spec.deadlineSeconds)
            }
        }
    };
    if payload.toJsonString().toBytes().length() > PAYLOAD_MAX {
        return error(string `job payload is over ${PAYLOAD_MAX} bytes`);
    }
    return payload;
}

isolated function checkId(string label, string id) returns error? {
    check checkLength(label, id, ID_MIN, ID_MAX);
    if !ID_PATTERN.isFullMatch(id) {
        return error(string `${label} must be URL-safe characters only`);
    }
}

isolated function checkLength(string label, string value, int min, int max) returns error? {
    if value.length() < min || value.length() > max {
        return error(string `${label} must be ${min}-${max} characters`);
    }
}

# Whether the job the scheduler holds already matches the payload, so an unchanged job isn't rewritten.
#
# + existing - `GET /jobs/{id}` body
# + desired - `jobPayload` result
# + return - True when nothing would change
public isolated function sameJob(json existing, map<json> desired) returns boolean {
    if existing !is map<json> {
        return false;
    }
    foreach string key in ["name", "collectionId", "state", "schedule"] {
        if existing[key] != desired[key] {
            return false;
        }
    }
    json|error action = existing.action;
    json|error want = desired.action;
    if action !is map<json> || want !is map<json> {
        return false;
    }
    json|error request = action.request;
    json|error wantRequest = want.request;
    if request !is map<json> || wantRequest !is map<json> {
        return false;
    }
    if request["method"] != wantRequest["method"] || request["uri"] != wantRequest["uri"]
            || (request["body"] ?: "") != wantRequest["body"]
            || (request["headers"] ?: <json[]>[]) != wantRequest["headers"] {
        return false;
    }
    json|error policy = action.retryPolicy;
    json|error wantPolicy = want.retryPolicy;
    if policy !is map<json> || wantPolicy !is map<json> {
        return false;
    }
    return policy["retryCount"] == wantPolicy["retryCount"]
        && sameDuration(policy["retryInterval"], wantPolicy["retryInterval"])
        && sameDuration(policy["deadline"], wantPolicy["deadline"]);
}

isolated function sameDuration(json a, json b) returns boolean {
    if a !is string || b !is string {
        return false;
    }
    decimal|error x = parseGoDuration(a);
    decimal|error y = parseGoDuration(b);
    return x is decimal && y is decimal && x == y;
}
