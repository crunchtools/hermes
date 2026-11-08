#!/usr/bin/env bash
# Tests for scripts/floating-tag.sh.
#
# That script decides which tag a run moves, and `latest` is the tag a
# podman-auto-update host on gloval pulls. A wrong answer here does not break
# a build; it quietly ships the wrong image. So every branch of it is driven.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/floating-tag.sh"
failures=0

expect() {
  local want=$1 ref=$2 ref_name=$3 got
  got=$(GITHUB_REF="$ref" GITHUB_REF_NAME="$ref_name" bash "$SCRIPT" 2>&1)
  if [[ $got == "$want" ]]; then
    printf '  ok  %-34s -> %s\n' "$ref" "$got"
  else
    printf '  FAIL %-33s -> %s, wanted %s\n' "$ref" "$got" "$want"
    failures=$((failures + 1))
  fi
}

expect_failure() {
  local label=$1
  shift
  if env -u GITHUB_REF -u GITHUB_REF_NAME "$@" bash "$SCRIPT" >/dev/null 2>&1; then
    printf '  FAIL %s: exited 0, wanted non-zero\n' "$label"
    failures=$((failures + 1))
  else
    printf '  ok  %s\n' "$label"
  fi
}

# A stable release, and only a stable release, moves `latest`.
expect latest     refs/tags/v1.1.0     v1.1.0
expect latest     refs/tags/v12.0.34   v12.0.34
expect v1.1.0-rc1 refs/tags/v1.1.0-rc1 v1.1.0-rc1
expect v1.1.0rc1  refs/tags/v1.1.0rc1  v1.1.0rc1
expect vNext      refs/tags/vNext      vNext
expect v2         refs/tags/v2         v2
expect v1.1       refs/tags/v1.1       v1.1

# The default branch owns `main`; a pull request owns `pr-N`.
expect main  refs/heads/main    main
expect pr-41 refs/pull/41/merge 41/merge
expect pr-41 refs/pull/41/head  41/head

# Every other branch is namespaced, so a branch cannot claim a tag's name.
# This is the whole point: `v1.2.3` and `latest` as BRANCH names are the
# RT#1559 shape, and so is a branch that happens to match a release tag.
expect branch-fix-clear-blocking-cves refs/heads/fix/clear-blocking-cves fix/clear-blocking-cves
expect branch-wip-a-b-c               refs/heads/wip/a/b/c               wip/a/b/c
expect branch-latest                  refs/heads/latest                  latest
expect branch-main                    refs/heads/not-main                main
expect branch-pr-9                    refs/heads/pr-9                    pr-9
expect branch-v1.2.3                  refs/heads/v1.2.3                  v1.2.3

# A hand-made tag named after what another case owns is refused, not renamed.
expect_failure "a tag named latest is refused"    GITHUB_REF=refs/tags/latest   GITHUB_REF_NAME=latest
expect_failure "a tag named main is refused"      GITHUB_REF=refs/tags/main     GITHUB_REF_NAME=main
expect_failure "a tag named pr-1 is refused"      GITHUB_REF=refs/tags/pr-1     GITHUB_REF_NAME=pr-1
expect_failure "a tag named branch-x is refused"  GITHUB_REF=refs/tags/branch-x GITHUB_REF_NAME=branch-x

# A missing input is a hard failure, never a guess at `latest`.
expect_failure "missing GITHUB_REF fails"      GITHUB_REF_NAME=main
expect_failure "missing GITHUB_REF_NAME fails" GITHUB_REF=refs/heads/not-main

echo
if ((failures)); then
  echo "$failures failure(s)"
  exit 1
fi
echo "floating-tag.sh: all checks passed"
