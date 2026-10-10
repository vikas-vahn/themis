// Stand-in for the third parties plutus-api calls during the core E2E flows.
// No dependencies: runs on a bare node image inside the E2E Docker network.
//
// Routes are registered in ./routes/*.js. Any request that no route matches
// is answered with 501 and recorded, and `GET /_unmatched` lists them, so a
// new outbound call introduced by a backend change shows up in the run report
// instead of silently timing out.

const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = Number(process.env.PORT || 4010);
const PUBLIC_URL = (process.env.MOCKS_PUBLIC_URL || `http://localhost:${PORT}`).replace(/\/$/, "");

const routes = [];
const unmatched = [];
const calls = [];
const state = new Map();

const ctx = { publicUrl: PUBLIC_URL, state };

function route(method, pattern, handler) {
  const keys = [];
  const source = pattern.replace(/:[a-zA-Z]+/g, (m) => {
    keys.push(m.slice(1));
    return "([^/]+)";
  });
  routes.push({ method, regex: new RegExp(`^${source}/?$`), keys, handler });
}

for (const file of fs.readdirSync(path.join(__dirname, "routes")).sort()) {
  if (file.endsWith(".js")) require(path.join(__dirname, "routes", file))(route, ctx);
}

function send(res, status, body, headers = {}) {
  const isText = typeof body === "string";
  const payload = isText ? body : JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": isText ? "text/html; charset=utf-8" : "application/json",
    ...headers,
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch {
        resolve({ _raw: raw });
      }
    });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://mocks");
  const pathname = url.pathname;

  if (pathname === "/_health") return send(res, 200, { ok: true });
  if (pathname === "/_unmatched") return send(res, 200, unmatched);
  if (pathname === "/_calls") return send(res, 200, calls);

  const body = await readBody(req);
  for (const r of routes) {
    if (r.method !== req.method) continue;
    const m = pathname.match(r.regex);
    if (!m) continue;
    const params = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])]));
    calls.push({ at: new Date().toISOString(), method: req.method, path: pathname });
    try {
      const out = await r.handler({ params, query: url.searchParams, body, headers: req.headers });
      return send(res, out.status || 200, out.body, out.headers);
    } catch (err) {
      console.error(`[mocks] handler error ${req.method} ${pathname}:`, err);
      return send(res, 500, { success: false, message: String(err) });
    }
  }

  const entry = {
    at: new Date().toISOString(),
    method: req.method,
    path: pathname,
    // Field names only. plutus-api sends whatever credentials it is configured
    // with (ULIP login, API keys), and those must never end up in a report.
    queryKeys: [...url.searchParams.keys()],
    bodyKeys: body && typeof body === "object" ? Object.keys(body) : [],
  };
  unmatched.push(entry);
  console.warn(`[mocks] UNMATCHED ${req.method} ${pathname}`);
  send(res, 501, { success: false, message: `e2e mocks: no route for ${req.method} ${pathname}` });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[mocks] listening on :${PORT}, public url ${PUBLIC_URL}, ${routes.length} routes`);
});
