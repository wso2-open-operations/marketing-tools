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
// Local prototype only: stands in for the Choreo gateway in front of people-app.
//
//   POST /token            OAuth2 client credentials (form or Basic auth) -> opaque access token
//   any other request      Bearer <that token>  ->  x-jwt-assertion {azp, sub = client id, aut = APPLICATION}  ->  people-app
//
// The assertion is unsigned: people-app only decodes it (the real gateway signs it). Clients come from
// CLIENTS="id:secret,id2:secret2". No user tokens here; call people-app directly for those.
import http from "node:http";
import { randomBytes } from "node:crypto";

const PORT = Number(process.env.PORT ?? 8080);
const UPSTREAM = new URL(process.env.UPSTREAM ?? "http://people-proto-app:9090");
const CLIENTS = new Map((process.env.CLIENTS ?? "").split(",").filter(Boolean).map((c) => c.split(":")));
const tokens = new Map();
const b64url = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

function clientOf(req, form) {
  const basic = /^Basic\s+(.+)$/i.exec(req.headers.authorization ?? "");
  if (basic) return Buffer.from(basic[1], "base64").toString().split(":");
  return [form.get("client_id"), form.get("client_secret")];
}

http
  .createServer((req, res) => {
    if (req.method === "POST" && req.url === "/token") {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        const [id, secret] = clientOf(req, new URLSearchParams(body));
        if (!id || CLIENTS.get(id) !== secret) {
          res.writeHead(401, { "Content-Type": "application/json" }).end('{"error":"invalid_client"}');
          return;
        }
        const token = randomBytes(24).toString("hex");
        tokens.set(token, id);
        console.log(`token issued to ${id}`);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ access_token: token, token_type: "Bearer", expires_in: 3600 }));
      });
      return;
    }
    const bearer = /^Bearer\s+(.+)$/i.exec(req.headers.authorization ?? "")?.[1];
    const clientId = bearer && tokens.get(bearer);
    if (!clientId) {
      res.writeHead(401, { "Content-Type": "application/json" }).end('{"message":"gateway: unknown token"}');
      return;
    }
    const now = Math.floor(Date.now() / 1000);
    const assertion = `${b64url({ alg: "RS256", typ: "JWT" })}.${b64url({
      iss: "people-proto-gateway", sub: clientId, azp: clientId, aut: "APPLICATION", aud: "people-app", iat: now, exp: now + 900,
    })}.unsigned`;
    const headers = { ...req.headers, "x-jwt-assertion": assertion, host: UPSTREAM.host };
    delete headers.authorization;
    // Hop-by-hop headers stay on this leg: a Ballerina client's HTTP/2 upgrade offer would otherwise reach
    // people-app, which accepts it, and this HTTP/1 relay then never completes the response.
    for (const h of ["connection", "upgrade", "http2-settings", "keep-alive", "te", "proxy-connection"]) delete headers[h];
    const up = http.request(
      { hostname: UPSTREAM.hostname, port: UPSTREAM.port, path: req.url, method: req.method, headers },
      (upRes) => {
        console.log(`${req.method} ${req.url} as ${clientId} -> ${upRes.statusCode}`);
        res.writeHead(upRes.statusCode ?? 502, upRes.headers);
        upRes.pipe(res);
      },
    );
    up.on("error", (e) => {
      console.error("upstream", e.message);
      if (!res.headersSent) res.writeHead(502);
      res.end();
    });
    req.pipe(up);
  })
  .listen(PORT, () => console.log(`gateway stub on :${PORT} -> ${UPSTREAM.href}`));
