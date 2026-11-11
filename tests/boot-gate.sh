#!/bin/bash
# Boot gate for the release workflow: run the image the way production does
# (its own ENTRYPOINT, read-only rootfs, no credentials) and require the
# entrypoint's `hermes: ready:` line within a deadline.
#
# That line is printed only after `hermes cron list` has answered, which proves
# the console script in the shipped venv executes in THIS image, the config dir
# is readable and the jobs store parses -- how this image has broken before. A
# `hermes: gave up:` line, or the container exiting first, fails the gate.
#
# No Matrix or provider credentials are given, so nothing here can log in as the
# live agent. Usage: boot-gate.sh <image>   (or IMAGE=<image>)
set -euo pipefail

image=${1:-${IMAGE:-}}
[ -n "$image" ] || { echo "usage: $0 <image>" >&2; exit 2; }
deadline=${BOOT_GATE_TIMEOUT:-150}
name=hermes-boot-gate-$$

cleanup() { podman rm -f "$name" > /dev/null 2>&1 || true; }
trap cleanup EXIT

podman run -d --name "$name" --read-only --tmpfs /tmp:rw,nosuid \
  --tmpfs /app/.hermes:rw,nosuid --tmpfs /app/logs:rw,nosuid \
  --tmpfs /app/.local/share/signal-cli:rw,nosuid \
  "$image" > /dev/null

SECONDS=0
while [ "$SECONDS" -lt "$deadline" ]; do
  logs=$(podman logs "$name" 2>&1 || true)
  if grep -q '^hermes: ready:' <<< "$logs"; then
    grep '^hermes: ready:' <<< "$logs" | head -1
    echo "boot gate: PASS"
    exit 0
  fi
  if grep -q '^hermes: gave up:' <<< "$logs"; then
    break
  fi
  [ "$(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] || break
  sleep 2
done
echo "boot gate: FAIL -- no 'hermes: ready:' line from $image" >&2
podman logs "$name" 2>&1 | tail -40 >&2
exit 1
