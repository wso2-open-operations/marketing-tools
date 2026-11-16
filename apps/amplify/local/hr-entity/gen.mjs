#!/usr/bin/env node
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

// Generates the fake cast for the local HR Entity stack from one source of truth, so the HR database and
// ThunderID always list the same people:
//   people.csv                  the 200 employees (5 named special users + 195 random names, all @example.com)
//   seed.sql                    loads people.csv's rows into the mock HR Entity's Postgres
//   thunder/10-amplify.yaml     ThunderID bootstrap: the users (minus the built-in admin), the amplify_* groups,
//                               the One WSO2 sign-in client and the CORS allowlist
// Deterministic (fixed seed): re-running gives byte-identical files. Run `node gen.mjs` after editing it.
// Fake people only. Nobody here is real.

import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const TOTAL = 200;
const PASSWORD = "Password2026!"; // shared default; ThunderID hashes it at bootstrap
const BUILTIN_ADMIN_ID = "01900000-0000-7000-8000-000000000030"; // ThunderID's default admin user (see README)

// mulberry32: tiny seeded PRNG so the cast never changes between runs
let seed = 20261111;
const rand = () => {
  seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const pick = (a) => a[Math.floor(rand() * a.length)];

const FIRST = ["Avery", "Devon", "Emery", "Logan", "Morgan", "Hayden", "Nico", "Riley", "Quinn", "Jordan", "Taylor",
  "Casey", "Skyler", "Rowan", "Sasha", "Reese", "Parker", "Finley", "Harper", "Kai", "Lane", "Marlow", "Noel",
  "Oakley", "Peyton", "Remy", "Sage", "Tatum", "Wren", "Zion", "Ari", "Blair", "Cameron", "Dakota", "Ellis",
  "Frankie", "Gray", "Harley", "Indigo", "Jules", "Kendall", "Lennon", "Micah", "Nova", "Onyx", "Phoenix",
  "Robin", "Shiloh", "Toby", "Val"];
const LAST = ["Abbott", "Barlow", "Calloway", "Dalton", "Ellison", "Fairbanks", "Garrison", "Hollis", "Ingram",
  "Jarvis", "Kensington", "Lockhart", "Mercer", "Northcott", "Ormond", "Pemberton", "Quill", "Redfern",
  "Sinclair", "Thornton", "Underhill", "Vance", "Whitlock", "Yardley", "Ashford", "Bellamy", "Carver", "Drummond",
  "Everett", "Fenwick", "Gallagher", "Hartley", "Irving", "Kendrick", "Langley", "Marsden", "Nash", "Osborne",
  "Prescott", "Rowley", "Stanton", "Tennant", "Upton", "Verity", "Winslow", "Yates", "Zeller", "Alden",
  "Brandt", "Crane"];

// business unit -> department (the team Amplify ranks) -> sub-teams
// Some departments sit under several BUs, one with a different spelling, as in the real directory: that is what
// makes the Team Leaderboard list a department more than once unless Amplify rolls it up by name.
const ORG = {
  PO: { PO: ["PO"], "Business Operations": ["Planning"] },
  SLT: { SLT: ["CEO", "Office"], "BUSINESS OPERATIONS": ["Office of the CEO"] },
  MKT: { Marketing: ["Content", "Events", "Growth"], "Business Operations": ["Programs"] },
  CS: { Support: ["FDE", "Success"], "Customer Success": ["Onboarding", "Renewals"] },
  ENG: { Platform: ["Core", "Infra"], Integration: ["Connectors", "Runtime"], Apps: ["Web", "Mobile"], "Customer Success": ["Solutions"] },
  PPL: { People: ["Recruiting", "Ops"], "Business Operations": ["Ops"] },
};
const HOUSES = [[1, "Orion"], [2, "Phoenix"], [3, "Draco"], [4, "Lyra"]];
const LOCATIONS = [["WSO2 - US", "US"], ["WSO2 - LK", "Sri Lanka"], ["WSO2 - UK", "UK"]];
const DESIGNATIONS = ["Engineer", "Senior Engineer", "Lead", "Manager", "Analyst", "Specialist"];

// [email, first, last, BU, department, subTeam, group]
const SPECIAL = [
  ["admin@example.com", "Admin", "User", "ENG", "Platform", "Core", "amplify_admin"],
  ["po@example.com", "Pat", "Owner", "PO", "PO", "PO", "amplify_po"],
  ["marketing@example.com", "Mel", "Marketer", "MKT", "Marketing", "Content", "amplify_marketing"],
  ["slt@example.com", "Sam", "Leader", "SLT", "SLT", "CEO", "amplify_slt"],
  ["user@example.com", "Una", "Employee", "ENG", "Apps", "Web", null],
];

const people = [];
const used = new Set();
let n = 0;
const add = (email, first, last, bu, dept, sub, group) => {
  n += 1;
  const house = rand() < 0.85 ? pick(HOUSES) : null; // ~15% have no house, like the real directory
  const [company, location] = pick(LOCATIONS);
  const ymd = `${2018 + Math.floor(rand() * 8)}-${String(1 + Math.floor(rand() * 12)).padStart(2, "0")}-${String(1 + Math.floor(rand() * 28)).padStart(2, "0")}`;
  people.push({
    id: n, uuid: `01900000-0000-7000-8001-${String(n).padStart(12, "0")}`, email, first, last, bu, dept, sub, group,
    houseId: house ? house[0] : null, house: house ? house[1] : null, company, location,
    designation: pick(DESIGNATIONS), startDate: ymd, status: "Active",
  });
  used.add(email);
};
for (const s of SPECIAL) add(...s);
// The random cast: spread over every BU / department / sub-team, never on a special address.
const slots = Object.entries(ORG).flatMap(([bu, depts]) =>
  Object.entries(depts).flatMap(([dept, subs]) => subs.map((sub) => [bu, dept, sub])));
while (people.length < TOTAL) {
  const first = pick(FIRST), last = pick(LAST);
  const email = `${first}.${last}@example.com`.toLowerCase();
  if (used.has(email)) continue;
  const [bu, dept, sub] = pick(slots);
  add(email, first, last, bu, dept, sub, null);
}
// Same department -> same manager (its first member), like a real org chart.
const managerOf = {};
for (const p of people) managerOf[p.dept] ??= p.email;

const csvCell = (v) => (v === null ? "" : /[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
const COLS = ["employeeId", "workEmail", "firstName", "lastName", "businessUnit", "department", "subTeam", "houseId",
  "house", "designation", "managerEmail", "company", "workLocation", "startDate", "employeeStatus", "amplifyGroup"];
const row = (p) => [p.id, p.email, p.first, p.last, p.bu, p.dept, p.sub, p.houseId, p.house, p.designation,
  managerOf[p.dept], p.company, p.location, p.startDate, p.status, p.group];
writeFileSync(join(HERE, "people.csv"), [COLS, ...people.map(row)].map((r) => r.map(csvCell).join(",")).join("\n") + "\n");

const HEADER_SQL = `-- Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
--
-- WSO2 LLC. licenses this file to you under the Apache License,
-- Version 2.0 (the "License"); you may not use this file except
-- in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.
`;
const q = (v) => (v === null ? "NULL" : `'${String(v).replace(/'/g, "''")}'`);
const sql = `${HEADER_SQL}-- GENERATED by local/hr-entity/gen.mjs from the same cast as people.csv and ThunderID. Do not edit by hand.
-- Local HR Entity mock only: ${TOTAL} fake employees on example.com addresses.

CREATE TABLE IF NOT EXISTS employee (
  employee_id     integer PRIMARY KEY,
  work_email      text NOT NULL UNIQUE,
  first_name      text NOT NULL,
  last_name       text NOT NULL,
  business_unit   text,
  department      text,
  sub_team        text,
  house_id        integer,
  house           text,
  designation     text,
  manager_email   text,
  company         text,
  work_location   text,
  start_date      date,
  employee_status text NOT NULL,
  amplify_group   text
);

INSERT INTO employee (employee_id, work_email, first_name, last_name, business_unit, department, sub_team, house_id, house,
  designation, manager_email, company, work_location, start_date, employee_status, amplify_group) VALUES
${people.map((p) => "  (" + row(p).map((v, i) => (i === 0 || i === 7 ? (v ?? "NULL") : q(v))).join(", ") + ")").join(",\n")}
ON CONFLICT (employee_id) DO NOTHING;
`;
writeFileSync(join(HERE, "seed.sql"), sql);

// ---- ThunderID bootstrap (read by setup.sh from /opt/thunderid/bootstrap, after the built-in 01 and 02 files) ----
const GROUPS = {
  amplify_admin: "Amplify admin", amplify_po: "Amplify product owner",
  amplify_marketing: "Amplify marketing", amplify_slt: "Amplify senior leadership",
};
const gid = (i) => `01900000-0000-7000-8002-${String(i).padStart(12, "0")}`;
const yq = (s) => JSON.stringify(s);
const docs = [];
docs.push(`# GENERATED by local/hr-entity/gen.mjs. Do not edit by hand. Mounted into ThunderID's /opt/thunderid/bootstrap.
# admin@example.com is ThunderID's built-in admin user (set ADMIN_USERNAME / ADMIN_PASSWORD in the compose file), so it
# is not created here; it is only added to the amplify_admin group below.
resource_type: server_config
name: cors
value:
  allowedOrigins:
    - "http://localhost:3000"`);
docs.push(`resource_type: application
id: 01900000-0000-7000-8003-000000000001
name: Amplify Local
description: Sign-in client for a local One WSO2 (Amplify)
type: browser
ouId: 01900000-0000-7000-8000-000000000001
url: "http://localhost:3000"
logoUrl: "avatar:shape=rounded,variant=anonymous_entity,content=cube,colors=0"
authFlowId: 01900000-0000-7000-8000-000000000068
registrationFlowId: 01900000-0000-7000-8000-000000000069
isRegistrationFlowEnabled: false
signOutFlowId: 01900000-0000-7000-8000-00000000006a
recoveryFlowId: 01900000-0000-7000-8000-000000000070
isRecoveryFlowEnabled: false
allowedUserTypes:
  - Person
inboundAuthConfig:
  - type: oauth2
    config:
      clientId: AMPLIFY_LOCAL
      redirectUris:
        - "http://localhost:3000"
      postLogoutRedirectUris:
        - "http://localhost:3000"
      grantTypes:
        - authorization_code
        - refresh_token
      responseTypes:
        - code
      pkceRequired: true
      tokenEndpointAuthMethod: none
      publicClient: true
      token:
        accessToken:
          userConfig:
            validityPeriod: 3600
            attributes:
              - given_name
              - family_name
              - email
              - groups
              - name
              - ouId
        idToken:
          validityPeriod: 3600
          userAttributes:
            - given_name
            - family_name
            - email
            - groups
            - name
            - ouId
      scopeClaims:
        profile:
          - name
          - given_name
          - family_name
          - picture
        email:
          - email
          - email_verified
        groups:
          - groups
        ou:
          - ouId`);
for (const p of people) {
  if (p.email === "admin@example.com") continue; // the built-in admin
  docs.push(`resource_type: user
id: ${p.uuid}
type: Person
ouHandle: default
attributes:
  username: ${yq(p.email)}
  sub: ${yq(p.email)}
  email: ${yq(p.email)}
  name: ${yq(`${p.first} ${p.last}`)}
  given_name: ${yq(p.first)}
  family_name: ${yq(p.last)}
credentials:
  password: ${yq(PASSWORD)}`);
}
Object.entries(GROUPS).forEach(([name, description], i) => {
  const members = people.filter((p) => p.group === name).map((p) => (p.email === "admin@example.com" ? BUILTIN_ADMIN_ID : p.uuid));
  docs.push(`resource_type: group
id: ${gid(i + 1)}
name: ${name}
description: ${yq(description)}
ouHandle: default
members:
${members.map((m) => `  - id: ${m}\n    type: user`).join("\n")}`);
});
writeFileSync(join(HERE, "thunder", "10-amplify.yaml"), docs.join("\n---\n") + "\n");
console.log(`wrote ${people.length} people: people.csv, seed.sql, thunder/10-amplify.yaml`);
