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

// Test gateway: RSA keypairs generated per run (openssl), a JWKS served from a test listener, a JWT
// minter, and in-memory fakes for the repository and audit seams.
import amplify_api.auth;
import amplify_common.types;
import amplify_domain.connection;
import amplify_domain.identity;
import amplify_domain.store;

import ballerina/crypto;
import ballerina/file;
import ballerina/http;
import ballerina/lang.array;
import ballerina/os;
import ballerina/test;
import ballerina/time;

const string TEST_ISSUER = "https://gateway.test/amplify";
const string TEST_AUDIENCE = "amplify-test-client";
const string TEST_KID = "test-key-1";

// The Asgardeo groups the tests sign into tokens. tests/Config.toml maps them to grants, as an
// environment's configuration would; the code itself names no group.
const string PO_GROUP = "amplify_po";
const string MARKETING_GROUP = "amplify_marketing";
const string SLT_GROUP = "amplify_slt";
const string ADMIN_GROUP = "amplify_admin";
# Only in `canCampaignGroups`: proves a second group can share a capability without any other grant.
const string CAMPAIGN_ONLY_GROUP = "amplify_campaign_extra";

# Gateway signing key (published in the test JWKS).
crypto:PrivateKey? gatewayKey = ();
# A second key, never published: signs the bad-signature tokens.
crypto:PrivateKey? rogueKey = ();
# Its public half as a JWK, for the dev-trust tests.
auth:Jwk? rogueJwk = ();

isolated json jwksBody = {keys: []};
isolated boolean jwksDown = false;
// Serve a 200 with no usable keys (parseJwks fails, the breaker stays closed): lets a test count fetches
// without the breaker short-circuiting them.
isolated boolean jwksEmptyBody = false;
isolated int jwksHits = 0;

listener http:Listener jwksListener = new (9591);

service /jwks on jwksListener {
    isolated resource function get .() returns json|http:ServiceUnavailable {
        lock {
            jwksHits += 1;
        }
        boolean down;
        lock {
            down = jwksDown;
        }
        boolean empty;
        lock {
            empty = jwksEmptyBody;
        }
        if down {
            return http:SERVICE_UNAVAILABLE;
        }
        if empty {
            return {keys: []};
        }
        lock {
            return jwksBody.clone();
        }
    }
}

@test:BeforeSuite
function generateKeys() returns error? {
    string dir = check file:createTempDir();
    [crypto:PrivateKey, auth:Jwk] gateway = check newKeyPair(dir, "gateway", TEST_KID);
    [crypto:PrivateKey, auth:Jwk] rogue = check newKeyPair(dir, "rogue", TEST_KID);
    gatewayKey = gateway[0];
    rogueKey = rogue[0];
    rogueJwk = rogue[1];
    json body = {keys: [{kty: "RSA", use: "sig", alg: "RS256", kid: TEST_KID, n: gateway[1].n, e: gateway[1].e}]};
    lock {
        jwksBody = body.clone();
    }
    check file:remove(dir, file:RECURSIVE);
}

function newKeyPair(string dir, string name, string kid) returns [crypto:PrivateKey, auth:Jwk]|error {
    string pem = check file:joinPath(dir, name + ".pem");
    _ = check run(["genrsa", "-out", pem, "2048"]);
    string modulus = check run(["rsa", "-in", pem, "-noout", "-modulus"]);
    int offset = (modulus.indexOf("=") ?: -1) + 1;
    string hex = re `\s`.replaceAll(modulus.substring(offset), "");
    crypto:PrivateKey key = check crypto:decodeRsaPrivateKeyFromKeyFile(pem);
    return [key, {kid, n: auth:toBase64Url(check array:fromBase16(hex)), e: "AQAB"}];
}

function run(string[] args) returns string|error {
    os:Process process = check os:exec({value: "openssl", arguments: args});
    int code = check process.waitForExit();
    byte[] out = check process.output();
    if code != 0 {
        return error(string `openssl ${args[0]} exited ${code}`);
    }
    return string:fromBytes(out);
}

function setJwksDown(boolean down) {
    lock {
        jwksDown = down;
    }
}

function setJwksEmptyBody(boolean empty) {
    lock {
        jwksEmptyBody = empty;
    }
}

function resetJwksHits() {
    lock {
        jwksHits = 0;
    }
}

function jwksHitCount() returns int {
    lock {
        return jwksHits;
    }
}

# Mints a compact RS256 JWS.
#
# + claims - Payload overrides; `()` values remove the default claim
# + key - Signing key (default: the gateway key)
# + header - Header overrides
# + return - The token
function mint(map<json> claims = {}, crypto:PrivateKey? key = (), map<json> header = {}) returns string|error {
    int now = time:utcNow()[0];
    map<json> payload = {
        iss: TEST_ISSUER,
        aud: TEST_AUDIENCE,
        sub: "emp-0001",
        email: "Ada.Lovelace@wso2.com",
        name: "Ada Lovelace",
        iat: now,
        exp: now + 300
    };
    foreach [string, json] [k, v] in claims.entries() {
        if v is () {
            _ = payload.removeIfHasKey(k);
        } else {
            payload[k] = v;
        }
    }
    map<json> head = {alg: "RS256", typ: "JWT", kid: TEST_KID};
    foreach [string, json] [k, v] in header.entries() {
        head[k] = v;
    }
    string input = auth:toBase64Url(head.toJsonString().toBytes()) + "."
        + auth:toBase64Url(payload.toJsonString().toBytes());
    crypto:PrivateKey signer = key ?: check gatewayKey.ensureType();
    byte[] signature = check crypto:signRsaSha256(input.toBytes(), signer);
    return input + "." + auth:toBase64Url(signature);
}

function groupsClaim(string... groups) returns map<json> => {groups: groups};

// ---- Fakes for the repository and audit seams ---------------------------------------------------

isolated store:AuditEntry[] denials = [];

function takeDenials() returns store:AuditEntry[] {
    lock {
        store:AuditEntry[] result = denials.clone();
        denials = [];
        return result.clone();
    }
}

@test:Mock {functionName: "recordDenial"}
isolated function mockRecordDenial(store:AuditEntry entry) returns error? {
    lock {
        denials.push(entry.clone());
    }
}

isolated class FakeEmployees {
    *identity:EmployeeRepository;
    private map<identity:Employee> rows = {};
    private map<string> aliases = {};

    public isolated function findById(types:EmployeeId employeeId) returns identity:Employee|error? {
        lock {
            return self.rows[employeeId].clone();
        }
    }

    public isolated function upsert(identity:Employee employee) returns error? {
        lock {
            self.rows[employee.employeeId] = employee.clone();
        }
    }

    public isolated function findByEmail(string email) returns identity:Employee|error? {
        lock {
            foreach identity:Employee e in self.rows {
                if e.email.toLowerAscii() == email.toLowerAscii() {
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
            string existing = self.aliases[sub] ?: employeeId;
            self.aliases[sub] = existing;
            return existing;
        }
    }

    # Test seam: how many aliases exist.
    isolated function aliasCount() returns int {
        lock {
            return self.aliases.length();
        }
    }
}

isolated class FakeConnections {
    *connection:ConnectionRepository;
    private map<connection:LinkedInConnection> rows = {};
    private int tokensInSave = 0;

    isolated function put(connection:LinkedInConnection c) {
        lock {
            self.rows[c.employeeId] = c.clone();
        }
    }

    public isolated function findByEmployee(types:EmployeeId employeeId, types:Provider provider)
            returns connection:LinkedInConnection|error? {
        lock {
            return self.rows[employeeId].clone();
        }
    }

    public isolated function findByMember(types:Provider provider, types:MemberUrn memberUrn)
            returns connection:LinkedInConnection|error? => ();

    public isolated function save(connection:ConnectionChange change, int? expectedVersion) returns error? {
        lock {
            if change.tokenToInsert !is () {
                self.tokensInSave += 1;
            }
        }
    }

    # Token rows handed to `save` (inserted in the connection's transaction, api H3).
    isolated function tokensSaved() returns int {
        lock {
            return self.tokensInSave;
        }
    }
}

final FakeEmployees fakeEmployees = new;
final FakeConnections fakeConnections = new;

@test:Mock {functionName: "employeeRepository"}
isolated function mockEmployeeRepository() returns identity:EmployeeRepository|error => fakeEmployees;

@test:Mock {functionName: "connectionRepository"}
isolated function mockConnectionRepository(store:Actor actor) returns connection:ConnectionRepository|error =>
    fakeConnections;
