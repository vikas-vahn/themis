#!/usr/bin/env bash
# Entry point for the end-to-end checks. The same commands run on a laptop and
# in GitHub Actions; see e2e/README.md.
#
#   e2e/run.sh doctor            check this machine can run each suite
#   e2e/run.sh up                build + start the hermetic backend stack
#   e2e/run.sh api               Bruno API flows          (needs: up)
#   e2e/run.sh web               Maestro flows, perseus   (needs: up)
#   e2e/run.sh mobile            Maestro flows, atlas-rn  (needs: up)
#   e2e/run.sh down              stop the stack, collect logs
#   e2e/run.sh all [suites...]   up, the given suites (default: api web mobile), down
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/stack.sh
. "$E2E_DIR/lib/stack.sh"
# shellcheck source=lib/suites.sh
. "$E2E_DIR/lib/suites.sh"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

run_suite() {
  local suite="$1" rc=0
  group "suite: $suite"
  "suite_$suite" || rc=$?
  endgroup
  case "$rc" in
    0)  record_result "$suite" pass; ok "$suite passed" ;;
    77) record_result "$suite" skip "prerequisites missing"; warn "$suite skipped" ;;
    *)  record_result "$suite" fail "exit $rc"; warn "$suite FAILED (exit $rc)" ;;
  esac
  return "$rc"
}

summary() {
  [ -f "$E2E_RUN_DIR/results.tsv" ] || return 0
  echo
  log "results"
  awk -F'\t' '{ printf "   %-8s %-5s %s\n", $1, $2, $3 }' "$E2E_RUN_DIR/results.tsv"
  log "reports and logs: $E2E_RUN_DIR"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### E2E results"
      echo "| Suite | Result | Note |"
      echo "| --- | --- | --- |"
      awk -F'\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }' "$E2E_RUN_DIR/results.tsv"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

trap suites_cleanup EXIT

case "$cmd" in
  doctor) doctor ;;
  up)     stack_up ;;
  down)   stack_down ;;
  api|web|mobile)
    run_suite "$cmd"; rc=$?
    summary
    [ "$rc" -eq 77 ] && [ "${E2E_SKIP_IS_FAILURE:-0}" != "1" ] && rc=0
    exit "$rc"
    ;;
  all)
    suites=("$@")
    [ ${#suites[@]} -eq 0 ] && suites=(api web mobile)
    failed=0
    # Always tear down, including on Ctrl-C or a failed start, unless asked to
    # keep the stack for debugging.
    cleanup() {
      suites_cleanup
      if [ "$E2E_KEEP_STACK" = "1" ]; then
        warn "stack left running (E2E_KEEP_STACK=1); stop it with: e2e/run.sh down"
      else
        stack_down
      fi
    }
    trap cleanup EXIT
    stack_up || exit 1
    for s in "${suites[@]}"; do
      run_suite "$s"; rc=$?
      if [ "$rc" -eq 77 ]; then
        [ "${E2E_SKIP_IS_FAILURE:-0}" = "1" ] && failed=1
      elif [ "$rc" -ne 0 ]; then
        failed=1
      fi
    done
    stack_check_unmatched || failed=1
    summary
    exit "$failed"
    ;;
  ""|-h|--help|help) usage ;;
  *) usage; die "unknown command: $cmd" ;;
esac
