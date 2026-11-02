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

// Unit tests for the infrastructure helpers (no database): TLS options, paging, audit entries, array
// literals, error mapping and time binding.

import amplify_common.types;

import ballerina/sql;
import ballerina/test;
import ballerinax/postgresql;

final DbConfig & readonly BASE = {host: "db", database: "amplify", user: "amplify_api", password: "x"};

function cfg(postgresql:SSLMode sslMode = postgresql:VERIFY_FULL, string? sslRootCert = ()) returns DbConfig =>
    {host: "db", database: "amplify", user: "amplify_api", password: "x", sslMode, sslRootCert};

@test:Config {}
function tlsVerifiesTheServerByDefault() {
    test:assertEquals(BASE.sslMode, postgresql:VERIFY_FULL, "R-04: default verifies the server");
    test:assertTrue(verifiesServer(BASE));
    test:assertEquals(secureSocketOf(BASE), {mode: postgresql:VERIFY_FULL});
    DbConfig withCa = cfg(sslRootCert = "/etc/amplify/db-ca.pem");
    test:assertEquals(secureSocketOf(withCa), {mode: postgresql:VERIFY_FULL, rootcert: "/etc/amplify/db-ca.pem"});
    DbConfig verifyCa = cfg(postgresql:VERIFY_CA, " /ca.pem ");
    test:assertEquals(secureSocketOf(verifyCa), {mode: postgresql:VERIFY_CA, rootcert: "/ca.pem"});
}

@test:Config {}
function nonVerifyingModesIgnoreTheCaAndSayNo() {
    DbConfig require = cfg(postgresql:REQUIRE, "/ca.pem");
    test:assertFalse(verifiesServer(require));
    test:assertEquals(secureSocketOf(require), {mode: postgresql:REQUIRE});
    DbConfig local = cfg(postgresql:DISABLE);
    test:assertFalse(verifiesServer(local));
    test:assertEquals(secureSocketOf(local), {mode: postgresql:DISABLE}, "local Docker keeps working");
    DbConfig blankCa = cfg(sslRootCert = "  ");
    test:assertEquals(secureSocketOf(blankCa), {mode: postgresql:VERIFY_FULL}, "blank CA = driver default");
}

@test:Config {}
function pageWindowNormalizesBadInput() {
    test:assertEquals(pageWindow(0, 20), [20, 0]);
    test:assertEquals(pageWindow(3, 20), [20, 60]);
    test:assertEquals(pageWindow(-2, 20), [20, 0], "negative page is page 0");
    test:assertEquals(pageWindow(1, 0), [1, 1], "size < 1 is 1");
    test:assertEquals(pageWindow(1, -5), [1, 1]);
    test:assertEquals(pageWindow(1, 500, 50), [50, 50], "upper bound when given");
    test:assertEquals(pageWindow(int:MAX_VALUE, 10), [10, int:MAX_VALUE], "no overflow panic");
}

@test:Config {}
function auditOfCarriesBeforeAndAfter() {
    Actor actor = {actorId: "po-1", roles: ["amplify_po"], correlationId: "c-1"};
    AuditEntry e = auditOf(actor, "ExternalShareApproved", "external_sharing.external_share", "id-1",
            {status: "APPROVED"}, "why", {status: "PENDING"});
    test:assertEquals(e.before, {status: "PENDING"});
    test:assertEquals(e.after, {status: "APPROVED"});
    test:assertEquals(e.reason, "why");
    test:assertEquals(e.correlationId, "c-1");
    test:assertEquals(e.actorRoles, ["amplify_po"]);
    test:assertEquals(e.outcome, "SUCCESS");
    AuditEntry insert = auditOf(SYSTEM, "CampaignRegistered", "campaign.campaign", "id-2", {title: "t"});
    test:assertEquals(insert.before, (), "an insert has no before");
    test:assertEquals(insert.actorId, "system");
}

@test:Config {}
function arrayLiteralQuotesAndEscapes() {
    test:assertEquals(arrayLiteral([]), "{}");
    test:assertEquals(arrayLiteral(["a", "b c"]), "{\"a\",\"b c\"}");
    test:assertEquals(arrayLiteral(["x\"y"]), "{\"x\\\"y\"}", "double quotes escaped");
    test:assertEquals(arrayLiteral(["a\\b"]), "{\"a\\\\b\"}", "backslashes escaped");
    test:assertEquals(arrayLiteral(["},{"]), "{\"},{\"}", "braces and commas stay inside the quotes");
}

@test:Config {}
function errorMappingHelpers() {
    test:assertFalse(isUniqueViolation(error("plain")), "not a database error");
    sql:NoRowsError noRows = error sql:NoRowsError("none");
    test:assertTrue(isNoRows(noRows));
    test:assertFalse(isNoRows(error("other")));
    test:assertFalse(isUniqueViolation(noRows));
    types:DomainError stale = versionConflict("campaign");
    test:assertEquals(stale.detail().code, types:ERR_VERSION_CONFLICT);
    test:assertTrue(stale.message().includes("campaign"));
    sql:DatabaseError unique = error sql:DatabaseError("duplicate key value violates unique constraint \"x_uk\"",
        errorCode = 0, sqlState = UNIQUE_VIOLATION);
    test:assertTrue(isUniqueViolation(unique));
    test:assertTrue(isUniqueViolation(unique, "x_uk"));
    test:assertFalse(isUniqueViolation(unique, "y_uk"));
    sql:DatabaseError checkFailed = error sql:DatabaseError("check", errorCode = 0, sqlState = CHECK_VIOLATION);
    test:assertFalse(isUniqueViolation(checkFailed));
}

@test:Config {}
function timesBindAsRfc3339AndTextIsTruncated() {
    test:assertEquals(ts(()), ());
    test:assertEquals(ts([0, 0]), "1970-01-01T00:00:00Z");
    test:assertEquals(truncate(()), ());
    test:assertEquals(truncate("short"), "short");
    string long = "";
    foreach int i in 0 ..< 1100 {
        long += "x";
    }
    test:assertEquals((truncate(long) ?: "").length(), 1000, "last_error CHECK is 1000");
}

// Domain review H-1: the start-up warning fires only for a remote host that isn't verified.
@test:Config
function tlsWarningOnlyForUnverifiedRemoteHosts() {
    DbConfig cfg = {host: "pg-amplify.a.aivencloud.com", database: "amplify", user: "amplify_api", password: "x"};
    test:assertEquals(tlsWarning(cfg), (), "VERIFY_FULL by default");
    cfg.sslMode = postgresql:REQUIRE;
    test:assertTrue(tlsWarning(cfg) is string, "REQUIRE encrypts but accepts any server");
    cfg.sslMode = postgresql:DISABLE;
    test:assertTrue(tlsWarning(cfg) is string);
    foreach string host in ["localhost", "127.0.0.1", "::1", "postgres"] {
        test:assertEquals(tlsWarning({host, database: "amplify", user: "u", password: "x",
            sslMode: postgresql:DISABLE}), (), host + " is local");
    }
    test:assertEquals(tlsWarning({host: "", database: "amplify", user: "u", password: "x",
        sslMode: postgresql:DISABLE}), (), "not configured");
}
