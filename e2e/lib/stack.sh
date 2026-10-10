# The hermetic backend stack: build, configure, start, seed, stop.
# shellcheck shell=bash

compose() {
  docker compose -p "$E2E_PROJECT" -f "$E2E_DIR/stack/docker-compose.yml" "$@"
}

psql_stack() {
  compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U plutus -d plutus "$@"
}

stack_build_backend() {
  require_dir PLUTUS_DIR "$PLUTUS_DIR"
  [ -f "$PLUTUS_DIR/e2e/config-overrides.yml" ] ||
    die "plutus-java at $PLUTUS_DIR has no e2e/ directory. Check out a branch that contains it."

  E2E_PLUTUS_JAR="${E2E_PLUTUS_JAR:-$PLUTUS_DIR/target/plutus-1.0-SNAPSHOT.jar}"
  if [ "${E2E_SKIP_BUILD:-0}" = "1" ] && [ -f "$E2E_PLUTUS_JAR" ]; then
    log "reusing $E2E_PLUTUS_JAR (E2E_SKIP_BUILD=1)"
  else
    need mvn "Install Maven, or build the JAR elsewhere and set E2E_PLUTUS_JAR + E2E_SKIP_BUILD=1."
    group "build plutus-java"
    (cd "$PLUTUS_DIR" && mvn -q -B -DskipTests package) || die "plutus-java build failed"
    endgroup
  fi
  [ -f "$E2E_PLUTUS_JAR" ] || die "backend JAR not found at $E2E_PLUTUS_JAR"
  export E2E_PLUTUS_JAR
}

# Deep-merges plutus-java's e2e overrides over its config.yml. The result holds
# every value from config.yml, so it stays in the gitignored, owner-only run
# directory and is never printed.
stack_render_config() {
  local out="$E2E_RUN_DIR/plutus"
  mkdir -p "$out"
  chmod 700 "$E2E_RUN_DIR" "$out"
  (
    umask 077
    docker run --rm -v "$PLUTUS_DIR:/src:ro" mikefarah/yq:4 \
      eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
      /src/config.yml /src/e2e/config-overrides.yml > "$out/config.yml"
  ) || die "could not render the backend config"
  [ -s "$out/config.yml" ] || die "rendered backend config is empty"
  install -m 600 "$PLUTUS_DIR/e2e/verification-testing.yml" "$out/verification-testing.yml"
}

stack_dump_logs() {
  mkdir -p "$E2E_RUN_DIR/logs"
  local svc
  for svc in plutus mocks postgres redis sqs gateway; do
    compose logs --no-color --no-log-prefix "$svc" > "$E2E_RUN_DIR/logs/$svc.log" 2>&1 || true
  done
  curl -s "$E2E_MOCKS_URL/_unmatched" > "$E2E_RUN_DIR/logs/mocks-unmatched.json" 2>/dev/null || true
}

stack_up() {
  need docker "Docker (or Colima) must be installed and running."
  docker info >/dev/null 2>&1 || die "Docker daemon is not reachable. Start it (macOS: 'colima start')."

  # Docker on macOS (Colima) can only mount paths under the home directory.
  case "$(uname -s):$E2E_RUN_DIR" in
    Darwin:/Users/*) ;;
    Darwin:*) die "E2E_RUN_DIR ($E2E_RUN_DIR) must be under /Users on macOS so Docker can mount it." ;;
  esac

  if compose ps -q 2>/dev/null | grep -q .; then
    log "a previous '$E2E_PROJECT' stack is still up; removing it"
    compose down -v --remove-orphans >/dev/null 2>&1 || die "could not remove the previous '$E2E_PROJECT' stack"
  fi
  local p
  for p in "$E2E_API_PORT" "$E2E_ADMIN_PORT" "$E2E_MOCKS_PORT"; do
    port_free "$p" || die "port $p is already in use. Change it in e2e/local.env (E2E_API_PORT, E2E_ADMIN_PORT, E2E_MOCKS_PORT)."
  done

  rm -rf "$E2E_RUN_DIR"
  mkdir -p "$E2E_RUN_DIR"

  stack_build_backend
  stack_render_config

  group "start infrastructure"
  compose up -d --wait postgres redis sqs mocks || { stack_dump_logs; die "infrastructure did not start"; }
  psql_stack < "$PLUTUS_DIR/e2e/schema-pre.sql" || die "schema-pre.sql failed"
  endgroup

  group "start plutus-api"
  if ! compose up -d --wait plutus gateway; then
    stack_dump_logs
    tail -n 40 "$E2E_RUN_DIR/logs/plutus.log" >&2 || true
    die "plutus-api did not become healthy. Full log: $E2E_RUN_DIR/logs/plutus.log"
  fi
  wait_for "plutus-api via gateway" 60 curl -sf -o /dev/null "$E2E_ADMIN_URL/healthcheck" ||
    die "plutus-api is healthy in its container but not reachable on $E2E_ADMIN_URL"
  endgroup

  group "align schema and seed reference data"
  psql_stack < "$PLUTUS_DIR/e2e/schema-post.sql" || die "schema-post.sql failed"
  psql_stack < "$PLUTUS_DIR/e2e/seed.sql" || die "seed.sql failed"
  endgroup

  ok "stack up: API $E2E_API_URL  admin $E2E_ADMIN_URL  mocks $E2E_MOCKS_URL"
}

stack_down() {
  stack_dump_logs
  if ! compose down -v --remove-orphans > "$E2E_RUN_DIR/logs/compose-down.log" 2>&1; then
    warn "docker compose down failed; see $E2E_RUN_DIR/logs/compose-down.log"
    return 1
  fi
  # The rendered config carries values from plutus-java's config.yml.
  rm -rf "$E2E_RUN_DIR/plutus"
  ok "stack down"
}

# Fails the run if the backend tried to reach a third party the mocks do not
# cover: that is an outbound call nobody has looked at yet.
stack_check_unmatched() {
  local n
  n="$(curl -s "$E2E_MOCKS_URL/_unmatched" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch{console.log(-1)}})')"
  if [ "$n" = "0" ]; then
    ok "no unmatched third-party calls"
  elif [ "$n" = "-1" ]; then
    warn "could not read the mocks' unmatched-call list"
  else
    warn "$n third-party call(s) had no mock route; see $E2E_RUN_DIR/logs/mocks-unmatched.json"
    curl -s "$E2E_MOCKS_URL/_unmatched" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const c of JSON.parse(s))console.error("   "+c.method+" "+c.path)})' || true
    return 1
  fi
}
