# tunnel: receive webhooks on your laptop

`https://hook.<domain>` is a fixed URL on our own domain (the zone in `mock-server/wrangler.toml`),
routed through a Cloudflare Tunnel to whoever on the team is listening. Anything a provider sends
to it is printed in that person's terminal:

```
$ tunnel/tunnel.sh listen
tunnel: listening on https://hook.<domain> — every request is printed below (Ctrl-C to stop)

────────────────────────────────────────────────────────────────────────
#1 12:47:52  POST /gupshup/dlr?x=1  from 203.0.113.7
  content-type: application/json
  x-signature: abc
  (+6 Cloudflare headers; TUNNEL_VERBOSE=1 shows them)

{
  "event": "delivered",
  "n": 1
}
```

Every request gets `200 {"ok":true}`. Any path works, so you can mirror the real route
(`https://hook.<domain>/api/webhooks/gupshup`). Query params on the webhook URL change the reply:

| Param | Effect |
|---|---|
| `_status=500` | Respond with that status. Use it to test the provider's retries. |
| `_delay=3000` | Wait that many ms before replying (max 10000). Use it to test timeouts. |
| `hub.challenge=...` (GET) | Echoed back, for Meta/WhatsApp subscription checks. |

To send the webhook into your running app instead of printing it, run
`tunnel/tunnel.sh up 8080`. The same URL then forwards to `localhost:8080`.

## One-time setup per laptop

You need `cloudflared` and Node. The script installs `cloudflared` with Homebrew if it's missing.
Then use **one** of these:

- **You have access to the domain in Cloudflare:** just run `tunnel/tunnel.sh listen`. The first
  time, a browser opens: sign in and pick the domain. The script creates the `themis-hook` tunnel
  and the `hook` DNS record if they don't exist yet.
- **You don't:** ask someone who does to run `tunnel/tunnel.sh token` and send you the line it
  prints. Put it in `tunnel/.env`, which is gitignored:
  ```bash
  TUNNEL_TOKEN=eyJh...
  ```
  This must be the tunnel token from that command. A Cloudflare API token (`cfut_...`) doesn't
  work here.

**The tunnel token lets anyone receive the team's webhooks.** Share it in a DM or password
manager. Never put it in a public channel, a commit or a notification.

## One listener at a time

Everyone shares `hook.<domain>`. If two laptops are connected, Cloudflare splits requests between
them, so each person sees only some. So `listen` and `up` check first and refuse to start if
someone is already connected. The error names that person's user and machine. Your options:

- ask them to stop;
- use your own URL: `TUNNEL_SUBDOMAIN=priya tunnel/tunnel.sh listen` gives
  `https://priya.<domain>`, and needs `token` for `priya` or a Cloudflare login;
- `TUNNEL_FORCE=1` to connect anyway.

`tunnel/tunnel.sh status` shows who is listening right now.

## Settings: `tunnel/.env` (gitignored, all optional)

```bash
TUNNEL_TOKEN=eyJh...             # from `tunnel/tunnel.sh token`; skips the Cloudflare login
TUNNEL_SUBDOMAIN=hook            # default: hook. One label only (a.b.<domain> fails TLS)
TUNNEL_PORT=8080                 # default app port for `up`
TUNNEL_RECEIVER_PORT=9876        # local port `listen` uses for the printer
TUNNEL_VERBOSE=1                 # also print Cloudflare's headers (cf-ray, x-forwarded-for, ...)
```

Variables set in your shell override the file. Rarely needed: `TUNNEL_DOMAIN` overrides the zone,
and `TUNNEL_ORIGIN_CERT` points at a Cloudflare login for this zone if your default
`~/.cloudflared/cert.pem` is for another one.

## Commands

| Command | What it does |
|---|---|
| `listen` | Prints every request sent to the URL. |
| `up [port]` | Forwards the URL to your app on `localhost:<port>`. |
| `status` | Shows the URL, your auth, and who is listening. |
| `token` | (Needs Cloudflare access.) Prints the `TUNNEL_TOKEN` line for colleagues. |
| `delete` | Deletes the tunnel. Remove its DNS record in the Cloudflare dashboard afterwards. |

## Things to know

- **Point only test/staging integrations here.** Payloads can contain phone numbers, signatures
  and auth headers, and they're printed in plain text.
- **The URL returns a Cloudflare error (530) when nobody is connected.** Providers treat that as
  a failed delivery and may retry or disable the webhook. If you want every request kept even
  when nobody is at their laptop, use [`mock-server/`](../mock-server/README.md). It is always
  up and stores requests for 72 hours.
- **The script never overwrites DNS.** If `hook.<domain>` already has a record that isn't this
  tunnel's, it stops and tells you.
