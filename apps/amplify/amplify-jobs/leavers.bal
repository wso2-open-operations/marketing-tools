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
// `identity.employee` and, in `ERASE` mode, erases anyone who is both gone from the directory and has not used Amplify
// for `leaverGraceDays` (`identity.erase_employee`, which audits the call and keeps the pseudonymous ledger).
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

# people-app's directory, the full `GET .../employees/basic-info` URL (the same one amplify-api reads).
configurable string peopleDirectoryUrl = "";
# Directory timeout, seconds.
configurable decimal peopleDirectoryTimeoutSeconds = 10;
# OAuth2 client credentials for the directory's API. Empty token URL = no auth header (local stubs only).
configurable string peopleDirectoryTokenUrl = "";
# Directory client id.
configurable string peopleDirectoryClientId = "";
# Directory client secret (Choreo secret).
configurable string peopleDirectoryClientSecret = "";

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

    isolated function init(postgresql:Client db, http:Client? directory) {
        self.db = db;
        self.directory = directory;
    }

    public isolated function directoryEmails() returns string[]|error {
        http:Client? c = self.directory;
        if c is () {
            return error("People directory is not configured");
        }
        http:Response res = check c->get("");
        if res.statusCode != 200 {
            return error(string `People directory answered ${res.statusCode}`);
        }
        // The body names people: a parse error's message can echo it, so it never reaches the log.
        json|error payload = res.getJsonPayload();
        if payload !is json[] {
            return error("People directory answered a malformed body");
        }
        string[] emails = [];
        foreach json row in payload {
            json|error email = row.workEmail;
            if email is string && email.trim().length() > 0 {
                emails.push(email.trim().toLowerAscii());
            }
        }
        return emails;
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

final http:Client? leaverDirectoryClient = check newDirectoryClient();

isolated function newDirectoryClient() returns http:Client?|error {
    if peopleDirectoryUrl.trim() == "" {
        return ();
    }
    http:ClientConfiguration config = {timeout: peopleDirectoryTimeoutSeconds};
    if peopleDirectoryTokenUrl.trim() != "" {
        config.auth = {tokenUrl: peopleDirectoryTokenUrl, clientId: peopleDirectoryClientId,
            clientSecret: peopleDirectoryClientSecret};
    }
    return check new (peopleDirectoryUrl, config);
}

# Checks the sweep settings at start-up: a mode that erases needs a directory, and the limits must make sense.
#
# + cfg - Settings
# + directoryConfigured - Whether `peopleDirectoryUrl` is set
# + return - An error naming the problem, or `()`
isolated function validateSweepConfig(SweepConfig cfg, boolean directoryConfigured) returns error? {
    if cfg.mode != OFF && !directoryConfigured {
        return error("leaverSweepMode is not OFF but peopleDirectoryUrl is empty: there is no directory to compare with");
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
# + return - What it did
isolated function runConfiguredSweep(postgresql:Client pg) returns LeaverSweepReport =>
    sweepLeavers(new ProductionLeaverPorts(pg, leaverDirectoryClient), sweepConfig());
