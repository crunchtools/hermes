#!/bin/bash
# Boot check, run inside the built image by sdlc's `boot` check: start the
# image's own entrypoint and require its `hermes: ready:` line within a
# deadline. Was tests/boot-gate.sh, run by container.yml's boot-command, which
# sdlc 0.15's image job does not run (crunchtools/sdlc#118).
#
# That line is printed only after `hermes cron list` has answered, which proves
# the console script in the shipped venv executes in THIS image, the config dir
# is readable and the jobs store parses. A `hermes: gave up:` line, or the
# entrypoint exiting first, fails the check.
#
# No Matrix or provider credentials are given, so nothing here can log in as the
# live agent.
set -uo pipefail

deadline=${BOOT_GATE_TIMEOUT:-150}
log=/tmp/hermes-boot.log

/usr/local/bin/hermes-entrypoint > "$log" 2>&1 < /dev/null &
pid=$!
stop() { kill "$pid" 2> /dev/null || true; wait "$pid" 2> /dev/null || true; }

SECONDS=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -q '^hermes: ready:' "$log"; then
    grep -m1 '^hermes: ready:' "$log"
    echo "boot check: PASS"
    stop
    exit 0
  fi
  grep -q '^hermes: gave up:' "$log" && break
  kill -0 "$pid" 2> /dev/null || break
  sleep 2
done
echo "boot check: FAIL -- no 'hermes: ready:' line" >&2
tail -40 "$log" >&2
stop
exit 1
