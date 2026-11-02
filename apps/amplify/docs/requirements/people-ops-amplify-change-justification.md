# people-app changes for Amplify: justification

Branch: `feat/people-app-service-client-directory` in `projects/people-ops-suite` (fork `BechtelCanDoIt/people-ops-suite`), 3 commits on top of upstream `main`, 9 files. Merged into the fork's `main` by fork PR #4 (`0dfbc2a3`); the workspace pins that commit. Nothing is proposed to upstream `wso2-open-operations/people-ops-suite` yet. The diffs below are `main..HEAD` of that branch and are unchanged by the Amplify window work.

## Routes reviewed

Every people-app route was read on `main` (`apps/people-app/backend/service.bal`). Amplify needs: one employee ("me"), the employee's team, the employee's BU, all BUs, all employees, and the employee count.

| Need | Existing route | Usable by Amplify's backend? |
|---|---|---|
| Me | `GET /user-info`, `GET /employees/{id}` (self, admin or lead) | Not by a service: the interceptor rejects application tokens. No team or BU on `/user-info`. |
| My team, my BU | No member-list route. Ids come from `/employees/{id}`, names from `basic-info` | Same. |
| All BUs | `GET /business-units` (with `activeEmployeeCount`), `GET /teams`, `GET /organization-structure` | Same. |
| All employees | `GET /employees/basic-info` (one call, everyone) | Same, until the service-client change below. |
| Employee count | No count route: length of `basic-info` | Same. |
| House of every employee | None. `/employees/{id}` and `/employees/search` are restricted, `/houses` has no members | No: needs the `house` field below. |

Two changes are needed and nothing else: let a service client read the one directory route (section 2 to 5), and add `house` to that route (section 1). No existing route avoids either.

## `GET /employees/basic-info`: add `house` to each row

**Summary.** Amplify needs a House leaderboard (house is a required board). A house is a company-wide grouping that cuts across BUs and teams, and each employee has one (`employee.house_id`). The directory listing is the only people-app route that returns every employee in one call to a caller who is not an admin or lead, and it had no house. The other places that carry it do not work for Amplify: `GET /employees/{id}` answers only for the person themselves, admins and leads; `POST /employees/search` is admin or lead only; `GET /houses` lists house names but not who belongs to them.

The change adds one nullable `house` field to `EmployeeDirectoryInfo` and a `LEFT JOIN house` to the query. It is additive: existing consumers (One WSO2 Org Chart and Amplify's photo and name lookup) ignore fields they don't read, and the rows and access rules stay the same. Houses are not personal data beyond what the same row already shows (name, team, BU, manager).

**Commits.**
- `cac91e1d` feat(people-app): include the employee's house in the directory listing

**Code diff** (`main..HEAD`).

```diff
diff --git a/apps/people-app/backend/modules/database/db_queries.bal b/apps/people-app/backend/modules/database/db_queries.bal
index 9d5bcf49..62c78d07 100644
--- a/apps/people-app/backend/modules/database/db_queries.bal
+++ b/apps/people-app/backend/modules/database/db_queries.bal
@@ -70,6 +70,7 @@ isolated function getAllEmployeesBasicInfoQuery() returns sql:ParameterizedQuery
         t.name AS team,
         st.name AS subTeam,
         u.name AS unit,
+        h.name AS house,
         et.name AS employmentType,
         c.name AS company,
         e.work_location AS workLocation,
@@ -82,6 +83,7 @@ isolated function getAllEmployeesBasicInfoQuery() returns sql:ParameterizedQuery
         INNER JOIN company c ON c.id = e.company_id
         LEFT JOIN sub_team st ON e.sub_team_id = st.id
         LEFT JOIN unit u ON e.unit_id = u.id
+        LEFT JOIN house h ON e.house_id = h.id
     WHERE e.employee_status IN ('Active', 'Marked leaver');`;
 
 # Fetch employee ID by primary key ID.
diff --git a/apps/people-app/backend/modules/database/types.bal b/apps/people-app/backend/modules/database/types.bal
index 811ad694..6bbb88af 100644
--- a/apps/people-app/backend/modules/database/types.bal
+++ b/apps/people-app/backend/modules/database/types.bal
@@ -142,6 +142,8 @@ public type EmployeeDirectoryInfo record {|
     string? subTeam;
     # Unit
     string? unit;
+    # House
+    string? house;
     # Employment type
     string employmentType;
     # Company name
```

## Service-client access: `JwtInterceptor` and its config type

**Summary.** Amplify's backend (`amplify-api`) has to read the directory server to server, because ranking people against their own team, BU or house cannot be left to the browser (a browser could ask for anyone's points). It authenticates with OAuth2 client credentials, and that token belongs to an application, not a person.

`JwtInterceptor` sits in front of every route and converts the gateway JWT into `CustomJwtPayload`, which requires `email` and `groups`. An application token has neither, so the conversion fails and the caller gets 500 "Malformed Invoker info object!". This is true for **every** people-app route (`/user-info`, `/employees/{id}`, `/business-units`, `/teams`, `/organization-structure`, `/employees/basic-info`), so no existing route can serve a service. The change is needed whichever route Amplify reads.

What it adds, kept as small as possible:
- Off unless configured: `directoryClientIds` defaults to empty, so behaviour is unchanged until a client id is listed.
- Only application tokens qualify (`aut = APPLICATION`) and only when the token has no `email` and no `groups`, so a person signing in through a listed app never takes this path.
- The client id must be on the allow-list.
- The one route a service may reach is fixed in code: `GET employees/basic-info`, exactly two path segments. Any other route or method answers 403 and logs a warning.
- Same trust model as today: the interceptor already decodes `x-jwt-assertion` without verifying its signature and relies on the gateway.

**Commits.**
- `8d39e2df` feat(people-app): let listed service clients read the employee directory
- `81a2b73e` fix(people-app): only application tokens count as service clients; exact route match

**Code diff** (`main..HEAD`).

```diff
diff --git a/apps/people-app/backend/modules/authorization/authorization.bal b/apps/people-app/backend/modules/authorization/authorization.bal
index a2cacc89..75aa6598 100644
--- a/apps/people-app/backend/modules/authorization/authorization.bal
+++ b/apps/people-app/backend/modules/authorization/authorization.bal
@@ -18,6 +18,7 @@ import ballerina/jwt;
 import ballerina/log;
 
 public configurable AppRoles authorizedRoles = ?;
+public configurable ServiceClientConfig serviceClients = {};
 
 # To handle authorization for each resource function invocation.
 public isolated service class JwtInterceptor {
@@ -45,6 +46,21 @@ public isolated service class JwtInterceptor {
             return <http:InternalServerError>{body: {message: errorMsg}};
         }
 
+        // Service callers (an application token with no user email or groups) are decided before the user
+        // path below, which would otherwise reject the token as malformed.
+        if result[1]["email"] is () && result[1]["groups"] is () {
+            string? clientId = allowedServiceClient(result[1]);
+            if clientId is string {
+                if isServiceClientRoute(req.method, path) {
+                    ctx.set(HEADER_SERVICE_CLIENT, clientId);
+                    return ctx.next();
+                }
+                log:printWarn(string `Service client ${clientId} attempted to access a restricted resource: `
+                        + string `${req.method} ${path.toBalString()}`);
+                return <http:Forbidden>{body: {message: "Insufficient privileges!"}};
+            }
+        }
+
         CustomJwtPayload|error userInfo = result[1].cloneWithType(CustomJwtPayload);
         if userInfo is error {
             string errorMsg = "Malformed Invoker info object!";
@@ -93,3 +109,29 @@ public isolated service class JwtInterceptor {
         return <http:Forbidden>{body: {message: "Insufficient privileges!"}};
     }
 }
+
+# The calling application's client id when the token belongs to an allowed service client: issued to an
+# application (`applicationClaim` = `applicationValue`), and its client id is listed.
+#
+# + payload - Decoded gateway JWT payload
+# + return - Client id, or `()` when the token isn't an allowed service client
+isolated function allowedServiceClient(jwt:Payload payload) returns string? {
+    if payload[serviceClients.applicationClaim] != serviceClients.applicationValue {
+        return ();
+    }
+    anydata claim = payload[serviceClients.clientIdClaim];
+    if claim !is string || claim.trim() == "" {
+        return ();
+    }
+    return serviceClients.directoryClientIds.indexOf(claim) is () ? () : claim;
+}
+
+# Whether a request is the one a service client may make: `GET /employees/basic-info`.
+#
+# + method - HTTP method
+# + path - Path segments after the service base path
+# + return - True for the employee directory read
+isolated function isServiceClientRoute(string method, string[] path) returns boolean =>
+    // Two segments exactly: an encoded slash (`employees%2Fbasic-info`) arrives as one segment and is refused.
+    method == http:HTTP_GET && path.length() == 2 && string:'join("/", ...path) == SERVICE_CLIENT_PATH;
+
diff --git a/apps/people-app/backend/modules/authorization/constants.bal b/apps/people-app/backend/modules/authorization/constants.bal
index 9ba5f92b..6e8afa96 100644
--- a/apps/people-app/backend/modules/authorization/constants.bal
+++ b/apps/people-app/backend/modules/authorization/constants.bal
@@ -17,6 +17,12 @@
 # Authorization Constants.
 public const JWT_ASSERTION_HEADER = "x-jwt-assertion";
 public const HEADER_USER_INFO = "user-info";
+# Request-context key holding the client id of an allowed service caller (see `ServiceClientConfig`).
+public const HEADER_SERVICE_CLIENT = "service-client";
+
+# The one resource a service caller may reach: the employee directory (read-only, the same data every
+# authenticated employee can read).
+public const SERVICE_CLIENT_PATH = "employees/basic-info";
 
 # Privileges.
 public const ADMIN_PRIVILEGE = 999;
diff --git a/apps/people-app/backend/modules/authorization/types.bal b/apps/people-app/backend/modules/authorization/types.bal
index 81dbceef..1945e40b 100644
--- a/apps/people-app/backend/modules/authorization/types.bal
+++ b/apps/people-app/backend/modules/authorization/types.bal
@@ -22,6 +22,25 @@ public type CustomJwtPayload record {
     string[] groups;
 };
 
+# Service-to-service callers allowed to read the employee directory.
+#
+# A service calls through the gateway with OAuth2 client credentials, so its gateway JWT names the calling
+# application but carries no user `email` or `groups`. Such a token is admitted only when its client id is
+# listed here, and only for `GET /employees/basic-info`.
+public type ServiceClientConfig record {|
+    # JWT claim holding the calling application's client id. Check a real gateway token for the claim name
+    # before relying on the default.
+    string clientIdClaim = "azp";
+    # JWT claim that says who the token was issued to. A user signing in through a listed app also carries
+    # that app's id, so the id alone doesn't make a caller a service: this claim must equal
+    # `applicationValue` too. Check a real client-credentials gateway token before relying on the default.
+    string applicationClaim = "aut";
+    # Value of `applicationClaim` on a token issued to an application rather than a person.
+    string applicationValue = "APPLICATION";
+    # Client ids allowed to read the directory. Empty = no service callers (the behaviour before this change).
+    string[] directoryClientIds = [];
+|};
+
 # Application specific role mapping.
 public type AppRoles record {|
     # Role for the employee
```

## `GET /employees/basic-info`: accept a service client as the caller

**Summary.** The resource used to return 500 when no user was in the request context. It now accepts either a user or a service client that the interceptor admitted. The query, the rows and the fields returned do not change, so a service client sees exactly what any signed-in employee can already read from this endpoint. Personal info, search and single-employee records stay off limits to it.

**Commits.**
- `8d39e2df` feat(people-app): let listed service clients read the employee directory

**Code diff** (`main..HEAD`).

```diff
diff --git a/apps/people-app/backend/service.bal b/apps/people-app/backend/service.bal
index 3a174a51..c055cb0d 100644
--- a/apps/people-app/backend/service.bal
+++ b/apps/people-app/backend/service.bal
@@ -743,14 +743,16 @@ service http:InterceptableService / on new http:Listener(9090) {
     }
 
     # Fetch directory information for all currently employed staff (Active and Marked leaver).
-    # Available to every authenticated user.
+    # Available to every authenticated user, and to the service clients listed in
+    # `authorization.serviceClients.directoryClientIds` (see `authorization:ServiceClientConfig`).
     #
     # + return - Directory information for Active and Marked leaver employees
     resource function get employees/basic\-info(http:RequestContext ctx)
         returns database:EmployeeDirectoryInfo[]|http:InternalServerError {
 
         authorization:CustomJwtPayload|error userInfo = ctx.getWithType(authorization:HEADER_USER_INFO);
-        if userInfo is error {
+        string|error serviceClient = ctx.getWithType(authorization:HEADER_SERVICE_CLIENT);
+        if userInfo is error && serviceClient is error {
             return <http:InternalServerError>{
                 body: {
                     message: ERROR_USER_INFORMATION_HEADER_NOT_FOUND
```

## Configuration defaults (`Config.toml.local`)

**Summary.** Adds the `[people.authorization.serviceClients]` section with empty defaults, so the feature is documented and off. The claim names (`azp`, `aut`) must be confirmed against a real gateway token before a client id is listed.

**Commits.**
- `8d39e2df` feat(people-app): let listed service clients read the employee directory
- `81a2b73e` fix(people-app): only application tokens count as service clients; exact route match

**Code diff** (`main..HEAD`).

```diff
diff --git a/apps/people-app/backend/Config.toml.local b/apps/people-app/backend/Config.toml.local
index 689f9df8..af7e4790 100644
--- a/apps/people-app/backend/Config.toml.local
+++ b/apps/people-app/backend/Config.toml.local
@@ -9,6 +9,14 @@ RESIGNATION_ROLE = ""
 QR_EXPORT_ROLE = ""
 EXTERNAL_USER_ROLES = [];
 
+# Service-to-service readers of GET /employees/basic-info (gateway client-credentials tokens, no user).
+# Empty = none. Confirm the client-id claim name against a real gateway token.
+[people.authorization.serviceClients]
+clientIdClaim = "azp"
+applicationClaim = "aut"
+applicationValue = "APPLICATION"
+directoryClientIds = []
+
 [people.database.dbConfig]
 host = ""
 user = ""
```

## Tests for the service-client path

**Summary.** Run the real `JwtInterceptor` in front of a small test service. They cover: a listed application token reaches `basic-info`; the same client on any other route or method gets 403; an unlisted client falls through to the existing behaviour; a token with `email` or `groups` never takes the service path; a user token for a listed app still goes through the normal role checks; and an encoded slash in the path is refused.

**Commits.**
- `8d39e2df` feat(people-app): let listed service clients read the employee directory
- `81a2b73e` fix(people-app): only application tokens count as service clients; exact route match

**Code diff** (`main..HEAD`).

```diff
diff --git a/apps/people-app/backend/modules/authorization/tests/Config.toml b/apps/people-app/backend/modules/authorization/tests/Config.toml
new file mode 100644
index 00000000..e4a263e6
--- /dev/null
+++ b/apps/people-app/backend/modules/authorization/tests/Config.toml
@@ -0,0 +1,12 @@
+[people.authorization.authorizedRoles]
+EMPLOYEE_ROLE = "people-employee"
+ADMIN_ROLE = "people-admin"
+SERVICE_DESK_ROLE = "people-service-desk"
+EMPLOYEE_VIEW_ROLE = "people-employee-view"
+RESIGNATION_ROLE = "people-resignation"
+QR_EXPORT_ROLE = "people-qr-export"
+EXTERNAL_USER_ROLES = ["people-external"]
+
+[people.authorization.serviceClients]
+clientIdClaim = "azp"
+directoryClientIds = ["amplify-api-client"]
diff --git a/apps/people-app/backend/modules/authorization/tests/service_client_test.bal b/apps/people-app/backend/modules/authorization/tests/service_client_test.bal
new file mode 100644
index 00000000..9e6a336f
--- /dev/null
+++ b/apps/people-app/backend/modules/authorization/tests/service_client_test.bal
@@ -0,0 +1,133 @@
+// Copyright (c) 2025 WSO2 LLC. (https://www.wso2.com).
+//
+// WSO2 LLC. licenses this file to you under the Apache License,
+// Version 2.0 (the "License"); you may not use this file except
+// in compliance with the License.
+// You may obtain a copy of the License at
+//
+// http://www.apache.org/licenses/LICENSE-2.0
+//
+// Unless required by applicable law or agreed to in writing,
+// software distributed under the License is distributed on an
+// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
+// KIND, either express or implied.  See the License for the
+// specific language governing permissions and limitations
+// under the License. 
+
+// JwtInterceptor with service clients: an allowed client reads GET /employees/basic-info and nothing else;
+// unknown clients and user tokens behave exactly as before.
+
+import ballerina/http;
+import ballerina/test;
+
+const int TEST_PORT = 19190;
+
+service http:InterceptableService / on new http:Listener(TEST_PORT) {
+
+    public function createInterceptors() returns http:Interceptor[] => [new JwtInterceptor()];
+
+    resource function get employees/basic\-info(http:RequestContext ctx) returns json {
+        string|error serviceClient = ctx.getWithType(HEADER_SERVICE_CLIENT);
+        CustomJwtPayload|error userInfo = ctx.getWithType(HEADER_USER_INFO);
+        return {
+            serviceClient: serviceClient is string ? serviceClient : (),
+            user: userInfo is CustomJwtPayload ? userInfo.email : ()
+        };
+    }
+
+    resource function post employees/basic\-info() returns json => {wrote: true};
+
+    resource function get employees/[string employeeId]() returns json => {employeeId};
+
+    resource function get employees/[string employeeEmail]/vehicles() returns json => {employeeEmail};
+}
+
+final http:Client testClient = check new (string `http://localhost:${TEST_PORT}`);
+
+# An unsigned JWT: the interceptor only decodes (the gateway verifies), so the signature is never read.
+function token(map<json> claims) returns string {
+    string header = {alg: "RS256", typ: "JWT"}.toJsonString().toBytes().toBase64();
+    string payload = claims.toJsonString().toBytes().toBase64();
+    return string `${base64Url(header)}.${base64Url(payload)}.c2ln`;
+}
+
+function base64Url(string b64) returns string =>
+    re `=+$`.replace(re `/`.replaceAll(re `\+`.replaceAll(b64, "-"), "_"), "");
+
+function call(string method, string path, map<json> claims) returns http:Response|error {
+    map<string> headers = {[JWT_ASSERTION_HEADER]: token(claims)};
+    if method == "POST" {
+        return testClient->post(path, {}, headers);
+    }
+    return testClient->get(path, headers);
+}
+
+@test:Config
+function allowedServiceClientReadsTheDirectory() returns error? {
+    http:Response res = check call("GET", "/employees/basic-info", {azp: "amplify-api-client", aut: "APPLICATION", sub: "amplify"});
+    test:assertEquals(res.statusCode, 200);
+    json body = check res.getJsonPayload();
+    test:assertEquals(check body.serviceClient, "amplify-api-client");
+    test:assertEquals(check body.user, (), "a service caller is never treated as a user");
+}
+
+@test:Config
+function allowedServiceClientIsLimitedToTheDirectory() returns error? {
+    map<json> amplify = {azp: "amplify-api-client", aut: "APPLICATION"};
+    test:assertEquals((check call("GET", "/employees/E1", amplify)).statusCode, 403, "no single employee record");
+    test:assertEquals((check call("GET", "/employees/a@wso2.com/vehicles", amplify)).statusCode, 403);
+    test:assertEquals((check call("POST", "/employees/basic-info", amplify)).statusCode, 403, "read only");
+}
+
+@test:Config
+function unknownServiceClientIsRefusedAsBefore() returns error? {
+    // Not listed: falls through to the user path, which can't read a user from it (unchanged behaviour).
+    http:Response res = check call("GET", "/employees/basic-info", {azp: "someone-else", aut: "APPLICATION"});
+    test:assertEquals(res.statusCode, 500);
+    http:Response blank = check call("GET", "/employees/basic-info", {azp: "  ", aut: "APPLICATION"});
+    test:assertEquals(blank.statusCode, 500);
+}
+
+@test:Config
+function userTokensAreUnchanged() returns error? {
+    http:Response employee = check call("GET", "/employees/basic-info",
+            {email: "ada@wso2.com", groups: ["people-employee"]});
+    test:assertEquals(employee.statusCode, 200);
+    json body = check employee.getJsonPayload();
+    test:assertEquals(check body.user, "ada@wso2.com");
+    test:assertEquals(check body.serviceClient, ());
+
+    http:Response noGroup = check call("GET", "/employees/basic-info", {email: "ada@wso2.com", groups: []});
+    test:assertEquals(noGroup.statusCode, 403);
+}
+
+@test:Config
+function userTokenWithAListedClientIdStaysAUser() returns error? {
+    // A user signed in through an app whose id happens to be listed still goes through the role check.
+    http:Response res = check call("GET", "/employees/E1",
+            {email: "ada@wso2.com", groups: [], azp: "amplify-api-client"});
+    test:assertEquals(res.statusCode, 403);
+}
+
+@test:Config
+function emailLessUserThroughAListedAppIsNotAService() returns error? {
+    // A person (or a service account) with no email, signed in through the listed app, carries its azp but
+    // isn't an application token: it never reaches the directory as a service.
+    http:Response appUser = check call("GET", "/employees/basic-info",
+            {azp: "amplify-api-client", aut: "APPLICATION_USER", sub: "someone"});
+    test:assertEquals(appUser.statusCode, 500, "falls through to the user path, which can't read a user");
+    http:Response noMarker = check call("GET", "/employees/basic-info", {azp: "amplify-api-client"});
+    test:assertEquals(noMarker.statusCode, 500);
+    http:Response withGroups = check call("GET", "/employees/basic-info",
+            {azp: "amplify-api-client", aut: "APPLICATION", groups: []});
+    test:assertEquals(withGroups.statusCode, 500, "a token with groups is a user token, never a service");
+}
+
+@test:Config
+function serviceRouteMatchesSegmentsExactly() returns error? {
+    map<json> amplify = {azp: "amplify-api-client", aut: "APPLICATION"};
+    test:assertEquals((check call("GET", "/employees%2Fbasic-info", amplify)).statusCode, 403,
+            "an encoded slash is one segment, not the directory route");
+    test:assertEquals((check call("GET", "/employees/basic-info/extra", amplify)).statusCode, 403);
+}
+
```

## How Amplify uses these changes (the House board and person popup)

**Summary.** The window work after this document was first written added no people-app change. It consumes the two above. The Participation window's House leaderboard is built in `amplify-api` from the `house` field of `GET /employees/basic-info`, read with the service-client path, and the person popup needs no people-app data beyond the name, team, BU and photo the same listing already returns.

- **House board.** `amplify-api` (`outbound.bal`) reads `house` into `DirectoryRecord`, indexes `houseOf` and `houseMembers`, and counts members per house in the headcount snapshot. `groups.bal` serves `GET .../groups?by=HOUSE` the same way it serves TEAM and BU. One WSO2 renders it as the House table after Team, before Export.
- **Missing house.** An employee without a house (`house` is null or blank) is left out of the House board. No route fills that gap, so the people data must be right in the source.
- **Person popup.** Its Posts table comes from Amplify's own data (`closesAt` added to the person posts). The photo comes from `employeeThumbnail`, which `basic-info` already returned. No people-app change.
- **Until it is deployed.** The board shows "No houses to show" until the fork's people-app change is deployed and `directoryClientIds` holds the Amplify Backend connection's client id for that environment. The `azp` and `aut` claim names are defaults, not yet checked against a real gateway token.

**Commits.** None in people-ops-suite. The consuming code is in `marketing-tools` and `one-wso2` (workspace commit `4e74519`).
