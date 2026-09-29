#!/usr/bin/env bash
# Receive webhooks on https://hook.<domain> on your laptop, through a
# Cloudflare Tunnel on our own domain. See tunnel/README.md.
#
#   tunnel/tunnel.sh listen             print every request sent to https://hook.<domain>
#   tunnel/tunnel.sh up [port]          forward https://hook.<domain> to your app on localhost:<port>
#   tunnel/tunnel.sh status             show the hostname and who is connected
#   tunnel/tunnel.sh token              (Cloudflare access) print the TUNNEL_TOKEN line for tunnel/.env
#   tunnel/tunnel.sh delete             delete the tunnel (the DNS record must be removed by hand)
#
# TUNNEL_SUBDOMAIN=<name> switches any command to https://<name>.<domain>.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-developer settings (gitignored). Environment variables win over the file.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="$(echo "$key" | tr -d '[:space:]')"
    if [[ -z "$key" || "$key" == \#* ]]; then continue; fi
    # Drop an inline "  # comment", surrounding spaces and quotes; expand a leading ~.
    value="$(echo "$value" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"
    value="${value/#\~/$HOME}"
    if [[ -z "${!key:-}" ]]; then export "$key=$value"; fi
  done < "$SCRIPT_DIR/.env"
fi

die() { echo "tunnel: $*" >&2; exit 1; }
info() { echo "tunnel: $*" >&2; }

# The zone defaults to the mock-server's hostname, so the domain lives in one place.
domain() {
  if [[ -n "${TUNNEL_DOMAIN:-}" ]]; then
    echo "$TUNNEL_DOMAIN"
    return
  fi
  local d
  d="$(sed -nE 's/.*pattern *= *"([^"/]+).*/\1/p' "$REPO_ROOT/mock-server/wrangler.toml" | head -1)"
  [[ -n "$d" ]] || die "set TUNNEL_DOMAIN in tunnel/.env (could not read it from mock-server/wrangler.toml)"
  echo "$d"
}

# A single DNS label: Cloudflare's free certificate covers *.<domain> only, so
# a.b.<domain> would fail TLS.
sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-' | sed -E 's/^-+//; s/-+$//'
}

subdomain() {
  local s="${1:-${TUNNEL_SUBDOMAIN:-hook}}"
  # Accept "hook", "hook.<domain>" or "https://hook.<domain>/".
  s="${s#*://}"
  s="${s%%/*}"
  s="${s%".$(domain)"}"
  [[ "$s" == *.* ]] && die "TUNNEL_SUBDOMAIN must be one label under $(domain), like 'hook' (got '$s')"
  s="$(sanitize "$s")"
  [[ -n "$s" ]] || die "empty subdomain"
  echo "$s"
}

tunnel_name() { echo "themis-$1"; }
hostname_for() { echo "$1.$(domain)"; }

need_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 && return
  if command -v brew >/dev/null 2>&1; then
    info "installing cloudflared with Homebrew"
    brew install cloudflared
  else
    die "install cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
  fi
}

origin_cert() { echo "${TUNNEL_ORIGIN_CERT:-$HOME/.cloudflared/cert.pem}"; }

need_login() {
  local cert
  cert="$(origin_cert)"
  [[ -f "$cert" ]] && return
  info "no Cloudflare login found at $cert"
  info "a browser will open: sign in and pick the zone '$(domain)'"
  cloudflared tunnel login >&2
  [[ -f "$cert" ]] || die "login did not produce $cert"
}

tunnel_exists() {
  cloudflared tunnel list --name "$1" --output json 2>/dev/null | grep -q '"id"'
}

# Create the tunnel and its DNS record if they don't exist yet. Idempotent.
ensure_tunnel() {
  local sub="$1" name host out
  name="$(tunnel_name "$sub")"
  host="$(hostname_for "$sub")"
  need_login
  if tunnel_exists "$name"; then
    info "tunnel $name exists"
  else
    info "creating tunnel $name"
    cloudflared tunnel create "$name" >&2
  fi
  # Never pass --overwrite-dns: an existing record on this hostname belongs to
  # someone else, and clobbering it could take a real service down.
  info "routing $host -> $name"
  if ! out="$(cloudflared tunnel route dns "$name" "$host" 2>&1)"; then
    echo "$out" >&2
    die "could not route $host. If a DNS record with that name already exists and isn't this tunnel's, remove it in the Cloudflare dashboard or pick another TUNNEL_SUBDOMAIN"
  fi
  echo "$out" >&2
  if echo "$out" | grep -q "$host\.[a-z]"; then
    die "the record was created in a different zone than $(domain): your login cert is for another domain. Run 'cloudflared tunnel login' with TUNNEL_ORIGIN_CERT pointing at a new file"
  fi
}

# The token lets cloudflared run the tunnel without a login or the credentials
# file, which only exists on the laptop that created the tunnel.
run_token() {
  local sub="$1"
  if [[ -n "${TUNNEL_TOKEN:-}" ]]; then
    # A tunnel token is base64 JSON with the tunnel id ("t"). Catch the usual
    # mix-up: a Cloudflare API token (cfut_...) doesn't work here.
    if ! echo "$TUNNEL_TOKEN" | base64 -d 2>/dev/null | grep -q '"t"'; then
      die "TUNNEL_TOKEN in tunnel/.env is not a tunnel token (a Cloudflare API token looks like cfut_...). Get one with 'tunnel/tunnel.sh token', or remove the line to log in with the browser instead"
    fi
    echo "$TUNNEL_TOKEN"
    return
  fi
  ensure_tunnel "$sub"
  cloudflared tunnel token "$(tunnel_name "$sub")"
}

# Only one person should be connected at a time: Cloudflare spreads requests
# across every connected laptop, so each would see only some of them.
check_nobody_listening() {
  local host="$1" who
  [[ "${TUNNEL_FORCE:-}" == "1" ]] && return
  who="$(curl -s --max-time 5 "https://$host/__themis_receiver" 2>/dev/null || true)"
  if echo "$who" | grep -q '"receiver":true'; then
    die "someone is already listening on https://$host ($who). Requests would be split between you. Ask them to stop, use TUNNEL_SUBDOMAIN=<yours> for your own URL, or set TUNNEL_FORCE=1"
  fi
  # `up` forwards to an app, which can't answer the probe; a connected tunnel
  # still answers with something other than Cloudflare's 530/1033 "no tunnel".
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$host/" 2>/dev/null || true)"
  if [[ -n "$code" && "$code" != "000" && "$code" != "530" ]]; then
    die "https://$host is already connected to someone's laptop (HTTP $code). Ask around, use TUNNEL_SUBDOMAIN=<yours>, or set TUNNEL_FORCE=1"
  fi
}

port_arg() {
  local port="${1:-${TUNNEL_PORT:-8080}}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "port must be a number, got '$port'"
  echo "$port"
}

warn_if_nothing_listening() {
  if ! nc -z localhost "$1" >/dev/null 2>&1; then
    info "warning: nothing is listening on localhost:$1 yet; requests will get a 502 until it is"
  fi
}

log_level() { [[ "${TUNNEL_VERBOSE:-}" == "1" ]] && echo debug || echo info; }

cmd_up() {
  local port sub host
  port="$(port_arg "${1:-}")"
  need_cloudflared
  warn_if_nothing_listening "$port"
  sub="$(subdomain)"
  host="$(hostname_for "$sub")"
  TUNNEL_TOKEN="$(run_token "$sub")"
  export TUNNEL_TOKEN # read by cloudflared; keeps the token out of `ps`
  check_nobody_listening "$host"
  info "https://$host -> http://localhost:$port (Ctrl-C to stop)"
  exec cloudflared tunnel --no-autoupdate --loglevel "$(log_level)" run --url "http://localhost:$port"
}

cmd_listen() {
  local sub host port log receiver_pid tunnel_pid
  need_cloudflared
  command -v node >/dev/null 2>&1 || die "node is required (brew install node)"
  sub="$(subdomain)"
  host="$(hostname_for "$sub")"
  port="${TUNNEL_RECEIVER_PORT:-9876}"
  if nc -z localhost "$port" >/dev/null 2>&1; then
    die "localhost:$port is in use; set TUNNEL_RECEIVER_PORT to a free port"
  fi
  TUNNEL_TOKEN="$(run_token "$sub")"
  export TUNNEL_TOKEN
  check_nobody_listening "$host"

  log="$(mktemp -t themis-tunnel)"
  TUNNEL_PUBLIC_URL="https://$host" node "$SCRIPT_DIR/receiver.mjs" "$port" &
  receiver_pid=$!
  cloudflared tunnel --no-autoupdate --loglevel "$(log_level)" run --url "http://localhost:$port" >"$log" 2>&1 &
  tunnel_pid=$!
  trap 'kill "$receiver_pid" "$tunnel_pid" 2>/dev/null; rm -f "$log"' EXIT
  trap 'exit 0' INT TERM

  info "connecting to Cloudflare..."
  for _ in $(seq 1 30); do
    grep -q "Registered tunnel connection" "$log" && break
    kill -0 "$tunnel_pid" 2>/dev/null || { cat "$log" >&2; die "cloudflared exited"; }
    sleep 1
  done
  grep -q "Registered tunnel connection" "$log" || { tail -20 "$log" >&2; die "tunnel did not connect within 30s"; }
  info "listening on https://$host — every request is printed below (Ctrl-C to stop)"
  [[ "${TUNNEL_VERBOSE:-}" == "1" ]] && info "cloudflared log: $log"

  # Stop when either process dies.
  while kill -0 "$receiver_pid" 2>/dev/null && kill -0 "$tunnel_pid" 2>/dev/null; do
    sleep 1
  done
  kill -0 "$tunnel_pid" 2>/dev/null || { tail -20 "$log" >&2; die "cloudflared exited"; }
  die "receiver exited"
}

cmd_status() {
  local sub
  sub="$(subdomain)"
  echo "domain:    $(domain)"
  echo "hostname:  https://$(hostname_for "$sub")"
  echo "tunnel:    $(tunnel_name "$sub")"
  if [[ -n "${TUNNEL_TOKEN:-}" ]]; then
    echo "auth:      TUNNEL_TOKEN in tunnel/.env"
  elif [[ -f "$(origin_cert)" ]]; then
    echo "auth:      Cloudflare login ($(origin_cert))"
  else
    echo "auth:      none yet (put TUNNEL_TOKEN in tunnel/.env, or run listen to log in)"
  fi
  local who
  who="$(curl -s --max-time 5 "https://$(hostname_for "$sub")/__themis_receiver" 2>/dev/null || true)"
  if echo "$who" | grep -q '"receiver":true'; then
    echo "listening: $who"
  else
    echo "listening: nobody (or someone is running 'up' to an app)"
  fi
}

cmd_token() {
  local sub
  sub="$(subdomain)"
  need_cloudflared
  ensure_tunnel "$sub"
  info "share privately (a DM or password manager, never a public channel); it goes in tunnel/.env:"
  [[ "$sub" != "hook" ]] && echo "TUNNEL_SUBDOMAIN=$sub"
  echo "TUNNEL_TOKEN=$(cloudflared tunnel token "$(tunnel_name "$sub")")"
}

cmd_delete() {
  local sub name
  sub="$(subdomain)"
  name="$(tunnel_name "$sub")"
  need_cloudflared
  need_login
  tunnel_exists "$name" || die "no tunnel named $name"
  read -r -p "Delete tunnel $name? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "aborted"
  cloudflared tunnel delete "$name"
  info "deleted. Remove the CNAME for $(hostname_for "$sub") in the Cloudflare dashboard (DNS) by hand; cloudflared can't"
}

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  listen) shift; cmd_listen "$@" ;;
  up)     shift; cmd_up "$@" ;;
  status) shift; cmd_status "$@" ;;
  token)  shift; cmd_token "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  -h|--help|help|"") usage ;;
  *) usage; exit 1 ;;
esac
