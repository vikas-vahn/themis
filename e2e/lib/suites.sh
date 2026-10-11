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
  for flow in $E2E_API_FLOWS; do
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

MAESTRO_WEB_IMAGE="themis-e2e-maestro-web:2.11.0"

# Maestro downloads its own Chromium through Selenium Manager, which has no
# build for arm64 Linux. There (or with E2E_MAESTRO_WEB_DOCKER=1) the web suite
# runs Maestro from a small image that carries Debian's Chromium instead.
maestro_web_in_docker() {
  case "${E2E_MAESTRO_WEB_DOCKER:-auto}" in
    1) return 0 ;;
    0) return 1 ;;
    *) [ "$(uname -s)-$(uname -m)" = "Linux-aarch64" ] ;;
  esac
}

maestro_web_image() {
  docker image inspect "$MAESTRO_WEB_IMAGE" >/dev/null 2>&1 && return 0
  log "building $MAESTRO_WEB_IMAGE (once per machine)"
  docker build -q -f "$E2E_DIR/ci/maestro-web.Dockerfile" -t "$MAESTRO_WEB_IMAGE" "$E2E_DIR/ci" >/dev/null ||
    die "could not build the Maestro web image"
}

# run_maestro <platform-args...> -- <out-dir> <flows> [-e K=V ...]
# Runs a flow file, or every flow in a directory, and keeps JUnit, screenshots
# and the UI hierarchy of each failed step. <flows> must be inside maestro/.
run_maestro() {
  local platform=()
  while [ "$1" != "--" ]; do platform+=("$1"); shift; done
  shift
  local out="$1" flows="$2"
  shift 2
  mkdir -p "$out"

  if [ "${MAESTRO_IN_DOCKER:-0}" = "1" ]; then
    # Host networking, so "localhost" in the browser is this machine: the app
    # under test insists on that hostname. Runs as the calling user because
    # Chromium will not start as root and the results land in a host directory.
    docker run --rm --network host --security-opt seccomp=unconfined --shm-size=1g \
      -u "$(id -u):$(id -g)" \
      -v "$THEMIS_DIR/maestro:/maestro:ro" -v "$out:/out" -w /out \
      "$MAESTRO_WEB_IMAGE" \
      maestro test ${platform[@]+"${platform[@]}"} \
        --format junit --output /out/junit.xml \
        --debug-output /out/debug --flatten-debug-output \
        "$@" "/maestro/${flows#"$THEMIS_DIR/maestro/"}"
    return $?
  fi

  # Maestro writes takeScreenshot output relative to the working directory.
  # (${arr[@]+...} keeps bash 3.2, the macOS default, happy with an empty array.)
  (
    cd "$out" &&
      maestro test ${platform[@]+"${platform[@]}"} \
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
  local MAESTRO_IN_DOCKER=0
  if maestro_web_in_docker; then
    MAESTRO_IN_DOCKER=1
    maestro_web_image
  else
    ensure_maestro || return $?
  fi
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
  # Started without npx so the PID is the server itself and stopping it works.
  (cd "$PERSEUS_DIR" && exec node node_modules/vite/bin/vite.js preview --outDir "$dist" --port "$E2E_WEB_PORT" --strictPort --host "${E2E_WEB_BIND:-localhost}") \
    > "$out/preview.log" 2>&1 &
  WEB_SERVER_PID=$!
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

# --- mobile (atlas-rn on an Android emulator) --------------------------------

EMULATOR_PID=""

android_env() {
  : "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
  if [ -z "$ANDROID_HOME" ]; then
    local c
    for c in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" /opt/homebrew/share/android-commandlinetools /usr/local/lib/android/sdk; do
      [ -d "$c/platform-tools" ] && ANDROID_HOME="$c" && break
    done
  fi
  [ -n "$ANDROID_HOME" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ] || return 1
  export ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME"
  PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
}

# An emulator needs hardware virtualisation. Without it (for example an arm64
# cloud VM with no nested KVM) it is too slow to be usable, so say so up front.
emulator_can_run() {
  case "$(uname -s)" in
    Darwin) return 0 ;;
    Linux) [ -r /dev/kvm ] && [ -w /dev/kvm ] ;;
    *) return 1 ;;
  esac
}

emulator_stop() {
  if [ -n "$EMULATOR_PID" ]; then
    adb emu kill >/dev/null 2>&1 || true
    wait "$EMULATOR_PID" 2>/dev/null || true
    EMULATOR_PID=""
  fi
}

# Uses a device that is already attached (a CI step may have booted one);
# otherwise boots the AVD named by E2E_AVD and stops it afterwards.
emulator_ensure() {
  local out="$1"
  if adb devices | awk 'NR > 1 && $2 == "device"' | grep -q .; then
    log "using the Android device that is already attached"
  else
    emulator_can_run || { warn "no usable virtualisation here (/dev/kvm missing): an Android emulator cannot run on this machine"; return 77; }
    local avd="${E2E_AVD:-themis_e2e}"
    emulator -list-avds 2>/dev/null | grep -qx "$avd" ||
      { warn "Android virtual device '$avd' does not exist (see e2e/README.md, 'Mobile runner')"; return 77; }
    log "booting emulator '$avd'"
    # shellcheck disable=SC2086
    emulator -avd "$avd" -no-audio -no-boot-anim -no-snapshot -wipe-data \
      ${E2E_EMULATOR_ARGS:--no-window -gpu swiftshader_indirect} > "$out/emulator.log" 2>&1 &
    EMULATOR_PID=$!
  fi
  adb wait-for-device
  wait_for "Android boot" 300 sh -c '[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")" = "1" ]' ||
    { warn "the emulator did not finish booting; see $out/emulator.log"; return 1; }
  # Animations make text assertions race the UI.
  local k
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb shell settings put global "$k" 0 >/dev/null 2>&1 || true
  done
}

mobile_build_apk() {
  local out="$1" apk="$2"
  if [ "${E2E_SKIP_BUILD:-0}" = "1" ] && [ -f "${E2E_ATLAS_APK:-}" ]; then
    log "reusing $E2E_ATLAS_APK (E2E_SKIP_BUILD=1)"
    cp "$E2E_ATLAS_APK" "$apk"
    return 0
  fi
  [ -x "$ATLAS_DIR/e2e/build-android.sh" ] ||
    die "atlas-rn at $ATLAS_DIR has no e2e/build-android.sh. Check out a branch that contains it."
  group "build atlas-rn (a first build takes 30-50 minutes)"
  # 10.0.2.2 is the emulator's address for the host's loopback interface.
  E2E_API_BASE_URL="http://10.0.2.2:${E2E_API_PORT}/api" "$ATLAS_DIR/e2e/build-android.sh" "$apk" > "$out/build.log" 2>&1 ||
    { tail -n 40 "$out/build.log" >&2; die "atlas-rn build failed; see $out/build.log"; }
  endgroup
}

suite_mobile() {
  ensure_maestro || return $?
  ensure_node_tools
  require_dir ATLAS_DIR "$ATLAS_DIR"
  android_env || { warn "Android SDK not found; set ANDROID_HOME"; return 77; }
  local out="$E2E_RUN_DIR/mobile" apk="$E2E_RUN_DIR/mobile/atlas-e2e.apk" rc=0
  rm -rf "$out"
  mkdir -p "$out"

  # Fail fast on a machine that cannot run the emulator, before a long build.
  if ! adb devices | awk 'NR > 1 && $2 == "device"' | grep -q . && ! emulator_can_run; then
    warn "no Android device attached and no usable virtualisation: the mobile suite cannot run here"
    return 77
  fi

  mobile_build_apk "$out" "$apk"

  emulator_ensure "$out" || return $?
  adb uninstall in.vahn.fleet >/dev/null 2>&1 || true
  adb install -r "$apk" > "$out/install.log" 2>&1 || { cat "$out/install.log" >&2; die "could not install the APK"; }

  local phone identity name pan truck flows="$THEMIS_DIR/maestro/tests/fleet-app"
  phone="7$(printf '%09d' "$(( (RANDOM * 32768 + RANDOM) % 1000000000 ))")"
  identity="${E2E_MOBILE_IDENTITY:-1}"
  name="$(node -e 'console.log("Mobile Fleet " + ["One","Two","Three","Four","Five"][process.argv[1]-1])' "$identity")"
  pan="EEECM$(printf '%04d' "$identity")M"
  truck="KA51MA$(printf '%04d' "$identity")"
  # The DigiLocker stand-in hands back an Aadhaar in this name.
  curl -sf -X POST "$E2E_MOCKS_URL/_control/digilocker" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\"}" >/dev/null || die "could not configure the DigiLocker stand-in"

  local env=(-e "PHONE=$phone" -e "OTP=$E2E_OTP" -e "FLEET_NAME=$name" -e "PAN=$pan"
    -e "TRUCK_REG=$truck" -e "DRIVER_PHONE=83${phone: -8}")

  # The flows are one journey for one user, so they run in order and stop at
  # the first failure: later steps would only fail for the same reason.
  local flow file
  for file in "$flows"/*.yaml; do
    [ -f "$file" ] || continue
    flow="$(basename "$file" .yaml)"
    if [ "$flow" = "03-create-trip" ]; then
      # Trip creation needs a customer with saved addresses; adding one in the
      # app goes through a Google map, which a hermetic run cannot use.
      local customer
      customer="$(E2E_API_URL="$E2E_API_URL" node "$E2E_DIR/lib/seed.mjs" customer --phone "$phone" --name "Mobile Customer One")" ||
        { warn "could not seed the customer for the trip flow"; rc=1; break; }
      env+=(-e "CUSTOMER_NAME=$(node -pe 'JSON.parse(process.argv[1]).customerName' "$customer")"
        -e "PICKUP=$(node -pe 'JSON.parse(process.argv[1]).pickupNickName' "$customer")"
        -e "DROP=$(node -pe 'JSON.parse(process.argv[1]).dropNickName' "$customer")")
    fi
    log "maestro: $flow"
    if ! run_maestro -- "$out/$flow" "$flows/$flow.yaml" "${env[@]}" > "$out/$flow.log" 2>&1; then
      tail -n 25 "$out/$flow.log" >&2
      rc=1
      break
    fi
    ok "$flow"
  done

  adb logcat -d -t 3000 > "$out/logcat.txt" 2>/dev/null || true
  emulator_stop
  return "$rc"
}

# Stops whatever a suite left running. Called from run.sh's EXIT trap, so it
# also runs when a suite dies half-way or the run is interrupted.
suites_cleanup() {
  web_stop_server
  emulator_stop
}

doctor() {
  local stack_ok=1 api_ok=1 web_ok=1 mobile_ok=1
  check() { # check <ok|bad|note> <text>
    case "$1" in
      ok) printf '  %sok%s    %s\n' "$_c_grn" "$_c_off" "$2" ;;
      bad) printf '  %sMISSING%s %s\n' "$_c_red" "$_c_off" "$2" ;;
      *) printf '  %snote%s  %s\n' "$_c_ylw" "$_c_off" "$2" ;;
    esac
  }

  log "machine: $(uname -s) $(uname -m)"

  log "stack (needed by every suite)"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    check ok "docker daemon reachable"
    docker compose version >/dev/null 2>&1 && check ok "docker compose" || { check bad "docker compose plugin"; stack_ok=0; }
  else
    check bad "docker daemon (install Docker; on macOS: colima start)"; stack_ok=0
  fi
  if [ -f "$PLUTUS_DIR/e2e/config-overrides.yml" ]; then check ok "plutus-java with e2e/ at $PLUTUS_DIR"
  else check bad "plutus-java with an e2e/ directory at $PLUTUS_DIR (PLUTUS_DIR)"; stack_ok=0; fi
  if [ -f "${E2E_PLUTUS_JAR:-$PLUTUS_DIR/target/plutus-1.0-SNAPSHOT.jar}" ]; then check ok "backend JAR already built"
  elif command -v mvn >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then check ok "mvn + java to build the backend ($(java -version 2>&1 | head -n 1))"
  else check bad "mvn and a JDK 21 (or a prebuilt JAR via E2E_PLUTUS_JAR)"; stack_ok=0; fi
  local p
  for p in "$E2E_API_PORT" "$E2E_ADMIN_PORT" "$E2E_MOCKS_PORT"; do
    port_free "$p" || check note "port $p is in use (fine if an E2E stack is currently up)"
  done

  log "api suite"
  command -v node >/dev/null 2>&1 && check ok "node $(node --version)" || { check bad "node 22+"; api_ok=0; }

  log "web suite"
  command -v node >/dev/null 2>&1 || web_ok=0
  if ensure_maestro 2>/dev/null; then check ok "maestro $(maestro --version 2>/dev/null | tail -n 1)"; else check bad "maestro + java 17+"; web_ok=0; mobile_ok=0; fi
  if grep -q "VITE_API_BASE_URL" "$PERSEUS_DIR/src/config/index.ts" 2>/dev/null; then check ok "perseus with VITE_API_BASE_URL at $PERSEUS_DIR"
  else check bad "perseus supporting VITE_API_BASE_URL at $PERSEUS_DIR (PERSEUS_DIR)"; web_ok=0; fi
  if maestro_web_in_docker; then
    web_ok=1
    check note "Maestro will run from the $MAESTRO_WEB_IMAGE container (arm64 Linux has no managed Chromium)"
  fi

  log "mobile suite"
  if [ -x "$ATLAS_DIR/e2e/build-android.sh" ]; then check ok "atlas-rn with e2e/ at $ATLAS_DIR"
  else check bad "atlas-rn with e2e/build-android.sh at $ATLAS_DIR (ATLAS_DIR)"; mobile_ok=0; fi
  if android_env; then
    check ok "Android SDK at $ANDROID_HOME"
    if adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device"' | grep -q .; then check ok "an Android device is attached"
    elif ! emulator_can_run; then check bad "hardware virtualisation (/dev/kvm): an emulator cannot run on this machine"; mobile_ok=0
    elif emulator -list-avds 2>/dev/null | grep -qx "${E2E_AVD:-themis_e2e}"; then check ok "emulator image '${E2E_AVD:-themis_e2e}'"
    else check bad "emulator image '${E2E_AVD:-themis_e2e}' (see e2e/README.md, 'Mobile runner')"; mobile_ok=0; fi
  else
    check bad "Android SDK (ANDROID_HOME)"; mobile_ok=0
  fi

  echo
  log "can run here:"
  verdict() { if [ "$stack_ok" = 1 ] && [ "$2" = 1 ]; then check ok "$1"; else check bad "$1"; fi; }
  verdict api "$api_ok"
  verdict web "$web_ok"
  verdict mobile "$mobile_ok"
  [ "$stack_ok" = 1 ]
}
