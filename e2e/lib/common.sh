# Shared settings and helpers. Sourced by e2e/run.sh; not executable on its own.
# shellcheck shell=bash

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEMIS_DIR="$(cd "$E2E_DIR/.." && pwd)"

# Per-machine settings (repo locations, ports). Never committed.
if [ -f "$E2E_DIR/local.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$E2E_DIR/local.env"
  set +a
fi

# Where the repos under test are checked out. Defaults assume the four repos
# sit side by side, which is how the GitHub workflow lays them out.
: "${PLUTUS_DIR:=$THEMIS_DIR/../plutus-java}"
: "${ATLAS_DIR:=$THEMIS_DIR/../atlas-rn}"
: "${PERSEUS_DIR:=$THEMIS_DIR/../perseus}"

# Compose project name. Give concurrent runs on one host different names and
# ports (the workflow derives both from the runner name).
: "${E2E_PROJECT:=themis-e2e}"
: "${E2E_API_PORT:=18080}"
: "${E2E_ADMIN_PORT:=18081}"
: "${E2E_MOCKS_PORT:=14010}"
: "${E2E_WEB_PORT:=15173}"
# Address the published ports bind to. The Android emulator reaches the host's
# loopback through 10.0.2.2, so 127.0.0.1 is enough for every suite.
: "${E2E_BIND:=127.0.0.1}"

: "${E2E_RUN_DIR:=$E2E_DIR/.run}"
: "${E2E_KEEP_STACK:=0}"

E2E_API_URL="http://localhost:${E2E_API_PORT}"
E2E_ADMIN_URL="http://localhost:${E2E_ADMIN_PORT}"
E2E_MOCKS_URL="http://localhost:${E2E_MOCKS_PORT}"
E2E_WEB_URL="http://localhost:${E2E_WEB_PORT}"

# Fixed test values. The OTP is the static OTP set in plutus-java
# e2e/config-overrides.yml; the admin is seeded by e2e/seed.sql.
E2E_OTP="667766"
E2E_ADMIN_PHONE="9000000001"

export E2E_PROJECT E2E_API_PORT E2E_ADMIN_PORT E2E_MOCKS_PORT E2E_WEB_PORT E2E_BIND E2E_RUN_DIR

if [ -t 1 ] && [ -z "${CI:-}" ]; then
  _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
  _c_red=""; _c_grn=""; _c_ylw=""; _c_dim=""; _c_off=""
fi

log()  { printf '%s[e2e]%s %s\n' "$_c_dim" "$_c_off" "$*"; }
ok()   { printf '%s[e2e] ok%s  %s\n' "$_c_grn" "$_c_off" "$*"; }
warn() { printf '%s[e2e] warn%s %s\n' "$_c_ylw" "$_c_off" "$*" >&2; }
die()  { printf '%s[e2e] FAIL%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# GitHub Actions log folding; a plain heading elsewhere.
group()    { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$*"; else log "== $*"; fi; }
endgroup() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed. ${2:-}"
}

require_dir() {
  [ -d "$2" ] || die "$1 not found at $2. Set $1 in e2e/local.env (see e2e/local.env.example)."
}

# wait_for <description> <timeout-seconds> <command...>
wait_for() {
  local what="$1" timeout="$2" start=$SECONDS
  shift 2
  until "$@" >/dev/null 2>&1; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      return 1
    fi
    sleep 2
  done
  log "$what ready after $((SECONDS - start))s"
}

port_free() {
  ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# record_result <suite> <pass|fail|skip> [note]   -> $E2E_RUN_DIR/results.tsv
record_result() {
  mkdir -p "$E2E_RUN_DIR"
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$E2E_RUN_DIR/results.tsv"
}
