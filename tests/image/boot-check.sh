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

# Production bind-mounts /app/.hermes, /app/logs and signal-cli's data dir;
# the old gate gave each a tmpfs. Here the image's own root is not writable
# by its user, so the same state lives under /tmp.
export HOME=/tmp/app HERMES_HOME=/tmp/app/.hermes HERMES_CONFIG_DIR=/tmp/app/.hermes
mkdir -p "$HERMES_HOME" /tmp/app/logs /tmp/app/.local/share/signal-cli

/usr/local/bin/hermes-entrypoint > "$log" 2>&1 < /dev/null &
pid=$!
# The image has no grep (its grep is a coreutils name coreutils does not
# answer to), so lines are matched with bash alone.
line() {  # line <prefix>: print the first log line starting with it; 1 if none
  local l
  [ -f "$log" ] || return 1
  while IFS= read -r l; do
    if [[ $l == "$1"* ]]; then printf '%s\n' "$l"; return 0; fi
  done < "$log"
  return 1
}
stop() { kill "$pid" 2> /dev/null || true; wait "$pid" 2> /dev/null || true; }

SECONDS=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if line 'hermes: ready:'; then
    echo "boot check: PASS"
    stop
    exit 0
  fi
  line 'hermes: gave up:' > /dev/null && break
  kill -0 "$pid" 2> /dev/null || break
  sleep 2
done
echo "boot check: FAIL -- no 'hermes: ready:' line" >&2
tail -40 "$log" >&2
stop
exit 1
