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

// Local stand-in for Novera's gateway: POST /token (client credentials) and POST /internal/notifications.
// Logs every notification's JSON and answers 202. Nothing reaches Google Chat.
// If CHECK_URL is set (local Novera, e.g. http://localhost:3002/internal/notifications), the body is also
// sent there and its verdict is logged: 400 = Novera's schema rejects it, 503 = schema OK (no Google key).
// Run: node server.mjs   (PORT defaults to 3003)
import http from "node:http";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Cards land in OUT_DIR/last-card.json (full Chat message) and last-card-builder.json (inner card only). Paste the latter into Google's Card Builder
// (https://addons.gsuite.google.com/uikit/builder) to see the real Chat rendering.
// `fileURLToPath` decodes a checkout path with a space (`my%20dir`); a trailing slash is added so `OUT_DIR=/tmp/x` works.
const OUT_DIR = ((dir) => (dir.endsWith("/") ? dir : dir + "/"))(process.env.OUT_DIR || fileURLToPath(new URL("./out/", import.meta.url)));
let lastCard = null;

// Port of buildCard() in wso2-digital-agents/po-agent/src/chat/notify.ts (as of main 3a1138d).
// `imageUrl` (image widget) and `button` {url,label} (buttonList) are on branch feat/notification-image-button.
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const cutAtWord = (t, max) => {
  const c = [...t];
  if (c.length <= max) return t;
  const cut = c.slice(0, max).join("");
  const sp = cut.lastIndexOf(" ");
  return (sp > 0 ? cut.slice(0, sp) : cut).trimEnd();
};
function buildCard(n) {
  const body = String(n.body ?? "").replace(/\s+/g, " ");
  const preview = cutAtWord(body, 240);
  const more = n.link ? ` <a href="${esc(n.link.url)}">…${esc(n.link.label)}</a>` : preview !== body ? "…" : "";
  let subtitle;
  if (n.subtitle) {
    const cut = cutAtWord(n.subtitle, 36);
    subtitle = cut === n.subtitle ? cut : `${cut}…`;
  }
  const widgets = [
    { decoratedText: { ...(n.iconUrl ? { startIcon: { iconUrl: n.iconUrl } } : {}), text: `<b>${esc(n.title)}</b>`, wrapText: true, ...(subtitle ? { bottomLabel: subtitle } : {}) } },
    { divider: {} },
  ];
  if (n.imageUrl) widgets.push({ image: { imageUrl: n.imageUrl, altText: n.title } });
  widgets.push({ textParagraph: { text: `${esc(preview)}${more}` } });
  if (n.button) widgets.push({ buttonList: { buttons: [{ text: n.button.label, onClick: { openLink: { url: n.button.url } } }] } });
  if (n.footer) widgets.push({ divider: {} }, { textParagraph: { text: `<font color="#5f6368">${esc(n.footer)}</font>` } });
  return { cardsV2: [{ cardId: `notification-${n.source}`, card: { sections: [{ widgets }] } }] };
}

const PORT = Number(process.env.PORT || 3003);
const CHECK_URL = process.env.CHECK_URL || "";

// req.url is the raw request target: percent-encoded, maybe with a query string and/or a trailing slash.
// Decode it and drop the trailing slash so /token, /token/ and /tok%65n all reach the same handler.
// A malformed escape (e.g. /%zz) is not a path we serve, so it answers 404 like any other unknown route.
const pathOf = (url) => {
  try {
    const p = new URL(String(url ?? "/"), "http://localhost").pathname;
    return decodeURIComponent(p).replace(/\/+$/, "") || "/";
  } catch {
    return null;
  }
};

const read = (req) => new Promise((resolve) => {
  let data = "";
  req.on("data", (c) => (data += c));
  req.on("end", () => resolve(data));
});
const send = (res, status, body) => {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
};

http.createServer(async (req, res) => {
  const raw = await read(req);
  const path = pathOf(req.url);
  if (req.method === "POST" && path === "/token") {
    return send(res, 200, { access_token: "mock-token", token_type: "Bearer", expires_in: 3600 });
  }
  if (req.method === "POST" && path === "/internal/notifications") {
    let json;
    try { json = JSON.parse(raw); } catch { console.log("[mock-novera] not JSON:", raw); return send(res, 400, { error: "not JSON" }); }
    console.log(`\n[mock-novera] ${new Date().toISOString()} notification\n${JSON.stringify(json, null, 2)}`);
    lastCard = buildCard(json);
    mkdirSync(OUT_DIR, { recursive: true });
    writeFileSync(OUT_DIR + "last-card.json", JSON.stringify(lastCard, null, 2));
    writeFileSync(OUT_DIR + "last-card-builder.json", JSON.stringify(lastCard.cardsV2[0].card, null, 2));
    console.log(`[mock-novera] Chat message -> ${OUT_DIR}last-card.json (or GET /card); Card Builder paste (inner card only) -> ${OUT_DIR}last-card-builder.json`);
    if (CHECK_URL) {
      try {
        const r = await fetch(CHECK_URL, { method: "POST", headers: { "Content-Type": "application/json" }, body: raw });
        const t = await r.text();
        console.log(`[mock-novera] real Novera says ${r.status} ${t} (400 = schema rejected, 503 = schema ok)`);
      } catch (e) { console.log("[mock-novera] real Novera unreachable:", e.message); }
    }
    return send(res, 202, { accepted: true });
  }
  if (req.method === "GET" && path === "/card") return send(res, lastCard ? 200 : 404, lastCard ?? { error: "no notification yet" });
  if (path === "/health") return send(res, 200, { status: "ok" });
  send(res, 404, { error: "not found" });
}).listen(PORT, "0.0.0.0", () => console.log(`[mock-novera] listening on ${PORT}`));
