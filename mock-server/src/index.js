import { inspectorPage, homePage } from "./pages.js";

export { Bin } from "./bin.js";

// Everything under /_ is reserved for the server itself; any other path is
// captured. The first path segment is the bin, e.g. /gupshup/delivery-report
// lands in bin "gupshup".
const BIN_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
const MAX_DELAY_MS = 10_000;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);
    const [first = "", second, third] = segments;

    if (url.pathname === "/" && request.method === "GET") {
      return html(homePage(url.origin));
    }
    if (first === "_health") {
      return json({ ok: true });
    }
    if (first === "_inspect" && BIN_NAME.test(second ?? "")) {
      return authorized(request, env) ? html(inspectorPage(url.origin, second)) : unauthorized();
    }
    if (first === "_api" && second === "bins" && BIN_NAME.test(third ?? "")) {
      return authorized(request, env) ? api(request, env, url, third, segments.slice(3)) : unauthorized();
    }
    if (first.startsWith("_") || !BIN_NAME.test(first)) {
      return json({ error: "Send requests to /<bin>/<any/path>. Bin names: letters, digits, _ and -, max 64." }, 400);
    }
    return capture(request, env, url, first);
  },
};

async function capture(request, env, url, bin) {
  const maxBody = Number(env.MAX_BODY_BYTES) || 262_144;
  const raw = new Uint8Array(await request.arrayBuffer());
  const stored = raw.subarray(0, maxBody);
  const { body, bodyEncoding } = decodeBody(stored);

  const entry = {
    id: crypto.randomUUID(),
    receivedAt: Date.now(),
    method: request.method,
    path: url.pathname,
    query: Object.fromEntries(url.searchParams),
    rawQuery: url.search,
    headers: Object.fromEntries(request.headers),
    body,
    bodyEncoding,
    bodySize: raw.byteLength,
    bodyTruncated: raw.byteLength > maxBody,
    ip: request.headers.get("cf-connecting-ip"),
    country: request.cf?.country ?? null,
  };

  await binStub(env, bin).record(entry);
  // Also visible live via `npm run tail` for anyone with Cloudflare access.
  console.log(JSON.stringify({ bin, id: entry.id, method: entry.method, path: entry.path, bodySize: entry.bodySize }));

  const delay = Math.min(Number(url.searchParams.get("_delay")) || 0, MAX_DELAY_MS);
  if (delay > 0) await new Promise((r) => setTimeout(r, delay));

  // Webhook subscription handshakes (Meta / WhatsApp Cloud API style) expect
  // the challenge echoed back as plain text.
  const challenge = url.searchParams.get("hub.challenge");
  if (request.method === "GET" && challenge !== null) {
    return new Response(challenge, { headers: { "content-type": "text/plain" } });
  }

  const status = Number(url.searchParams.get("_status"));
  return json({ ok: true, bin, id: entry.id }, status >= 200 && status <= 599 ? status : 200);
}

async function api(request, env, url, bin, rest) {
  const stub = binStub(env, bin);
  if (request.method === "GET" && rest.length === 0) {
    const limit = Number(url.searchParams.get("limit")) || 50;
    const since = Number(url.searchParams.get("since")) || 0;
    return json({ bin, requests: await stub.list(limit, since) });
  }
  if (request.method === "GET" && rest.length === 1) {
    const entry = await stub.get(rest[0]);
    return entry ? json(entry) : json({ error: "not found" }, 404);
  }
  if (request.method === "DELETE" && rest.length === 0) {
    await stub.clear();
    return json({ ok: true });
  }
  return json({ error: "not found" }, 404);
}

function binStub(env, bin) {
  return env.BINS.get(env.BINS.idFromName(bin));
}

// UTF-8 text is stored as-is; anything else (images, protobuf, ...) as base64.
function decodeBody(bytes) {
  if (bytes.byteLength === 0) return { body: "", bodyEncoding: "utf8" };
  try {
    return { body: new TextDecoder("utf-8", { fatal: true }).decode(bytes), bodyEncoding: "utf8" };
  } catch {
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    return { body: btoa(bin), bodyEncoding: "base64" };
  }
}

// When the INSPECT_TOKEN secret is set, viewing captured requests needs it,
// as ?token=... or "Authorization: Bearer ...". Capturing never does.
function authorized(request, env) {
  if (!env.INSPECT_TOKEN) return true;
  const url = new URL(request.url);
  const header = request.headers.get("authorization") ?? "";
  const given = url.searchParams.get("token") ?? header.replace(/^Bearer\s+/i, "");
  return timingSafeEqual(given, env.INSPECT_TOKEN);
}

function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  if (x.byteLength !== y.byteLength) return false;
  return crypto.subtle.timingSafeEqual(x, y);
}

function unauthorized() {
  return json({ error: "Missing or wrong token. Pass ?token=<INSPECT_TOKEN>." }, 401);
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

function html(body) {
  return new Response(body, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      // Captured payloads are untrusted; the page renders them as text only,
      // and this blocks anything else from loading or running.
      "content-security-policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'self'",
      "referrer-policy": "no-referrer",
    },
  });
}
