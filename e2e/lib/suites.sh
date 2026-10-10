# The test suites and the machine check. Each suite_* returns 0 (pass),
# 77 (skipped: this machine cannot run it) or anything else (fail).
# shellcheck shell=bash

ensure_node_tools() {
  need node "Install Node 22 or newer."
  if [ ! -x "$E2E_DIR/node_modules/.bin/bru" ]; then
    log "installing pinned E2E tooling (Bruno CLI)"
    (cd "$E2E_DIR" && npm install --no-audit --no-fund --silent) || die "npm install failed in e2e/"
  fi
}

suite_api() {
  ensure_node_tools
  local out="$E2E_RUN_DIR/api" rc=0 flow
  mkdir -p "$out"
  # Each journey is a folder of numbered requests; run them one journey at a
  # time so a failure in one does not hide the others.
  for flow in fleet-onboarding; do
    log "bruno: $flow"
    (
      cd "$THEMIS_DIR/bruno/flows/plutus-api" &&
        "$E2E_DIR/node_modules/.bin/bru" run "$flow" \
          --env e2e \
          --env-var "baseUrl=$E2E_API_URL" \
          --env-var "e2eOtp=$E2E_OTP" \
          --env-var "e2eAdminPhone=$E2E_ADMIN_PHONE" \
          --reporter-junit "$out/$flow.junit.xml" \
          --reporter-html "$out/$flow.html"
    ) || rc=1
  done
  return "$rc"
}

suite_web()    { warn "web suite not wired yet"; return 77; }
suite_mobile() { warn "mobile suite not wired yet"; return 77; }

doctor() { warn "doctor not wired yet"; }
