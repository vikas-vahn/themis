// Server-rendered pages. Only the validated bin name and the request origin
// are interpolated; captured data is fetched as JSON and rendered with
// textContent, never innerHTML.

const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// Safe to drop inside a <script> block.
const jsLiteral = (v) => JSON.stringify(v).replace(/</g, "\\u003c");

const STYLE = `
  :root { --bg:#fff; --fg:#1b1f24; --muted:#656d76; --line:#d0d7de; --panel:#f6f8fa; --accent:#0969da; --sel:#ddf4ff; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0d1117; --fg:#e6edf3; --muted:#8d96a0; --line:#30363d; --panel:#161b22; --accent:#4493f8; --sel:#1f2d3d; }
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
  code, pre, .mono { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12.5px; }
  a { color:var(--accent); }
  header { display:flex; flex-wrap:wrap; gap:8px 16px; align-items:center; padding:12px 16px; border-bottom:1px solid var(--line); }
  header h1 { font-size:16px; margin:0; }
  button { background:var(--panel); color:var(--fg); border:1px solid var(--line); border-radius:6px; padding:4px 10px; cursor:pointer; font:inherit; }
  button:hover { border-color:var(--accent); }
  .muted { color:var(--muted); }
`;

export function homePage(origin) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Webhook Inspector</title>
<style>${STYLE}
  main { max-width:720px; margin:0 auto; padding:24px 16px; }
  pre { background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:12px; overflow-x:auto; }
  form { display:flex; gap:8px; margin:16px 0; }
  input { flex:1; min-width:0; padding:6px 10px; border:1px solid var(--line); border-radius:6px; background:var(--bg); color:var(--fg); font:inherit; }
</style></head>
<body><main>
<h1>Webhook Inspector</h1>
<p>Point a third-party webhook at any path under a bin of your choosing. Every request is captured
(method, route, query, headers, body) and shown on that bin's inspect page.</p>
<pre>${esc(origin)}/&lt;bin&gt;/&lt;any/path&gt;

curl -X POST '${esc(origin)}/my-test/orders/callback?x=1' \\
  -H 'content-type: application/json' -d '{"hello":"world"}'</pre>
<form action="" onsubmit="event.preventDefault(); const b=this.bin.value.trim(); if(b) location.href='/_inspect/'+encodeURIComponent(b);">
  <input name="bin" placeholder="bin name, e.g. gupshup-dlr" pattern="[A-Za-z0-9][A-Za-z0-9_-]{0,63}" required>
  <button>Inspect</button>
</form>
<p class="muted">Response knobs (query params on the webhook URL): <code>_status=500</code> sets the HTTP status,
<code>_delay=3000</code> waits that many ms (max 10000). <code>hub.challenge</code> on a GET is echoed back for
subscription handshakes. Captured data is kept for a limited time and is visible to anyone with the inspect link,
so use test data only.</p>
</main></body></html>`;
}

export function inspectorPage(origin, bin) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Inspect ${esc(bin)}</title>
<style>${STYLE}
  .layout { display:grid; grid-template-columns:minmax(240px,340px) 1fr; height:calc(100vh - 57px); }
  #list { overflow-y:auto; border-right:1px solid var(--line); }
  #list .item { padding:8px 16px; border-bottom:1px solid var(--line); cursor:pointer; }
  #list .item:hover { background:var(--panel); }
  #list .item.sel { background:var(--sel); }
  .method { font-weight:600; margin-right:6px; }
  .path { word-break:break-all; }
  #detail { overflow:auto; padding:16px; min-width:0; }
  #detail h2 { font-size:13px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:20px 0 6px; }
  #detail h2:first-child { margin-top:0; }
  table { border-collapse:collapse; width:100%; }
  td { border-top:1px solid var(--line); padding:4px 8px; vertical-align:top; word-break:break-all; }
  td:first-child { width:30%; color:var(--muted); white-space:nowrap; word-break:normal; }
  pre { background:var(--panel); border:1px solid var(--line); border-radius:6px; padding:12px; margin:0; white-space:pre-wrap; word-break:break-all; }
  .empty { padding:24px 16px; }
  .actions { display:flex; gap:8px; margin-left:auto; }
  @media (max-width:720px) {
    .layout { grid-template-columns:1fr; height:auto; }
    #list { border-right:none; max-height:40vh; border-bottom:1px solid var(--line); }
  }
</style></head>
<body>
<header>
  <h1>Bin: ${esc(bin)}</h1>
  <code class="muted">${esc(origin)}/${esc(bin)}/…</code>
  <span id="status" class="muted"></span>
  <div class="actions"><button id="pause">Pause</button><button id="clear">Clear bin</button></div>
</header>
<div class="layout">
  <div id="list"><div class="empty muted">Waiting for requests… send one to <code>${esc(origin)}/${esc(bin)}/anything</code></div></div>
  <div id="detail"></div>
</div>
<script>
const BIN = ${jsLiteral(bin)};
const ORIGIN = ${jsLiteral(origin)};
const token = new URLSearchParams(location.search).get("token");
const api = "/_api/bins/" + encodeURIComponent(BIN) + (token ? "?token=" + encodeURIComponent(token) + "&" : "?");
let entries = [], selected = null, lastSeq = 0, paused = false;

const el = (tag, props = {}, ...kids) => { const n = Object.assign(document.createElement(tag), props); n.append(...kids); return n; };

async function poll() {
  if (paused) return;
  try {
    const res = await fetch(api + "since=" + lastSeq + "&limit=200");
    if (!res.ok) throw new Error(res.status + " " + (await res.text()));
    const { requests } = await res.json();
    if (requests.length) {
      entries = requests.concat(entries).slice(0, 500);
      lastSeq = entries[0].seq;
      if (!selected) selected = entries[0].id;
      render();
    }
    document.getElementById("status").textContent = entries.length + " captured · live";
  } catch (e) {
    document.getElementById("status").textContent = "error: " + e.message;
  }
}

function render() {
  const list = document.getElementById("list");
  if (!entries.length) return;
  list.replaceChildren(...entries.map((r) => {
    const item = el("div", { className: "item" + (r.id === selected ? " sel" : "") },
      el("div", {}, el("span", { className: "method mono", textContent: r.method }), el("span", { className: "path mono", textContent: r.path + r.rawQuery })),
      el("div", { className: "muted", textContent: new Date(r.receivedAt).toLocaleString() + " · " + r.bodySize + " B" }));
    item.onclick = () => { selected = r.id; render(); };
    return item;
  }));
  renderDetail(entries.find((r) => r.id === selected));
}

function kvTable(obj) {
  const keys = Object.keys(obj);
  if (!keys.length) return el("div", { className: "muted", textContent: "(none)" });
  return el("table", {}, ...keys.sort().map((k) => el("tr", {}, el("td", { className: "mono", textContent: k }), el("td", { className: "mono", textContent: obj[k] }))));
}

function prettyBody(r) {
  if (r.bodyEncoding === "base64") return "[binary, base64]\\n" + r.body;
  const ct = (r.headers["content-type"] || "").toLowerCase();
  try { if (ct.includes("json") || /^\\s*[\\[{]/.test(r.body)) return JSON.stringify(JSON.parse(r.body), null, 2); } catch {}
  if (ct.includes("x-www-form-urlencoded")) {
    try { return JSON.stringify(Object.fromEntries(new URLSearchParams(r.body)), null, 2); } catch {}
  }
  return r.body;
}

function curlFor(r) {
  const q = (s) => "'" + String(s).replace(/'/g, "'\\\\''") + "'";
  const skip = /^(host|content-length|cf-|x-forwarded-|x-real-ip|cdn-loop|accept-encoding)/i;
  const parts = ["curl -X " + r.method + " " + q(ORIGIN + r.path + r.rawQuery)];
  for (const [k, v] of Object.entries(r.headers)) if (!skip.test(k)) parts.push("-H " + q(k + ": " + v));
  if (r.body && r.bodyEncoding === "utf8") parts.push("--data-raw " + q(r.body));
  return parts.join(" \\\\\\n  ");
}

function renderDetail(r) {
  const d = document.getElementById("detail");
  if (!r) { d.replaceChildren(); return; }
  const copy = el("button", { textContent: "Copy as cURL" });
  copy.onclick = async () => { await navigator.clipboard.writeText(curlFor(r)); copy.textContent = "Copied"; setTimeout(() => copy.textContent = "Copy as cURL", 1200); };
  const meta = { id: r.id, received: new Date(r.receivedAt).toISOString(), method: r.method, path: r.path, ip: r.ip || "", country: r.country || "",
    body: r.bodySize + " bytes" + (r.bodyTruncated ? " (truncated)" : "") };
  d.replaceChildren(
    el("h2", { textContent: "Request" }), kvTable(meta),
    el("h2", { textContent: "Query" }), kvTable(r.query),
    el("h2", { textContent: "Headers" }), kvTable(r.headers),
    el("h2", { textContent: "Body" }), r.body ? el("pre", { textContent: prettyBody(r) }) : el("div", { className: "muted", textContent: "(empty)" }),
    el("h2", { textContent: "Replay" }), copy);
}

document.getElementById("pause").onclick = (e) => { paused = !paused; e.target.textContent = paused ? "Resume" : "Pause"; if (!paused) poll(); };
document.getElementById("clear").onclick = async () => {
  if (!confirm("Delete every captured request in bin " + BIN + "?")) return;
  await fetch(api.replace(/[?&]$/, ""), { method: "DELETE" });
  entries = []; selected = null; lastSeq = 0;
  document.getElementById("list").replaceChildren(el("div", { className: "empty muted", textContent: "Cleared." }));
  renderDetail(null);
};

poll();
setInterval(poll, 2000);
</script>
</body></html>`;
}
