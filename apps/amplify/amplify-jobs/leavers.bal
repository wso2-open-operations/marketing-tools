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

// Leaver sweep (security review). Employees who left stay in Amplify, with a LinkedIn token and a place on the
// leaderboard, until someone remembers. The daily maintenance run compares the people directory with
// `identity_employee` and, in `ERASE` mode, erases anyone who is both gone from the directory and has not used Amplify
// for `leaverGraceDays` (`identity_erase_employee`, which audits the call and keeps the pseudonymous ledger).
//
// It does nothing by default. Switch it on in stages: `DRY_RUN` reports who would be erased, `ERASE` erases. A directory
// that answers with too few people, or a sweep that finds more leavers than `leaverMaxPerRun`, erases nobody and says why:
// both look like a broken directory, not a company that lost people overnight.

import amplify_common.resilience;
import amplify_domain.identity;
import amplify_domain.store;

import ballerina/http;
import ballerina/log;
import ballerinax/postgresql;

# What the sweep does.
public enum SweepMode {
    # Nothing runs
    OFF,
    # Finds leavers and reports them; erases nobody
    DRY_RUN,
    # Erases the leavers it finds
    ERASE
}

# Sweep mode. Default `OFF`.
configurable SweepMode leaverSweepMode = OFF;
# Days a person must also have been away from Amplify, on top of missing from the directory, before they are erased.
configurable int leaverGraceDays = 30;
# Fewest people the directory must list for its answer to be trusted. An answer smaller than this skips the sweep.
configurable int leaverMinDirectorySize = 100;
# Most leavers one sweep will erase. More than this erases nobody: it points to a directory problem, not to leavers.
configurable int leaverMaxPerRun = 10;
# Most leavers one sweep will erase, as a percentage of the employees Amplify knows. The absolute cap alone lets a partial
# directory erase a handful of active people while Amplify is small; this one scales with the pilot.
configurable int leaverMaxPercent = 10;

# The HR Entity GraphQL service's URL (the same one amplify-api reads).
configurable string hrEntityBaseUrl = "";
# HR Entity timeout, seconds, per page.
configurable decimal hrEntityTimeoutSeconds = 10;
# OAuth2 client credentials for the HR Entity service. Empty token URL = no auth header (local stubs only).
configurable string hrEntityTokenUrl = "";
# HR Entity client id.
configurable string hrEntityClientId = "";
# HR Entity client secret (Choreo secret).
configurable string hrEntityClientSecret = "";
# Retries after a failed HR Entity call (connection error, or a 500, 502, 503 or 504 answer); the same settings and
# defaults as amplify-api and the other apps that read the HR Entity.
configurable int hrEntityRetryCount = 3;
# Seconds before the first retry.
configurable decimal hrEntityRetryInterval = 3.0;
# Each retry waits this many times longer than the one before.
configurable float hrEntityRetryBackOffFactor = 2.0;
# Longest wait between two retries, seconds.
configurable decimal hrEntityRetryMaxWaitInterval = 20.0;
# Rows asked for per page.
configurable int hrEntityPageSize = 1000;
# Employee statuses the directory lists. `Marked leaver` stays in until the person is `Left`.
configurable string[] hrEntityStatuses = ["Active", "Marked leaver"];

# What one sweep did. Ids are the pseudonymous `sub`, never emails.
public type LeaverSweepReport record {|
    # The mode it ran in
    string mode;
    # Why it did nothing, absent when it ran
    string skipped?;
    # People the directory listed
    int directorySize;
    # Leavers found (grace period applied)
    int candidates;
    # Leavers erased
    int erased;
    # Erases that failed (logged; the next sweep tries again)
    int failed;
    # The first few candidates, in `DRY_RUN` and `ERASE`, so an operator can check them
    string[] sample;
|};

# What the sweep needs from the outside, so it can be tested without a directory or a database.
public type LeaverPorts isolated object {
    # Lower-case work emails of everyone the directory lists.
    public isolated function directoryEmails() returns string[]|error;
    # Leavers among `emails`' complement, at most `limit` rows.
    public isolated function candidates(string[] emails, int graceDays, int 'limit) returns string[]|error;
    # Erases one employee.
    public isolated function erase(string employeeId) returns error?;
    # Employees Amplify holds data for (not yet erased), the base of the percentage cap.
    public isolated function knownEmployees() returns int|error;
};

# The sweep settings.
public type SweepConfig record {|
    # Mode
    SweepMode mode;
    # Grace days
    int graceDays;
    # Smallest trusted directory
    int minDirectorySize;
    # Most erased in one sweep
    int maxPerRun;
    # Most erased in one sweep, as a percentage of the employees Amplify knows
    int maxPercent;
|};

# Runs one sweep. Never fails: every problem becomes `skipped` or a count, and is logged.
#
# + ports - Directory and database
# + cfg - Settings
# + return - What it did
public isolated function sweepLeavers(LeaverPorts ports, SweepConfig cfg) returns LeaverSweepReport {
    LeaverSweepReport report = {mode: cfg.mode, directorySize: 0, candidates: 0, erased: 0, failed: 0, sample: []};
    if cfg.mode == OFF {
        report.skipped = "off";
        return report;
    }
    string[]|error emails = ports.directoryEmails();
    if emails is error {
        log:printWarn("Leaver sweep skipped: the people directory is unavailable", resilience:loggable(emails));
        report.skipped = "directory unavailable";
        return report;
    }
    report.directorySize = emails.length();
    if emails.length() < cfg.minDirectorySize {
        log:printError("Leaver sweep skipped: the directory listed too few people to trust",
                listed = emails.length(), minimum = cfg.minDirectorySize);
        report.skipped = string `directory listed ${emails.length()}, fewer than ${cfg.minDirectorySize}`;
        return report;
    }
    // One more than the cap, so "more than the cap" is visible without reading every leaver.
    string[]|error found = ports.candidates(emails, cfg.graceDays, cfg.maxPerRun + 1);
    if found is error {
        log:printWarn("Leaver sweep skipped: could not read the candidates", resilience:loggable(found));
        report.skipped = "candidates unreadable";
        return report;
    }
    report.candidates = found.length();
    report.sample = found.length() > 20 ? found.slice(0, 20) : found;
    if found.length() > cfg.maxPerRun {
        log:printError("Leaver sweep skipped: more leavers than one sweep may erase; check the directory",
                maximum = cfg.maxPerRun);
        report.skipped = string `more than ${cfg.maxPerRun} leavers; nobody erased, check the directory`;
        return report;
    }
    int|error known = ports.knownEmployees();
    if known is error {
        log:printWarn("Leaver sweep skipped: could not count the employees", resilience:loggable(known));
        report.skipped = "employee count unreadable";
        return report;
    }
    if found.length() * 100 > cfg.maxPercent * known {
        log:printError("Leaver sweep skipped: the leavers are too large a share of the employees; check the directory",
                leavers = found.length(), employees = known, maxPercent = cfg.maxPercent);
        report.skipped = string `${found.length()} leavers of ${known} employees is over ${cfg.maxPercent}%; nobody erased, check the directory`;
        return report;
    }
    if cfg.mode == DRY_RUN {
        log:printInfo("Leaver sweep (dry run)", candidates = found.length());
        return report;
    }
    foreach string employeeId in found {
        error? erased = ports.erase(employeeId);
        if erased is error {
            report.failed += 1;
            log:printError("Leaver erase failed", resilience:loggable(erased));
        } else {
            report.erased += 1;
        }
    }
    log:printInfo("Leaver sweep done", erased = report.erased, failed = report.failed, directory = report.directorySize);
    return report;
}

# The directory and the database behind `LeaverPorts`.
isolated class ProductionLeaverPorts {
    *LeaverPorts;

    private final postgresql:Client db;
    private final http:Client? directory;
    private final string? correlationId;

    isolated function init(postgresql:Client db, http:Client? directory, string? correlationId = ()) {
        self.db = db;
        self.directory = directory;
        self.correlationId = correlationId;
    }

    public isolated function directoryEmails() returns string[]|error {
        http:Client? c = self.directory;
        if c is () {
            return error("People directory is not configured");
        }
        int pageSize = hrEntityPageSize > 0 ? hrEntityPageSize : 1000;
        map<string> headers = resilience:correlationHeaders(self.correlationId);
        string[] emails = [];
        int offset = 0;
        foreach int _ in 0 ..< MAX_DIRECTORY_PAGES {
            DirectoryPage page = check directoryPage(c, headers, pageSize, offset);
            // The end is an empty page, not a short one: the service may cap `limit` below what was asked for.
            if page.rows == 0 {
                return emails;
            }
            emails.push(...page.emails);
            offset += page.rows;
        }
        return error(string `People directory did not end within ${MAX_DIRECTORY_PAGES} pages`);
    }

    public isolated function candidates(string[] emails, int graceDays, int 'limit) returns string[]|error =>
        identity:leaverCandidates(self.db, emails, graceDays, 'limit);

    public isolated function knownEmployees() returns int|error => identity:countEmployees(self.db);

    public isolated function erase(string employeeId) returns error? {
        json|error result = identity:eraseEmployee(self.db, employeeId, store:SYSTEM.actorId, "LEAVER_SWEEP");
        if result is error {
            return result;
        }
    }
}

# Reads the directory page by page until a short page. The end is decided by the ROW count of a page, not by
# how many rows had a work email: a full page with one email-less row must not look like the last page, or
# everyone on later pages would look like a leaver.
#
# + pageSize - Rows asked for per page
# + fetch - Reads one page (rows asked for, rows to skip): the emails found and the number of rows it held
# + return - All emails, or an error (also when the directory does not end within `MAX_DIRECTORY_PAGES`)
isolated function collectDirectoryEmails(int pageSize,
        isolated function (int, int) returns [string[], int]|error fetch) returns string[]|error {
    string[] emails = [];
    int offset = 0;
    foreach int _ in 0 ..< MAX_DIRECTORY_PAGES {
        [string[], int] [pageEmails, rows] = check fetch(pageSize, offset);
        emails.push(...pageEmails);
        if rows < pageSize {
            return emails;
        }
        offset += pageSize;
    }
    return error(string `People directory did not end within ${MAX_DIRECTORY_PAGES} pages`);
}

final http:Client? leaverDirectoryClient = check newDirectoryClient();

isolated function newDirectoryClient() returns http:Client?|error {
    if hrEntityBaseUrl.trim() == "" {
        return ();
    }
    http:ClientConfiguration config = {
        timeout: hrEntityTimeoutSeconds,
        retryConfig: {
            count: hrEntityRetryCount,
            interval: hrEntityRetryInterval,
            backOffFactor: hrEntityRetryBackOffFactor,
            maxWaitInterval: hrEntityRetryMaxWaitInterval,
            statusCodes: [500, 502, 503, 504]
        }
    };
    if hrEntityTokenUrl.trim() != "" {
        config.auth = {tokenUrl: hrEntityTokenUrl, clientId: hrEntityClientId, clientSecret: hrEntityClientSecret};
    }
    return check new (hrEntityBaseUrl, config);
}

# The query, one page of current employees. Only the work email is asked for: the sweep compares emails.
const string EMPLOYEES_QUERY = "query getEmployees($filter: EmployeeFilter!, $limit: Int, $offset: Int) { "
        + "employees(filter: $filter, limit: $limit, offset: $offset) { workEmail } }";

# Most pages one directory read will ask for.
const int MAX_DIRECTORY_PAGES = 100;

# One page of the HR Entity's employees.
type DirectoryPage record {|
    # Lower-case work emails (a row without one is skipped)
    string[] emails;
    # Rows the service returned, with or without an email: what the next offset moves by
    int rows;
|};

# One page of the HR Entity's employees, as lower-case work emails.
#
# + c - HR Entity client
# + headers - Request headers (the correlation id)
# + pageSize - Rows asked for
# + offset - Rows to skip
# + return - The page, or an error that never carries the response body (it names people)
isolated function directoryPage(http:Client c, map<string> headers, int pageSize, int offset)
        returns DirectoryPage|error {
    json body = {
        query: EMPLOYEES_QUERY,
        variables: {filter: {employeeStatus: hrEntityStatuses}, 'limit: pageSize, offset}
    };
    http:Response res = check c->post("", body, headers);
    if res.statusCode != 200 {
        return error(string `People directory answered ${res.statusCode}`);
    }
    json|error payload = res.getJsonPayload();
    if payload is error || payload !is map<json> {
        return error("People directory answered a malformed body");
    }
    json errors = payload["errors"];
    if errors is json[] && errors.length() > 0 {
        return error("People directory answered with GraphQL errors");
    }
    json data = payload["data"];
    json employees = data is map<json> ? data["employees"] : ();
    if employees !is json[] {
        return error("People directory answered a malformed body");
    }
    string[] emails = [];
    foreach json row in employees {
        json|error email = row.workEmail;
        if email is string && email.trim().length() > 0 {
            emails.push(email.trim().toLowerAscii());
        }
    }
    return {emails, rows: employees.length()};
}

# Checks the sweep settings at start-up: a mode that erases needs a directory, and the limits must make sense.
#
# + cfg - Settings
# + directoryConfigured - Whether `hrEntityBaseUrl` is set
# + return - An error naming the problem, or `()`
isolated function validateSweepConfig(SweepConfig cfg, boolean directoryConfigured) returns error? {
    if cfg.mode != OFF && !directoryConfigured {
        return error("leaverSweepMode is not OFF but hrEntityBaseUrl is empty: there is no directory to compare with");
    }
    if cfg.graceDays < 1 || cfg.minDirectorySize < 1 || cfg.maxPerRun < 1 {
        return error("leaverGraceDays, leaverMinDirectorySize and leaverMaxPerRun must be at least 1");
    }
    if cfg.maxPercent < 1 || cfg.maxPercent > 100 {
        return error("leaverMaxPercent must be between 1 and 100");
    }
}

# The configured sweep settings.
#
# + return - Settings
isolated function sweepConfig() returns SweepConfig => {
    mode: leaverSweepMode,
    graceDays: leaverGraceDays,
    minDirectorySize: leaverMinDirectorySize,
    maxPerRun: leaverMaxPerRun,
    maxPercent: leaverMaxPercent
};

# Runs the sweep against the real database and directory.
#
# + pg - Jobs database client
# + correlationId - Trigger correlation id, sent to the HR Entity so a failing sweep can be traced there
# + return - What it did
isolated function runConfiguredSweep(postgresql:Client pg, string? correlationId = ()) returns LeaverSweepReport =>
    sweepLeavers(new ProductionLeaverPorts(pg, leaverDirectoryClient, correlationId), sweepConfig());
