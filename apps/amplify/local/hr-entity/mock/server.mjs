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

// Local HR Entity mock: the `employees(filter, limit, offset)` GraphQL query Amplify reads (amplify-api
// outbound.bal `employeesQuery`), served from Postgres. Same behaviour as local/people-stub's /graphql route:
// filters on `employeeStatus`, pages with limit / offset, answers only the fields the query names.
// Also GET /employees/basic-info (people-app's shape) for a local One WSO2's photos and names.
// No auth: local use only.
import http from "node:http";
import pg from "pg";

const PORT = Number(process.env.PORT ?? 9096);
const ORIGINS = (process.env.ALLOW_ORIGINS ?? "http://localhost:3000").split(",");
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });

// GraphQL field -> column
const FIELDS = {
  employeeId: "employee_id", workEmail: "work_email", firstName: "first_name", lastName: "last_name",
  businessUnit: "business_unit", department: "department", subTeam: "sub_team", houseId: "house_id", house: "house",
  designation: "designation", managerEmail: "manager_email", company: "company", workLocation: "work_location",
  startDate: "start_date", employeeStatus: "employee_status",
};

const send = (res, code, body, origin) => {
  const h = { "Content-Type": "application/json" };
  if (origin && ORIGINS.includes(origin)) {
    Object.assign(h, { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Credentials": "true", Vary: "Origin" });
  }
  res.writeHead(code, h).end(JSON.stringify(body));
};

async function employees(statuses, limit, offset, fields) {
  const cols = fields.map((f) => `${FIELDS[f]} AS "${f}"`).join(", ");
  const { rows } = await pool.query(
    `SELECT ${cols} FROM employee WHERE ($1::text[] IS NULL OR employee_status = ANY($1)) ORDER BY employee_id LIMIT $2 OFFSET $3`,
    [statuses, limit, offset]);
  return rows.map((r) => ({ ...r, ...(r.startDate instanceof Date ? { startDate: r.startDate.toISOString().slice(0, 10) } : {}) }));
}

http.createServer(async (req, res) => {
  const origin = req.headers.origin;
  const path = new URL(req.url, "http://x").pathname;
  try {
    if (req.method === "OPTIONS") {
      return res.writeHead(204, {
        "Access-Control-Allow-Origin": ORIGINS.includes(origin) ? origin : "", "Access-Control-Allow-Credentials": "true",
        "Access-Control-Allow-Headers": "Authorization, Content-Type", "Access-Control-Max-Age": "600",
      }).end();
    }
    if (req.method === "GET" && path === "/health") return send(res, 200, { status: "UP" });
    if (req.method === "GET" && path === "/employees/basic-info") {
      const rows = await employees(null, 100000, 0, ["employeeId", "firstName", "lastName", "workEmail", "designation",
        "businessUnit", "department", "subTeam", "house", "employeeStatus"]);
      return send(res, 200, rows.map((r) => ({ ...r, employeeThumbnail: "" })), origin);
    }
    if (req.method === "POST" && (path === "/graphql" || path === "/")) {
      let raw = ""; for await (const c of req) raw += c;
      const body = JSON.parse(raw || "{}");
      const v = body.variables ?? {};
      // Fields named inside `employees(...) { ... }`; no selection set = a 400, as a real GraphQL server answers.
      const sel = /employees\s*\([^)]*\)\s*\{([^}]*)\}/.exec(body.query ?? "")?.[1]?.trim().split(/\s+/).filter(Boolean) ?? [];
      const unknown = sel.filter((f) => !(f in FIELDS));
      if (sel.length === 0 || unknown.length) {
        return send(res, 400, { errors: [{ message: `Cannot query field(s) ${unknown.join(", ") || "(none)"} on type Employee` }] }, origin);
      }
      const st = Array.isArray(v.filter?.employeeStatus) ? v.filter.employeeStatus : null;
      const data = await employees(st, Number.isInteger(v.limit) ? v.limit : 1000, Number.isInteger(v.offset) ? v.offset : 0, sel);
      return send(res, 200, { data: { employees: data } }, origin);
    }
    send(res, 404, { message: "not found" });
  } catch (e) {
    console.error("hr-entity mock error:", e.message);
    send(res, 500, { message: "mock error" });
  }
}).listen(PORT, () => console.log(`hr-entity mock on :${PORT}`));
