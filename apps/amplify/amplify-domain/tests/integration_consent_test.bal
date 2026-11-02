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

// The Link Me consent record against PostgreSQL (`connection.linkedin_consent`). The one piece of logic is the CASE in
// `PgConsentRepository.save`: declining replaces the stored profile URL (with the new one, or with nothing), while
// consenting keeps an earlier URL. The in-memory tests only cover `isProfileUrl`, so this pins the SQL.

import amplify_domain.connection;

import ballerina/test;
import ballerina/time;
import ballerinax/postgresql;

type StoredConsent record {|
    string decision;
    string? profile_url;
    int version;
|};

function storedConsent(postgresql:Client db, string employeeId) returns StoredConsent|error {
    StoredConsent row = check db->queryRow(`
        SELECT decision, profile_url, version FROM connection.linkedin_consent WHERE employee_id = ${employeeId}`);
    return row;
}

@test:Config {groups: ["integration"], enable: itEnabled}
function testDecliningReplacesTheProfileUrlAndConsentingKeepsIt() returns error? {
    postgresql:Client db = check api();
    connection:PgConsentRepository repo = new (db);
    string emp = "consent-" + uniq();
    string first = "https://www.linkedin.com/in/first-profile";
    string second = "https://www.linkedin.com/in/second-profile";

    // Declined with a URL: stored as given.
    check repo.save(emp, connection:DECLINED, first, time:utcNow());
    StoredConsent a = check storedConsent(db, emp);
    test:assertEquals(a.decision, "DECLINED");
    test:assertEquals(a.profile_url, first);
    test:assertEquals(a.version, 1);

    // Then consented: the decision changes, the earlier URL stays.
    check repo.save(emp, connection:CONSENTED, (), time:utcNow());
    StoredConsent b = check storedConsent(db, emp);
    test:assertEquals(b.decision, "CONSENTED");
    test:assertEquals(b.profile_url, first, "consenting keeps the URL given earlier");
    test:assertEquals(b.version, 2);

    // Consenting again, even with a URL in hand, still does not overwrite it.
    check repo.save(emp, connection:CONSENTED, second, time:utcNow());
    StoredConsent c = check storedConsent(db, emp);
    test:assertEquals(c.profile_url, first, "only a decline replaces the URL");
    test:assertEquals(c.version, 3);

    // Declined with a new URL: replaced.
    check repo.save(emp, connection:DECLINED, second, time:utcNow());
    StoredConsent d = check storedConsent(db, emp);
    test:assertEquals(d.decision, "DECLINED");
    test:assertEquals(d.profile_url, second, "declining replaces the URL");
    test:assertEquals(d.version, 4);

    // Declined with no URL: the stored one is cleared, not kept.
    check repo.save(emp, connection:DECLINED, (), time:utcNow());
    StoredConsent e = check storedConsent(db, emp);
    test:assertEquals(e.decision, "DECLINED");
    test:assertEquals(e.profile_url, (), "declining without a URL clears it");
    test:assertEquals(e.version, 5);

    // A first-time consent has no URL to keep.
    string other = "consent-" + uniq();
    check repo.save(other, connection:CONSENTED, (), time:utcNow());
    StoredConsent f = check storedConsent(db, other);
    test:assertEquals(f.decision, "CONSENTED");
    test:assertEquals(f.profile_url, ());
    test:assertEquals(f.version, 1);
    check db.close();
}
