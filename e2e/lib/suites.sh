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

ensure_maestro() {
  # Maestro installs to ~/.maestro/bin by default and needs Java 17+.
  [ -d "$HOME/.maestro/bin" ] && PATH="$HOME/.maestro/bin:$PATH"
  command -v maestro >/dev/null 2>&1 || { warn "maestro is not installed (https://docs.maestro.dev)"; return 77; }
  command -v java >/dev/null 2>&1 || { warn "java is not installed; Maestro needs Java 17 or newer"; return 77; }
}

# run_maestro <platform-args...> -- <out-dir> <flows-dir> [-e K=V ...]
# Runs every flow in the directory and keeps JUnit, screenshots and the UI
# hierarchy of each failed step.
run_maestro() {
  local platform=()
  while [ "$1" != "--" ]; do platform+=("$1"); shift; done
  shift
  local out="$1" flows="$2"
  shift 2
  mkdir -p "$out"
  # Maestro writes takeScreenshot output relative to the working directory.
  (
    cd "$out" &&
      maestro test "${platform[@]}" \
        --format junit --output "$out/junit.xml" \
        --debug-output "$out/debug" --flatten-debug-output \
        "$@" "$flows"
  )
}

WEB_SERVER_PID=""

web_stop_server() {
  if [ -n "$WEB_SERVER_PID" ]; then
    kill "$WEB_SERVER_PID" 2>/dev/null || true
    wait "$WEB_SERVER_PID" 2>/dev/null || true
    WEB_SERVER_PID=""
  fi
}

suite_web() {
  ensure_maestro || return $?
  ensure_node_tools
  require_dir PERSEUS_DIR "$PERSEUS_DIR"
  local out="$E2E_RUN_DIR/web" dist="$E2E_RUN_DIR/web/dist"
  rm -rf "$out"
  mkdir -p "$out"

  # perseus hardcodes its API host per environment; VITE_API_BASE_URL (added
  # for this purpose) points the build at the local stack instead.
  grep -q "VITE_API_BASE_URL" "$PERSEUS_DIR/src/config/index.ts" 2>/dev/null ||
    die "perseus at $PERSEUS_DIR does not support VITE_API_BASE_URL. Check out a branch that has it."
  group "build perseus"
  (
    cd "$PERSEUS_DIR" || exit 1
    if [ ! -d node_modules ] || [ "${E2E_SKIP_BUILD:-0}" != "1" ]; then
      npm ci --no-audit --no-fund --silent || exit 1
    fi
    VITE_NODE_ENV=development VITE_API_BASE_URL="$E2E_API_URL/api" \
      npx vite build --outDir "$dist" --emptyOutDir --logLevel warn
  ) > "$out/build.log" 2>&1 || { tail -n 30 "$out/build.log" >&2; die "perseus build failed; see $out/build.log"; }
  endgroup

  port_free "$E2E_WEB_PORT" || die "port $E2E_WEB_PORT is already in use (E2E_WEB_PORT in e2e/local.env)."
  # The app keys several behaviours off the hostname being exactly "localhost".
  (cd "$PERSEUS_DIR" && exec npx vite preview --outDir "$dist" --port "$E2E_WEB_PORT" --strictPort --host localhost) \
    > "$out/preview.log" 2>&1 &
  WEB_SERVER_PID=$!
  trap web_stop_server RETURN
  wait_for "perseus preview" 60 curl -sf -o /dev/null "$E2E_WEB_URL/" ||
    { tail -n 20 "$out/preview.log" >&2; die "perseus preview server did not start"; }

  # The web app has no sign-up or KYC, so its user is onboarded through the API.
  local user customer phone tail4
  user="$(E2E_API_URL="$E2E_API_URL" node "$E2E_DIR/lib/seed.mjs" onboard --suite W --index "${E2E_WEB_IDENTITY:-1}")" || die "could not seed the web user"
  phone="$(node -pe 'JSON.parse(process.argv[1]).phone' "$user")"
  customer="$(E2E_API_URL="$E2E_API_URL" node "$E2E_DIR/lib/seed.mjs" customer --phone "$phone" --name "Web Customer One")" ||
    die "could not seed the web user's customer"
  tail4="${phone: -7}"

  local rc=0
  # A tall viewport keeps whole forms on screen; below 1024px wide the app
  # shows "Mobile View Not Available" instead of the UI.
  run_maestro -p web --headless --screen-size 1440x1400 -- "$out" "$THEMIS_DIR/maestro/tests/fleet-web" \
    -e "WEB_URL=$E2E_WEB_URL" \
    -e "OTP=$E2E_OTP" \
    -e "PHONE=$phone" \
    -e "FLEET_NAME=$(node -pe 'JSON.parse(process.argv[1]).name' "$user")" \
    -e "NEW_PHONE=7$(printf '%09d' "$(( (RANDOM * 32768 + RANDOM) % 1000000000 ))")" \
    -e "TRUCK_REG=$(node -pe 'JSON.parse(process.argv[1]).trucks[0]' "$user")" \
    -e "DRIVER_PHONE=82${phone: -8}" \
    -e "DRIVER_LICENSE=KA012020$tail4" \
    -e "CUSTOMER_NAME=$(node -pe 'JSON.parse(process.argv[1]).customerName' "$customer")" \
    -e "PICKUP=$(node -pe 'JSON.parse(process.argv[1]).pickupNickName' "$customer")" \
    -e "DROP=$(node -pe 'JSON.parse(process.argv[1]).dropNickName' "$customer")" \
    > "$out/maestro.log" 2>&1 || rc=$?
  # Selenium prints a harmless CDP version warning for every flow.
  grep -vE 'CdpVersionFinder|Unable to find (CDP|version of CDP)|ChromiumDriver lambda' "$out/maestro.log" || true
  web_stop_server
  return "$rc"
}

suite_mobile() { warn "mobile suite not wired yet"; return 77; }

doctor() { warn "doctor not wired yet"; }
