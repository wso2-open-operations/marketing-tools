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

// LOCAL ONLY: stands in for the Choreo API proxy so a local One WSO2 can call the Compose amplify-api.
//
//   One WSO2 (localhost:3000) --Bearer <ThunderID or Asgardeo token>--> :9089 --x-jwt-assertion <dev JWT>--> :9090
//
// - CORS for the One WSO2 dev server.
// - Reads sub / email / groups from the incoming bearer WITHOUT verifying it (local only; amplify-api's dev
//   JWT mode is itself refused outside environment=local), then mints a dev JWT with mint-dev-jwt.sh.
// - Role switch: put "po", "marketing", "employee" or "token" in ./role (default "token" = use the token's
//   groups/roles claim). Takes effect on the next request; no restart.
// - USERINFO_URL (optional): the IdP's OIDC userinfo endpoint, asked once per user when the access token
//   has no email (ThunderID's doesn't). Without it, a token with no email maps to <sub>@example.com.
//
// Run (stack up, from apps/amplify): node local/one-wso2-proxy/proxy.mjs
import http from "node:http";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const MINT = process.env.MINT_SCRIPT ?? join(HERE, "..", "dev-jwt", "mint-dev-jwt.sh");
const TARGET = { host: process.env.TARGET_HOST ?? "127.0.0.1", port: Number(process.env.TARGET_PORT ?? 9090) };
const PORT = Number(process.env.PORT ?? 9089);
const ORIGIN = process.env.ORIGIN ?? "http://localhost:3000";
const ROLE_GROUPS = { po: ["amplify_po"], marketing: ["amplify_marketing"], employee: [] };

const cache = new Map();
// sub -> { email, name, until }: ThunderID's access token carries no email, so ask userinfo once per user.
const USERINFO = process.env.USERINFO_URL ?? "";
const profiles = new Map();

async function profileOf(sub, auth) {
  if (!USERINFO) return {};
  const hit = profiles.get(sub);
  if (hit && hit.until > Date.now()) return hit;
  try {
    const res = await fetch(USERINFO, { headers: { Authorization: auth } });
    if (!res.ok) throw new Error(`userinfo ${res.status}`);
    const u = await res.json();
    const p = { email: u.email, groups: u.groups, until: Date.now() + 30 * 60 * 1000 };
    profiles.set(sub, p);
    console.log(`userinfo for ${sub}: email=${u.email ?? "none"} groups=${JSON.stringify(u.groups ?? null)}`);
    return p;
  } catch (e) {
    console.error("userinfo failed", e.message);
    return {};
  }
}
const loggedClaims = new Set();

function claims(auth) {
  const m = /^Bearer\s+([^.]+)\.([^.]+)\./i.exec(auth ?? "");
  if (!m) return null;
  try {
    return JSON.parse(Buffer.from(m[2], "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

function role() {
  try {
    return readFileSync(join(HERE, "role"), "utf8").trim() || "token";
  } catch {
    return "token";
  }
}

function devJwt(c) {
  const sub = String(c.sub ?? "dev-user");
  const email = String(c.email ?? c.preferred_username ?? c.username ?? `${sub}@example.com`);
  const r = role();
  const raw = c.groups ?? c.roles ?? [];
  const tokenGroups = (Array.isArray(raw) ? raw : String(raw).split(/[ ,]+/)).filter((g) => g.startsWith("amplify_"));
  const groups = ROLE_GROUPS[r] ?? tokenGroups;
  const key = `${sub}|${email}|${groups.join(",")}`;
  const hit = cache.get(key);
  if (hit && hit.until > Date.now()) return { token: hit.token, sub, email, groups };
  const token = execFileSync(MINT, ["token", sub, email, ...groups], { encoding: "utf8" }).trim();
  cache.set(key, { token, until: Date.now() + 20 * 60 * 1000 });
  return { token, sub, email, groups };
}

const cors = {
  "Access-Control-Allow-Origin": ORIGIN,
  "Access-Control-Allow-Credentials": "true",
  "Access-Control-Allow-Methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
  "Access-Control-Allow-Headers": "Authorization,Content-Type,Idempotency-Key,X-Correlation-ID,If-None-Match",
  "Access-Control-Expose-Headers": "ETag,X-Correlation-ID,Idempotent-Replayed",
  "Access-Control-Max-Age": "600",
};

http
  .createServer(async (req, res) => {
    if (req.method === "OPTIONS") {
      res.writeHead(204, cors).end();
      return;
    }
    let c = claims(req.headers.authorization);
    if (c && !c.email && c.sub) {
      const p = await profileOf(c.sub, req.headers.authorization);
      c = { ...c, email: p.email ?? c.email, groups: c.groups ?? p.groups };
    }
    if (!c) {
      res.writeHead(401, { ...cors, "Content-Type": "application/problem+json" });
      res.end(JSON.stringify({ type: "urn:dev-proxy", title: "No bearer", status: 401, code: "TOKEN_MISSING" }));
      return;
    }
    const seen = `${c.sub}|${c.scope ?? ""}|${JSON.stringify(c.groups ?? null)}|${JSON.stringify(c.roles ?? null)}`;
    if (!loggedClaims.has(seen)) {
      loggedClaims.add(seen);
      console.log(
        `token claims: [${Object.keys(c).join(", ")}] scope="${c.scope ?? ""}" groups=${JSON.stringify(c.groups ?? null)} roles=${JSON.stringify(c.roles ?? null)}`,
      );
    }
    let minted;
    try {
      minted = devJwt(c);
    } catch (e) {
      console.error("mint failed", e.message);
      res.writeHead(500, cors).end();
      return;
    }
    const headers = { ...req.headers, "x-jwt-assertion": minted.token, host: `${TARGET.host}:${TARGET.port}` };
    delete headers.authorization;
    delete headers.origin;
    const up = http.request({ ...TARGET, path: req.url, method: req.method, headers }, (upRes) => {
      res.writeHead(upRes.statusCode ?? 502, { ...upRes.headers, ...cors });
      upRes.pipe(res);
      console.log(`${req.method} ${req.url} -> ${upRes.statusCode}  [${minted.email} ${minted.groups.join(",") || "employee"}]`);
    });
    up.on("error", (e) => {
      console.error("upstream", e.message);
      if (!res.headersSent) res.writeHead(502, cors);
      res.end();
    });
    req.pipe(up);
  })
  .listen(PORT, "127.0.0.1", () => console.log(`amplify dev proxy on http://localhost:${PORT} -> ${TARGET.host}:${TARGET.port} (role: ${role()})`));
