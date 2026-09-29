// End-to-end check against a running server:
//   npm run smoke                              # local `npm run dev` on :8787
//   npm run smoke -- https://mommopommo.site   # deployed (pass INSPECT_TOKEN if set)
const base = (process.argv[2] ?? "http://localhost:8787").replace(/\/$/, "");
const token = process.env.INSPECT_TOKEN;
const bin = `smoke-${Date.now()}`;
const auth = token ? { authorization: `Bearer ${token}` } : {};

function check(cond, msg) {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exit(1);
  }
  console.log(`ok   ${msg}`);
}

const sent = await fetch(`${base}/${bin}/orders/callback?_status=202&x=1`, {
  method: "POST",
  headers: { "content-type": "application/json", "x-signature": "abc123" },
  body: JSON.stringify({ event: "delivered", n: 1 }),
});
check(sent.status === 202, `capture returns _status override (got ${sent.status})`);
const { id } = await sent.json();

const list = await (await fetch(`${base}/_api/bins/${bin}`, { headers: auth })).json();
const r = list.requests?.[0];
check(r?.id === id, "captured request is listed");
check(r.method === "POST" && r.path === `/${bin}/orders/callback`, "method and path recorded");
check(r.query.x === "1" && r.headers["x-signature"] === "abc123", "query and headers recorded");
check(JSON.parse(r.body).event === "delivered", "body recorded");

const challenge = await fetch(`${base}/${bin}/verify?hub.challenge=42`);
check((await challenge.text()) === "42", "hub.challenge echoed");

check((await fetch(`${base}/_nope`)).status === 400, "reserved path rejected");
check((await fetch(`${base}/_inspect/${bin}`, { headers: auth })).status === 200, "inspector page renders");

const cleared = await fetch(`${base}/_api/bins/${bin}`, { method: "DELETE", headers: auth });
const after = await (await fetch(`${base}/_api/bins/${bin}`, { headers: auth })).json();
check(cleared.ok && after.requests.length === 0, "clear empties the bin");
