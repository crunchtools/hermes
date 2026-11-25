#!/bin/sh
# Run a Python test with its dependencies from tests/requirements.txt, hash
# for hash (constitution S1: install from lockfiles). The pin-tests and
# reconcile-tests checks in sdlc.toml call it in the uv image.
#
#   tests/run-locked.sh tests/test-verify-pins.py
set -eu
test=${1:?usage: run-locked.sh <test.py>}
venv=$(mktemp -d)
uv venv -q "$venv"
uv pip install --python "$venv/bin/python" --require-hashes --no-deps \
  -r "$(dirname "$0")/requirements.txt"
exec "$venv/bin/python" "$test"
