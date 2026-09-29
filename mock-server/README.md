# mock-server: webhook inspector

A Cloudflare Worker that captures any HTTP request sent to it, so you can see exactly what a
third-party webhook sends: method, route, query, headers and body. It works like webhook.site,
but it's ours, on our domain, and defined in this repo.

The public hostname is set in `wrangler.toml` (`routes`). The code never references it; the
examples below use `<host>`.

## Using it (no setup needed)

1. Pick a **bin** name for what you're testing, e.g. `gupshup-dlr` or `razorpay-payouts`.
2. Set the third party's webhook URL to `https://<host>/<bin>/<any/path>`. Everything after the
   bin is recorded as-is, so you can mirror the real route (`/gupshup-dlr/api/webhooks/dlr`).
3. Open `https://<host>/_inspect/<bin>`. It shows requests live, and each one has **Copy as cURL**
   so you can replay it against `localhost` or staging.

The server always replies `200 {"ok":true,...}`. You can change that with query params on the
webhook URL:

| Param | Effect |
|---|---|
| `_status=500` | Respond with that status. Use it to test the provider's retry behaviour. |
| `_delay=3000` | Wait that many ms before replying (max 10000). Use it to test timeouts. |
| `hub.challenge=...` (GET) | Echoed back as plain text, for Meta/WhatsApp-style subscription handshakes. |

JSON API, for scripts: `GET /_api/bins/<bin>` (newest first; `?limit=`, `?since=<seq>`),
`GET /_api/bins/<bin>/<id>`, `DELETE /_api/bins/<bin>`.

**Limits:** the newest 200 requests per bin are kept, for 72 hours. Bodies over 256 KiB are
truncated. Binary bodies are stored as base64. All of these are `[vars]` in `wrangler.toml`.

### Privacy
Anyone who knows a bin name can read that bin, unless the `INSPECT_TOKEN` secret is set. When it
is, the inspect page and API need `?token=<INSPECT_TOKEN>` or `Authorization: Bearer ...`.
Capturing never needs the token, since third parties can't send it. Point only **test/staging**
integrations here, never production: payloads can contain phone numbers, signatures and auth
headers.

## Running locally

```bash
cd mock-server
npm install
npm run dev            # http://localhost:8787, storage persisted in .wrangler/ (gitignored)
npm run smoke          # end-to-end check against the local server
```

To receive real webhooks locally, expose the dev server with `tunnel/tunnel.sh up 8787` (see
`tunnel/README.md`). For a local token, put `INSPECT_TOKEN=...` in
`mock-server/.dev.vars` (gitignored).

## Deploying

A push to `main` that touches `mock-server/**` deploys automatically
(`.github/workflows/deploy-mock-server.yml`). You can also trigger it manually from the Actions tab.

One-time setup (GitHub → Settings → Secrets and variables → Actions):

| Name | Kind | Value |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | secret | Cloudflare API token from the **Edit Cloudflare Workers** template, scoped to the account and the domain's zone |
| `CLOUDFLARE_ACCOUNT_ID` | secret | Cloudflare account ID (dashboard sidebar) |
| `MOCK_SERVER_URL` | variable | e.g. `https://<host>`. Optional; if set, the deploy runs the smoke test against it |
| `INSPECT_TOKEN` | secret | Only if you enabled the token (see below), so the smoke test can read bins |

To enable the inspect token on the deployed Worker, run `npx wrangler secret put INSPECT_TOKEN`.

For a manual deploy with your own Cloudflare login: `npx wrangler login && npm run deploy`.

`npm run tail` streams live logs, one line per captured request, if you have Cloudflare access.

**Changing the hostname:** edit `routes` in `wrangler.toml`. The domain's zone must be on the same
Cloudflare account, and the hostname must not already have a DNS record, because Cloudflare
creates it on deploy.
