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
import ballerinax/postgresql;

@test:Config
function testListMigrationsKeepsOnlyVersionedScriptsInOrder() returns error? {
    string[] scripts = check listMigrations("tests/resources/migrations");
    test:assertEquals(scripts, ["V001__first.sql", "V002__second.sql"]);
}

@test:Config
function testMisnamedSqlScriptStopsTheRun() {
    string[]|error scripts = listMigrations("tests/resources/misnamed");
    test:assertTrue(scripts is error, "a .sql file that isn't V###__name.sql must not be skipped silently");
    if scripts is error {
        test:assertTrue(scripts.message().includes("V12__no_padding.sql"));
    }
}

@test:Config
function testDuplicateVersionStopsTheRun() {
    string[]|error scripts = listMigrations("tests/resources/duplicate");
    test:assertTrue(scripts is error, "two V001 scripts must stop the run");
    if scripts is error {
        test:assertTrue(scripts.message().includes("share the version V001"));
    }
}

@test:Config
function testShippedScriptsAreWellFormed() returns error? {
    string[] migrations = check listMigrations("migrations");
    // What this slice ships (V001-V007); later slices add more, so this is a floor, not the full count.
    test:assertTrue(migrations.length() >= 7);
    test:assertEquals(migrations[0], "V001__schemas_roles.sql");
    string[] seeds = check listScripts("seed", SEED_FILE);
    test:assertTrue(seeds.length() >= 4);
    test:assertEquals(versionOf("V012__x.sql"), "V012__x");
}


@test:Config
function testRunnerVerifiesTheServerByDefault() {
    // The declared default, not `dbSslMode`: a shell that exports BAL_CONFIG_VAR_DBSSLMODE=DISABLE for the IT
    // recipe would otherwise fail this test for a reason unrelated to the runner.
    test:assertEquals(DEFAULT_SSL_MODE, postgresql:VERIFY_FULL, "the runner defaults to VERIFY_FULL, like api and jobs");
    test:assertEquals(secureSocketOf(postgresql:VERIFY_FULL, " /mnt/db-ca/ca.pem "),
        {mode: postgresql:VERIFY_FULL, rootcert: "/mnt/db-ca/ca.pem"});
    test:assertEquals(secureSocketOf(postgresql:VERIFY_FULL, ""), {mode: postgresql:VERIFY_FULL});
    test:assertEquals(secureSocketOf(postgresql:REQUIRE, "/mnt/db-ca/ca.pem"), {mode: postgresql:REQUIRE},
        "a root certificate means nothing unless the mode verifies the server");
    test:assertEquals(secureSocketOf(postgresql:DISABLE, ""), {mode: postgresql:DISABLE});
}

@test:Config
function testTlsWarningOnlyForUnverifiedRemoteHosts() {
    test:assertTrue(tlsWarning("pg-amplify.aivencloud.com", postgresql:REQUIRE) is string);
    test:assertTrue(tlsWarning("pg-amplify.aivencloud.com", postgresql:DISABLE) is string);
    test:assertEquals(tlsWarning("pg-amplify.aivencloud.com", postgresql:VERIFY_FULL), ());
    test:assertEquals(tlsWarning("pg-amplify.aivencloud.com", postgresql:VERIFY_CA), ());
    test:assertEquals(tlsWarning("postgres", postgresql:DISABLE), (), "Compose service name is local");
    test:assertEquals(tlsWarning("localhost", postgresql:DISABLE), ());
    test:assertEquals(tlsWarning("127.0.0.1", postgresql:DISABLE), ());
    test:assertEquals(tlsWarning(" ", postgresql:DISABLE), ());
}

@test:Config
function testClassifyScriptPendingAppliedChanged() {
    map<string> recorded = {"V001__first": "aaa", "V002__second": "bbb"};
    test:assertEquals(classifyScript("V001__first", "aaa", recorded), "APPLIED");
    test:assertEquals(classifyScript("V002__second", "xxx", recorded), "CHANGED");
    test:assertEquals(classifyScript("V003__third", "ccc", recorded), "PENDING");
    test:assertEquals(classifyScript("V001__first", "aaa", {}), "PENDING", "no schema_version means all pending");
}

@test:Config
function testChecksumOfMatchesSha256() {
    test:assertEquals(checksumOf("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

@test:Config
function testPendingBelowAppliedIsOutOfOrder() {
    map<string> recorded = {"V013__a": "1", "V015__y": "2", "S004__s": "3"};
    string[] found = findOutOfOrder(["V013__a.sql", "V014__x.sql", "V015__y.sql", "V016__z.sql"], recorded);
    test:assertEquals(found, ["V014__x is pending but V015__y is already applied; renumber it"]);
}

@test:Config
function testOutOfOrderIsPerKind() {
    map<string> recorded = {"V020__a": "1", "S004__s": "3"};
    test:assertEquals(findOutOfOrder(["S005__new.sql"], recorded), [], "a seed is not judged by migrations");
    test:assertEquals(findOutOfOrder(["S003__old.sql"], recorded),
        ["S003__old is pending but S004__s is already applied; renumber it"]);
    test:assertEquals(findOutOfOrder(["V001__a.sql"], {}), [], "nothing applied, nothing out of order");
}
