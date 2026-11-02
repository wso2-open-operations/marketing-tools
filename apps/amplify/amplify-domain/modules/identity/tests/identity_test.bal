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

import amplify_common.types;

import ballerina/test;
import ballerina/time;

final time:Utc T0 = [1790000000, 0];

@test:Config
function firstSeenStaysLastSeenMoves() returns error? {
    Employee first = check recordSeen((), {sub: "emp-1", email: "Avery.Mock@WSO2.com"}, T0);
    test:assertEquals(first.email, "avery.mock@wso2.com");
    test:assertEquals(first.displayName, "avery.mock", "falls back to the email local part");
    Employee later = check recordSeen(first, {sub: "emp-1", email: "avery.mock@wso2.com", name: "Avery Mock"},
            types:addDays(T0, 1));
    test:assertEquals(later.firstSeenAt, T0);
    test:assertEquals(later.lastSeenAt, types:addDays(T0, 1));
    test:assertEquals(later.displayName, "Avery Mock");
}

@test:Config
function badClaimsAreRejected() {
    Employee|types:DomainError noSub = recordSeen((), {sub: " ", email: "a@wso2.com"}, T0);
    test:assertTrue(noSub is types:DomainError);
    Employee|types:DomainError badEmail = recordSeen((), {sub: "e", email: "nope"}, T0);
    test:assertTrue(badEmail is types:DomainError);
}


isolated class InMemoryEmployees {
    *EmployeeRepository;
    private map<Employee> rows = {};
    private map<string> aliases = {};
    private int aliasWrites = 0;

    isolated function seed(string id, string email) {
        lock {
            self.rows[id] = {employeeId: id, email: email, displayName: id, firstSeenAt: T0, lastSeenAt: T0};
        }
    }

    isolated function writes() returns int {
        lock {
            return self.aliasWrites;
        }
    }

    public isolated function findById(types:EmployeeId employeeId) returns Employee|error? {
        lock {
            return self.rows[employeeId].clone();
        }
    }

    public isolated function upsert(Employee employee) returns error? {
        lock {
            self.rows[employee.employeeId] = employee.clone();
        }
    }

    public isolated function findByEmail(string email) returns Employee|error? {
        lock {
            foreach Employee e in self.rows {
                if e.email == email.toLowerAscii() {
                    return e.clone();
                }
            }
            return ();
        }
    }

    public isolated function findAlias(string sub) returns types:EmployeeId|error? {
        lock {
            return self.aliases[sub];
        }
    }

    public isolated function addAlias(string sub, types:EmployeeId employeeId) returns types:EmployeeId|error {
        lock {
            if !self.aliases.hasKey(sub) {
                self.aliasWrites += 1;
                self.aliases[sub] = employeeId;
            }
            return self.aliases.get(sub);
        }
    }
}

function conflictCode(ResolvedEmployee|types:DomainError|error r) returns string =>
    r is types:DomainError ? r.detail().code : r is error ? "ERROR" : "OK";

@test:Config
function newPersonResolvesToTheirOwnSub() returns error? {
    InMemoryEmployees repo = new;
    ResolvedEmployee r = check resolveEmployee(repo, "sub-new", "New.Person@wso2.com");
    test:assertEquals(r, {employeeId: "sub-new", aliased: false});
    test:assertEquals(repo.writes(), 0);
}

@test:Config
function recreatedAccountKeepsTheFirstEmployeeId() returns error? {
    InMemoryEmployees repo = new;
    repo.seed("sub-old", "re.person@wso2.com");
    ResolvedEmployee r = check resolveEmployee(repo, "sub-new", "Re.Person@WSO2.com");
    test:assertEquals(r, {employeeId: "sub-old", aliased: true}, "email is matched ignoring case");
    // Idempotent: the second sign-in reads the alias, writes nothing, answers the same.
    ResolvedEmployee again = check resolveEmployee(repo, "sub-new", "re.person@wso2.com");
    test:assertEquals(again, r);
    test:assertEquals(repo.writes(), 1);
    // The old sub still resolves to itself.
    test:assertEquals(check resolveEmployee(repo, "sub-old", "re.person@wso2.com"), {employeeId: "sub-old", aliased: false});
}

@test:Config
function racingFirstRequestsAgreeOnTheAlias() returns error? {
    InMemoryEmployees repo = new;
    repo.seed("sub-old", "race@wso2.com");
    types:EmployeeId first = check repo.addAlias("sub-new", "sub-old");
    // A second writer arriving with a (stale) different target gets the mapping that won.
    types:EmployeeId second = check repo.addAlias("sub-new", "sub-other");
    test:assertEquals([first, second], ["sub-old", "sub-old"]);
}

@test:Config
function twoRecordsClaimingOneEmailIsATypedConflict() {
    InMemoryEmployees repo = new;
    repo.seed("sub-a", "a@wso2.com");
    repo.seed("sub-b", "b@wso2.com");
    // b's own row exists and the token now says a's email.
    test:assertEquals(conflictCode(resolveEmployee(repo, "sub-b", "a@wso2.com")), types:ERR_EMAIL_CONFLICT);
    // A new sub already mapped to a, now arriving with b's email.
    InMemoryEmployees other = new;
    other.seed("sub-a", "a@wso2.com");
    other.seed("sub-b", "b@wso2.com");
    test:assertEquals(conflictCode(resolveEmployee(other, "sub-x", "a@wso2.com")), "OK");
    test:assertEquals(conflictCode(resolveEmployee(other, "sub-x", "b@wso2.com")), types:ERR_EMAIL_CONFLICT,
            "an alias of a cannot take b's email");
    test:assertEquals(other.writes(), 1, "the conflicting call wrote nothing");
}

@test:Config
function conflictMessageNamesNoOneElse() {
    InMemoryEmployees repo = new;
    repo.seed("sub-a", "a@wso2.com");
    repo.seed("sub-b", "b@wso2.com");
    ResolvedEmployee|types:DomainError|error r = resolveEmployee(repo, "sub-b", "a@wso2.com");
    test:assertTrue(r is types:DomainError);
    if r is types:DomainError {
        test:assertFalse(r.message().includes("a@wso2.com") || r.message().includes("sub-a"));
    }
}
