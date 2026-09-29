#!/usr/bin/env bash
# Expose a local port on a stable https://<sub>.<domain> hostname through a
# Cloudflare Tunnel, so third-party webhooks can reach code running on your
# machine. See tunnel/README.md.
#
#   tunnel/tunnel.sh up [port]          run your tunnel (sets it up on first use)
#   tunnel/tunnel.sh quick [port]       throwaway *.trycloudflare.com URL, no login
#   tunnel/tunnel.sh status             show your tunnel and hostname
#   tunnel/tunnel.sh provision <sub>    (admin) create a tunnel for a colleague, print its token
#   tunnel/tunnel.sh delete [sub]       delete a tunnel (the DNS record must be removed by hand)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-developer settings (gitignored). Environment variables win over the file.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key="$(echo "$key" | tr -d '[:space:]')"
    if [[ -z "$key" || "$key" == \#* ]]; then continue; fi
    value="${value%\"}"; value="${value#\"}"
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
  local s
  s="$(sanitize "${1:-${TUNNEL_SUBDOMAIN:-$(whoami)}}")"
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
  cloudflared tunnel login
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
    die "could not route $host. If a DNS record with that name already exists and isn't yours, pick another TUNNEL_SUBDOMAIN"
  fi
  echo "$out" >&2
  if echo "$out" | grep -q "$host\.[a-z]"; then
    die "the record was created in a different zone than $(domain): your login cert is for another domain. Run 'cloudflared tunnel login' with TUNNEL_ORIGIN_CERT pointing at a new file"
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

  # Colleagues without Cloudflare access run with a token from `provision`.
  if [[ -n "${TUNNEL_TOKEN:-}" ]]; then
    if [[ -n "${TUNNEL_SUBDOMAIN:-}" ]]; then info "public URL: https://$(hostname_for "$(subdomain)")"; fi
    info "forwarding to http://localhost:$port (Ctrl-C to stop)"
    exec cloudflared tunnel --no-autoupdate --loglevel "$(log_level)" run --url "http://localhost:$port"
  fi

  sub="$(subdomain)"
  host="$(hostname_for "$sub")"
  ensure_tunnel "$sub"
  info "public URL: https://$host -> http://localhost:$port (Ctrl-C to stop)"
  exec cloudflared tunnel --no-autoupdate --loglevel "$(log_level)" run --url "http://localhost:$port" "$(tunnel_name "$sub")"
}

cmd_quick() {
  local port
  port="$(port_arg "${1:-}")"
  need_cloudflared
  warn_if_nothing_listening "$port"
  info "the random https://*.trycloudflare.com URL is printed below; it changes on every run"
  exec cloudflared tunnel --no-autoupdate --loglevel "$(log_level)" --url "http://localhost:$port"
}

cmd_status() {
  local sub
  sub="$(subdomain "${1:-}")"
  echo "domain:    $(domain)"
  echo "hostname:  https://$(hostname_for "$sub")"
  echo "tunnel:    $(tunnel_name "$sub")"
  echo "port:      $(port_arg "")"
  if [[ -n "${TUNNEL_TOKEN:-}" ]]; then
    echo "auth:      TUNNEL_TOKEN (from provision)"
    return
  fi
  need_cloudflared
  if [[ ! -f "$(origin_cert)" ]]; then
    echo "auth:      not logged in (run: tunnel/tunnel.sh up)"
    return
  fi
  echo "auth:      $(origin_cert)"
  cloudflared tunnel list --name "$(tunnel_name "$sub")"
}

cmd_provision() {
  [[ -n "${1:-}" ]] || die "usage: tunnel/tunnel.sh provision <subdomain>"
  local sub
  sub="$(subdomain "$1")"
  need_cloudflared
  ensure_tunnel "$sub"
  info "send these two lines privately (not in a public channel); they go in the colleague's tunnel/.env:"
  echo "TUNNEL_SUBDOMAIN=$sub"
  echo "TUNNEL_TOKEN=$(cloudflared tunnel token "$(tunnel_name "$sub")")"
}

cmd_delete() {
  local sub name
  sub="$(subdomain "${1:-}")"
  name="$(tunnel_name "$sub")"
  need_cloudflared
  need_login
  tunnel_exists "$name" || die "no tunnel named $name"
  read -r -p "Delete tunnel $name? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "aborted"
  cloudflared tunnel delete "$name"
  info "deleted. Remove the CNAME for $(hostname_for "$sub") in the Cloudflare dashboard (DNS) by hand; cloudflared can't"
}

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  up)        shift; cmd_up "$@" ;;
  quick)     shift; cmd_quick "$@" ;;
  status)    shift; cmd_status "$@" ;;
  provision) shift; cmd_provision "$@" ;;
  delete)    shift; cmd_delete "$@" ;;
  -h|--help|help|"") usage ;;
  *) usage; exit 1 ;;
esac
