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

import ballerina/test;

// A directory and a database in memory.
isolated class FakeLeaverPorts {
    *LeaverPorts;

    private final readonly & string[] directory;
    private final boolean directoryDown;
    private final readonly & string[] leavers;
    private final boolean leaversDown;
    private final int employees;
    private final readonly & string[] failErasing;
    private string[] erasedIds = [];
    private int candidateLimit = -1;

    isolated function init(string[] directory, string[] leavers, string[] failErasing = [],
            boolean directoryDown = false, boolean leaversDown = false, int employees = 1000) {
        self.employees = employees;
        self.directory = directory.cloneReadOnly();
        self.directoryDown = directoryDown;
        self.leavers = leavers.cloneReadOnly();
        self.leaversDown = leaversDown;
        self.failErasing = failErasing.cloneReadOnly();
    }

    public isolated function directoryEmails() returns string[]|error {
        if self.directoryDown {
            return error("connection refused");
        }
        return self.directory;
    }

    public isolated function candidates(string[] emails, int graceDays, int 'limit) returns string[]|error {
        lock {
            self.candidateLimit = 'limit;
        }
        if self.leaversDown {
            return error("db down");
        }
        string[] all = self.leavers;
        return all.length() > 'limit ? all.slice(0, 'limit) : all.clone();
    }

    public isolated function knownEmployees() returns int|error => self.employees;

    public isolated function erase(string employeeId) returns error? {
        if self.failErasing.indexOf(employeeId) !is () {
            return error("database said no");
        }
        lock {
            self.erasedIds.push(employeeId);
        }
    }

    isolated function erased() returns string[] {
        lock {
            return self.erasedIds.clone();
        }
    }

    isolated function askedFor() returns int {
        lock {
            return self.candidateLimit;
        }
    }
}

isolated function crowd(int n) returns string[] => from int i in 0 ..< n select string `person${i}@example.com`;

isolated function config(SweepMode mode, int graceDays = 30, int maxPerRun = 5, int maxPercent = 10) returns SweepConfig =>
    {mode, graceDays, minDirectorySize: 100, maxPerRun, maxPercent};

final SweepConfig & readonly ERASING = config(ERASE).cloneReadOnly();

@test:Config
function testSweepDoesNothingByDefault() {
    FakeLeaverPorts ports = new (crowd(500), ["gone-1"]);
    LeaverSweepReport report = sweepLeavers(ports, config(OFF));
    test:assertEquals(report.skipped, "off");
    test:assertEquals(ports.erased(), []);
}

@test:Config
function testDryRunNamesTheLeaversAndErasesNobody() {
    FakeLeaverPorts ports = new (crowd(500), ["gone-1", "gone-2"]);
    LeaverSweepReport report = sweepLeavers(ports, config(DRY_RUN));
    test:assertEquals(report.candidates, 2);
    test:assertEquals(report.sample, ["gone-1", "gone-2"]);
    test:assertEquals(report.erased, 0);
    test:assertEquals(ports.erased(), []);
}

@test:Config
function testEraseModeErasesEachLeaverOnce() {
    FakeLeaverPorts ports = new (crowd(500), ["gone-1", "gone-2", "gone-3"]);
    LeaverSweepReport report = sweepLeavers(ports, ERASING);
    test:assertEquals(report.erased, 3);
    test:assertEquals(report.failed, 0);
    test:assertEquals(ports.erased(), ["gone-1", "gone-2", "gone-3"]);
    test:assertEquals(report.skipped, ());
}

@test:Config
function testOneFailedEraseDoesNotStopTheRest() {
    FakeLeaverPorts ports = new (crowd(500), ["gone-1", "gone-2", "gone-3"], ["gone-2"]);
    LeaverSweepReport report = sweepLeavers(ports, ERASING);
    test:assertEquals(report.erased, 2);
    test:assertEquals(report.failed, 1);
    test:assertEquals(ports.erased(), ["gone-1", "gone-3"]);
}

@test:Config
function testADirectoryThatIsDownOrTooSmallErasesNobody() {
    FakeLeaverPorts down = new ([], ["gone-1"], directoryDown = true);
    test:assertEquals(sweepLeavers(down, ERASING).skipped, "directory unavailable");
    test:assertEquals(down.erased(), []);
    // A directory that suddenly lists 3 people would make everyone else a "leaver".
    FakeLeaverPorts tiny = new (crowd(3), ["gone-1", "gone-2"]);
    LeaverSweepReport report = sweepLeavers(tiny, ERASING);
    test:assertTrue((report.skipped ?: "").startsWith("directory listed 3"), report.skipped ?: "");
    test:assertEquals(tiny.erased(), []);
    test:assertEquals(tiny.askedFor(), -1, "the database is not even asked");
}

@test:Config
function testMoreLeaversThanTheCapErasesNobody() {
    FakeLeaverPorts ports = new (crowd(500), ["a", "b", "c", "d", "e", "f"]);
    LeaverSweepReport report = sweepLeavers(ports, ERASING);
    test:assertTrue((report.skipped ?: "").startsWith("more than 5 leavers"), report.skipped ?: "");
    test:assertEquals(report.erased, 0);
    test:assertEquals(ports.erased(), []);
    test:assertEquals(ports.askedFor(), 6, "asks for one more than the cap, to see that the cap was exceeded");
    // Exactly the cap is fine.
    FakeLeaverPorts exact = new (crowd(500), ["a", "b", "c", "d", "e"]);
    test:assertEquals(sweepLeavers(exact, ERASING).erased, 5);
}

@test:Config
function testLeaversThatAreTooLargeAShareOfAmplifyEraseNobody() {
    // Few people use Amplify during the pilot: 3 leavers of 20 employees is 15%, over the 10% cap, even though 3 is
    // far under the absolute cap of 5. A directory that is missing some of them looks exactly like this.
    FakeLeaverPorts ports = new (crowd(500), ["a", "b", "c"], employees = 20);
    LeaverSweepReport report = sweepLeavers(ports, ERASING);
    test:assertTrue((report.skipped ?: "").includes("over 10%"), report.skipped ?: "");
    test:assertEquals(ports.erased(), []);
    // The same three among 100 employees is 3%, fine; exactly at the cap is fine too.
    FakeLeaverPorts roomy = new (crowd(500), ["a", "b", "c"], employees = 100);
    test:assertEquals(sweepLeavers(roomy, ERASING).erased, 3);
    FakeLeaverPorts exact = new (crowd(500), ["a", "b"], employees = 20);
    test:assertEquals(sweepLeavers(exact, ERASING).erased, 2);
}

@test:Config
function testUnreadableCandidatesSkipTheSweep() {
    FakeLeaverPorts ports = new (crowd(500), [], leaversDown = true);
    test:assertEquals(sweepLeavers(ports, ERASING).skipped, "candidates unreadable");
    test:assertEquals(ports.erased(), []);
}

@test:Config
function testSweepSettingsAreCheckedAtStartUp() {
    test:assertTrue(validateSweepConfig(ERASING, false) is error, "erasing needs a directory");
    test:assertEquals(validateSweepConfig(config(OFF), false), (), "off needs nothing");
    test:assertEquals(validateSweepConfig(ERASING, true), ());
    test:assertTrue(validateSweepConfig(config(ERASE, graceDays = 0), true) is error);
    test:assertTrue(validateSweepConfig(config(ERASE, maxPerRun = 0), true) is error);
    test:assertTrue(validateSweepConfig(config(ERASE, maxPercent = 0), true) is error);
    test:assertTrue(validateSweepConfig(config(ERASE, maxPercent = 101), true) is error);
}
