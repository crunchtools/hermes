#!/bin/bash
# The entrypoint, run against a stand-in `hermes` on PATH (tests/stub-hermes).
#
# No real Hermes is involved and none may be: a second `hermes gateway run`
# would log in to Matrix as the live agent. The stub is what makes the ready,
# ready-late, never-ready and dead-gateway paths all reachable here.
#
# Run it from anywhere:  bash tests/test-entrypoint.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
entrypoint="$here/../rootfs/usr/local/bin/hermes-entrypoint"
stub="$here/stub-hermes"

failures=0
case_dir=
stub_dir=
out=
rc=0
elapsed=0

ok() { printf 'ok   %s\n' "$1"; }

not_ok() {
  printf 'FAIL %s\n' "$1"
  printf '%s\n' "$out" | sed 's/^/     | /'
  failures=$((failures + 1))
}

assert_contains() {
  case "$out" in
    *"$2"*) ok "$1" ;;
    *) not_ok "$1: '$2' is not in the output" ;;
  esac
}

assert_absent() {
  case "$out" in
    *"$2"*) not_ok "$1: '$2' should not be in the output" ;;
    *) ok "$1" ;;
  esac
}

assert_equal() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    not_ok "$1: expected '$3', got '$2'"
  fi
}

assert_at_least() {
  if [ "$2" -ge "$3" ]; then
    ok "$1"
  else
    not_ok "$1: expected at least $3, got $2"
  fi
}

assert_at_most() {
  if [ "$2" -le "$3" ]; then
    ok "$1"
  else
    not_ok "$1: expected at most $3, got $2"
  fi
}

new_case() {
  case_dir=$(mktemp -d)
  stub_dir="$case_dir/stub"
  mkdir -p "$case_dir/bin" "$stub_dir"
  install -m 0755 "$stub" "$case_dir/bin/hermes"
}

cron_calls() {
  if [ -f "$stub_dir/cron-calls" ]; then
    wc -l < "$stub_dir/cron-calls" | tr -d ' '
  else
    echo 0
  fi
}

# Env assignments are passed as arguments: run_entrypoint HERMES_READY_TIMEOUT=3
run_entrypoint() {
  local started=$SECONDS
  out=$(env "PATH=$case_dir/bin:$PATH" "HOME=$case_dir" "STUB_DIR=$stub_dir" "$@" \
    bash "$entrypoint" 2>&1)
  rc=$?
  elapsed=$((SECONDS - started))
}

# The same, with the arguments handed to the entrypoint rather than to env.
run_entrypoint_with_args() {
  out=$(env "PATH=$case_dir/bin:$PATH" "HOME=$case_dir" "STUB_DIR=$stub_dir" \
    bash "$entrypoint" "$@" 2>&1)
  rc=$?
}

# --- the readiness line is printed once the CLI answers --------------------
#
# The whole point of the line. Falsify by printing it before the poll loop:
# the "gave up" assertions in the never-ready case below then fail.
test_says_it_is_ready_once_cron_list_answers() {
  new_case
  touch "$stub_dir/cron-ok"
  run_entrypoint STUB_GATEWAY_LIFETIME=2 HERMES_READY_TIMEOUT=10
  assert_contains "the ready line is printed when cron list answers" "ready: cron list answered after"
  assert_absent "the success path does not also say it gave up" "gave up"
  assert_equal "the gateway's own exit status is the container's" "$rc" 0
}

# --- the wait is the point, not the final check -----------------------------
#
# A gateway is not instant. If readiness looked once and moved on, a scheduler
# that answers two seconds later would be reported as a gateway that never came
# up, and the deploy robot would roll back a healthy deploy. Falsify by
# deleting the poll loop: this is the test that fails first.
test_waits_for_a_scheduler_that_answers_late() {
  new_case
  (
    sleep 2
    touch "$stub_dir/cron-ok"
  ) &
  local marker=$!
  run_entrypoint STUB_GATEWAY_LIFETIME=6 HERMES_READY_TIMEOUT=20
  wait "$marker" 2>/dev/null
  assert_contains "a late answer still produces the ready line" "ready: cron list answered after"
  assert_absent "a late answer is not reported as a failure" "gave up"
  assert_at_least "it polled more than once" "$(cron_calls)" 2
}

# --- and it gives up without ever claiming to be ready --------------------
#
# The two assertions are separate claims. The first is that the failure line
# appears; the second is that the WAITING happened, which is what a test on the
# final check alone would miss. Falsify by deleting the poll loop: the call
# count drops to 1 and the reported wait to 0s, and both fail.
test_gives_up_without_claiming_to_be_ready() {
  new_case
  run_entrypoint STUB_GATEWAY_LIFETIME=5 HERMES_READY_TIMEOUT=3
  assert_contains "the failure line is printed" "gave up: no answer from cron list in"
  # "NOT ready" would contain "ready", and a watcher told to wait for the
  # success line would be satisfied by the failure one.
  assert_absent "the failure line shares no substring with the success line" "ready"
  assert_at_least "it kept polling for the whole timeout" "$(cron_calls)" 3
  local waited
  waited=$(printf '%s\n' "$out" | sed -n 's/.*no answer from cron list in \([0-9]*\)s.*/\1/p')
  assert_at_least "the failure is reported after the timeout, not at once" "${waited:-0}" 2
}

# --- a dead gateway ends the wait at once ----------------------------------
#
# Promptness is the claim, so the timeout is set far above the budget: a
# generous assertion would be satisfied by the slow path too. Falsify by
# deleting the `kill -0` liveness check -- this then takes the full 60s.
test_a_dead_gateway_stops_the_wait_at_once() {
  new_case
  run_entrypoint STUB_GATEWAY_EXIT=9 HERMES_READY_TIMEOUT=60
  assert_contains "a dead gateway is reported as a failure" "gave up: no answer from cron list in"
  assert_absent "a dead gateway is never reported as ready" "ready"
  assert_equal "the gateway's exit status is still the container's" "$rc" 9
  assert_at_most "the wait ended at once rather than after the timeout" "$elapsed" 20
}

# --- the banner still reaches the log -------------------------------------
test_the_gateway_output_still_reaches_the_log() {
  new_case
  touch "$stub_dir/cron-ok"
  run_entrypoint STUB_GATEWAY_LIFETIME=1 HERMES_READY_TIMEOUT=10
  assert_contains "the gateway's own startup output is not swallowed" "Hermes Gateway Starting"
}

# --- the gateway still has the container's stdin --------------------------
#
# The old ENTRYPOINT was exec'd, so it had stdin. Bash gives an asynchronous
# command /dev/null instead unless the redirection is explicit, so the `<&0` in
# the entrypoint is load-bearing. Falsify by deleting it.
test_the_gateway_keeps_the_containers_stdin() {
  new_case
  touch "$stub_dir/cron-ok"
  out=$(printf 'hello from stdin\n' | env "PATH=$case_dir/bin:$PATH" "HOME=$case_dir" \
    "STUB_DIR=$stub_dir" STUB_READ_STDIN=1 STUB_GATEWAY_LIFETIME=1 HERMES_READY_TIMEOUT=10 \
    bash "$entrypoint" 2>&1)
  rc=$?
  local seen=
  if [ -f "$stub_dir/stdin-line" ]; then
    seen=$(cat "$stub_dir/stdin-line")
  fi
  assert_equal "the gateway is handed the container's stdin, not /dev/null" \
    "$seen" "hello from stdin"
}

# --- arguments still land where they always did ----------------------------
#
# The old ENTRYPOINT was exec form, so a container's arguments were appended to
# `hermes gateway run`. They still are. Running them INSTEAD of the gateway
# would be a quietly different image, and this is the test that would catch it.
test_arguments_are_appended_to_the_gateway() {
  new_case
  touch "$stub_dir/cron-ok"
  run_entrypoint_with_args --verbose
  local argv=
  if [ -f "$stub_dir/gateway-argv" ]; then
    argv=$(cat "$stub_dir/gateway-argv")
  fi
  assert_equal "arguments are appended to the gateway command" "$argv" "gateway run --verbose"
  assert_contains "the readiness line is still printed" "ready: cron list answered after"
}

# --- the wait keeps to its timeout even when a probe is slow ---------------
#
# The deploy robot sets its readiness window against HERMES_READY_TIMEOUT, so
# overshooting it is the robot rolling back a deploy that was about to report.
# Falsify by bounding each probe with probe_timeout alone: with a 10s probe
# timeout and a 4s wait, the failure line arrives at 10s.
test_a_slow_probe_does_not_outlast_the_timeout() {
  new_case
  run_entrypoint STUB_CRON_HANG=30 STUB_GATEWAY_LIFETIME=5 \
    HERMES_READY_TIMEOUT=4 HERMES_READY_PROBE_TIMEOUT=10
  assert_contains "a hung probe still produces the failure line" "gave up: no answer from cron list in"
  local waited
  waited=$(printf '%s\n' "$out" | sed -n 's/.*no answer from cron list in \([0-9]*\)s.*/\1/p')
  assert_at_most "the reported wait is the timeout, not the probe timeout" "${waited:-99}" 6
  assert_at_most "the wait ended on its own timeout" "$elapsed" 8
}

# --- TERM is not held up by a probe in flight ------------------------------
#
# Bash defers a trap until the foreground command returns, so a probe run in
# the foreground would sit on the gateway's TERM for the whole probe timeout
# and eat the runtime's shutdown grace period. Falsify by running the probe in
# the foreground instead of backgrounding it and waiting.
test_term_is_not_held_up_by_a_probe_in_flight() {
  new_case
  local log="$case_dir/log"
  env "PATH=$case_dir/bin:$PATH" "HOME=$case_dir" "STUB_DIR=$stub_dir" \
    STUB_CRON_HANG=30 STUB_GATEWAY_LIFETIME=30 \
    HERMES_READY_TIMEOUT=60 HERMES_READY_PROBE_TIMEOUT=20 \
    bash "$entrypoint" > "$log" 2>&1 &
  local pid=$!
  # Long enough that the first probe is certainly in flight.
  sleep 2
  local started=$SECONDS
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  local took=$((SECONDS - started))
  out=$(cat "$log")
  assert_at_most "TERM reaches the gateway while a probe is in flight" "$took" 5
  if [ -f "$stub_dir/got-term" ]; then
    ok "the gateway got the TERM, not just the wrapper"
  else
    not_ok "the gateway got the TERM, not just the wrapper"
  fi
}

# --- TERM reaches the gateway ---------------------------------------------
#
# The gateway was PID 1 and is a child now, so the trap is the only thing
# carrying the runtime's stop signal to it. Falsify by deleting the trap.
test_term_reaches_the_gateway() {
  new_case
  touch "$stub_dir/cron-ok"
  local log="$case_dir/log"
  env "PATH=$case_dir/bin:$PATH" "HOME=$case_dir" "STUB_DIR=$stub_dir" \
    STUB_GATEWAY_LIFETIME=30 HERMES_READY_TIMEOUT=10 \
    bash "$entrypoint" > "$log" 2>&1 &
  local pid=$!
  local waited=0
  while [ "$waited" -lt 15 ] && ! grep -q "ready:" "$log"; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  out=$(cat "$log")
  if [ -f "$stub_dir/got-term" ]; then
    ok "TERM is forwarded to the gateway"
  else
    not_ok "TERM is forwarded to the gateway"
  fi
}

[ -x "$entrypoint" ] || { echo "$entrypoint is not executable" >&2; exit 2; }
bash -n "$entrypoint" || exit 2
bash -n "$stub" || exit 2

test_says_it_is_ready_once_cron_list_answers
test_waits_for_a_scheduler_that_answers_late
test_gives_up_without_claiming_to_be_ready
test_a_dead_gateway_stops_the_wait_at_once
test_the_gateway_output_still_reaches_the_log
test_the_gateway_keeps_the_containers_stdin
test_arguments_are_appended_to_the_gateway
test_a_slow_probe_does_not_outlast_the_timeout
test_term_reaches_the_gateway
test_term_is_not_held_up_by_a_probe_in_flight

if [ "$failures" -ne 0 ]; then
  echo "$failures assertion(s) failed" >&2
  exit 1
fi
echo "all assertions passed"
