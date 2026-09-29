// Local webhook receiver: prints every request it gets (method, path, headers,
// body) to the terminal and replies 200. `tunnel/tunnel.sh listen` runs it
// behind the Cloudflare Tunnel. See tunnel/README.md.
//
//   node tunnel/receiver.mjs [port]      (default 9876)
//
// Reply overrides, as query params on the webhook URL (same as mock-server):
//   ?_status=500   respond with that status, to test the provider's retries
//   ?_delay=3000   wait that many ms before replying (max 10000)
//   GET ?hub.challenge=...  echoed back, for Meta/WhatsApp subscription checks

import http from "node:http";
import os from "node:os";

const port = Number(process.argv[2] || process.env.TUNNEL_RECEIVER_PORT || 9876);
const allHeaders = process.env.TUNNEL_VERBOSE === "1";
const maxPrintBytes = 64 * 1024;

// Answered by the receiver itself, so `listen` can tell whether someone else is
// already on the shared hostname before it joins.
const PROBE_PATH = "/__themis_receiver";

const tty = process.stdout.isTTY;
const c = (code) => (s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : String(s));
const bold = c("1"), dim = c("2"), cyan = c("36"), green = c("32"), yellow = c("33"), red = c("31");

// Headers Cloudflare adds on the way in; noise unless TUNNEL_VERBOSE=1.
const isProxyHeader = (h) =>
  h.startsWith("cf-") || h.startsWith("x-forwarded-") || ["cdn-loop", "x-real-ip"].includes(h);

let count = 0;
const startedAt = new Date().toISOString();

function formatBody(buf, contentType = "") {
  if (buf.length === 0) return dim("(empty body)");
  const truncated = buf.length > maxPrintBytes;
  const text = buf.subarray(0, maxPrintBytes).toString("utf8");
  const note = truncated ? "\n" + yellow(`... truncated, ${buf.length} bytes total`) : "";

  if (/json/i.test(contentType) || /^\s*[{[]/.test(text)) {
    try {
      return JSON.stringify(JSON.parse(buf.toString("utf8")), null, 2);
    } catch {
      // not valid JSON after all; fall through to text
    }
  }
  if (/x-www-form-urlencoded/i.test(contentType)) {
    const rows = [...new URLSearchParams(text)].map(([k, v]) => `  ${cyan(k)} = ${v}`);
    return rows.join("\n") + note;
  }
  // Treat it as binary if it has control characters other than whitespace.
  if (/[\x00-\x08\x0e-\x1f]/.test(text)) {
    return dim(`(binary, ${buf.length} bytes, base64)`) + "\n" + buf.subarray(0, 512).toString("base64") + note;
  }
  return text + note;
}

function print(req, url, body) {
  count += 1;
  const from = req.headers["cf-connecting-ip"] || req.socket.remoteAddress;
  const time = new Date().toLocaleTimeString();
  const lines = [
    "",
    dim("─".repeat(72)),
    `${bold(`#${count}`)} ${dim(time)}  ${bold(green(req.method))} ${bold(url.pathname)}${url.search}  ${dim(`from ${from}`)}`,
  ];
  const hidden = [];
  for (const [name, value] of Object.entries(req.headers)) {
    if (!allHeaders && isProxyHeader(name)) {
      hidden.push(name);
      continue;
    }
    lines.push(`  ${cyan(name)}: ${Array.isArray(value) ? value.join(", ") : value}`);
  }
  if (hidden.length) lines.push(dim(`  (+${hidden.length} Cloudflare headers; TUNNEL_VERBOSE=1 shows them)`));
  lines.push("", formatBody(body, req.headers["content-type"]));
  console.log(lines.join("\n"));
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", async () => {
    const url = new URL(req.url, "http://receiver");

    if (url.pathname === PROBE_PATH) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ receiver: true, user: os.userInfo().username, host: os.hostname(), since: startedAt }));
      return;
    }

    print(req, url, Buffer.concat(chunks));

    const delay = Math.min(Number(url.searchParams.get("_delay")) || 0, 10000);
    if (delay > 0) await new Promise((r) => setTimeout(r, delay));

    const challenge = url.searchParams.get("hub.challenge");
    if (req.method === "GET" && challenge !== null) {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(challenge);
      return;
    }
    const wanted = Number(url.searchParams.get("_status"));
    const status = wanted >= 200 && wanted <= 599 ? wanted : 200;
    if (status !== 200) console.log(yellow(`  -> replied ${status}`));
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: status < 400, id: count }));
  });
});

server.on("error", (err) => {
  console.error(red(`receiver: ${err.message}`));
  process.exit(1);
});

server.listen(port, "127.0.0.1", () => {
  if (process.env.TUNNEL_PUBLIC_URL) return; // tunnel.sh prints the banner once the tunnel is up
  console.log(`receiver: printing requests sent to http://localhost:${port} (Ctrl-C to stop)`);
});
