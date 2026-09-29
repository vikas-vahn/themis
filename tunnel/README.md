# tunnel: expose your local server on our domain

A Cloudflare Tunnel on our own domain gives each of us a fixed public URL, `https://<you>.<domain>`,
that forwards to a local port. Everyone uses the same domain, each on their own subdomain. Use it
to point a third-party webhook (Gupshup, Razorpay, ...) at code running on your laptop, with
breakpoints and logs.

`<domain>` is the zone from `mock-server/wrangler.toml` (`routes`) unless you set
`TUNNEL_DOMAIN`. Your hostname is `<TUNNEL_SUBDOMAIN>.<domain>`, and the subdomain defaults to
your macOS username.

> **Tunnel or mock-server?** If you only need to *see* what a provider sends, use
> [`mock-server/`](../mock-server/README.md). It needs no setup and stays up. Use a tunnel when the
> webhook must hit *your running code*.

## Quick start (you have access to the domain in Cloudflare)

```bash
tunnel/tunnel.sh up 8080          # forward https://<you>.<domain> -> http://localhost:8080
```

The first run installs `cloudflared` with Homebrew if it's missing. It then opens a browser for
`cloudflared tunnel login`, where you pick the domain's zone. After that it creates your tunnel
(`themis-<you>`) and its DNS record. Later runs start in a couple of seconds. The hostname stays
the same, so you configure the provider's webhook URL once.

Press Ctrl-C to stop. While the tunnel is down, the URL returns a Cloudflare error (530).

## Colleagues without Cloudflare access

Someone with access provisions a tunnel for them:

```bash
tunnel/tunnel.sh provision priya  # creates themis-priya + priya.<domain>, prints two lines
```

The colleague pastes those two lines (`TUNNEL_SUBDOMAIN`, `TUNNEL_TOKEN`) into `tunnel/.env`
and runs `tunnel/tunnel.sh up 8080`. They need no login. **The token lets anyone run that
tunnel.** Share it in a DM, never in a public channel, commit or notification.

## Settings: `tunnel/.env` (gitignored, optional)

```bash
TUNNEL_SUBDOMAIN=vikas           # hostname label; one level only (a.b.<domain> fails TLS)
TUNNEL_PORT=8080                 # default port for `up`
TUNNEL_DOMAIN=example.com        # override the zone read from mock-server/wrangler.toml
TUNNEL_TOKEN=...                 # from `provision`; skips login entirely
TUNNEL_VERBOSE=1                 # log each request's method, URL and headers
TUNNEL_ORIGIN_CERT=~/.cloudflared/other.pem   # if your default login is for another zone
```

Variables set in your shell override the file.

## Commands

| Command | What it does |
|---|---|
| `up [port]` | Runs your tunnel, and sets it up the first time. |
| `status [sub]` | Shows the hostname, tunnel name, and whether you're logged in. |
| `provision <sub>` | (Needs Cloudflare access.) Creates a tunnel for someone else and prints its token. |
| `delete [sub]` | Deletes a tunnel. Remove its DNS record in the dashboard afterwards. |

## Things to know

- **Your port is public while the tunnel runs.** Anyone who knows the URL can call your local
  server. Stop the tunnel when you're done, and point only test/staging integrations at it.
- **Verbose logs contain secrets.** `TUNNEL_VERBOSE=1` logs request headers, including auth
  headers and signatures. Don't paste those logs anywhere.
- **The script never overwrites DNS.** If `<sub>.<domain>` already has a record (for example
  another service, or the mock-server itself on the apex), `up` stops and asks you to pick another
  `TUNNEL_SUBDOMAIN`.
- **A login for another zone creates the record in the wrong place.** `cloudflared` keeps one
  login certificate at `~/.cloudflared/cert.pem`. If it belongs to another domain, the record is
  created as `<sub>.<domain>.<other-domain>` and the script stops. Log in again with
  `TUNNEL_ORIGIN_CERT` pointing at a new file.
- **One tunnel serves one port at a time.** Restart `up` with another port to switch. Don't run two
  `up` processes for the same tunnel: Cloudflare load-balances between them.
