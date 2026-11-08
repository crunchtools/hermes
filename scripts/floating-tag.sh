#!/usr/bin/env bash
# Print the ONE floating tag a build run may move.
#
# `latest` is the newest stable RELEASE (constitution 1.33.0), so a branch push
# moves the branch's own tag and a pull request gets its own, and neither can
# touch `latest`. Before that rule, every push to the default branch moved
# `latest`, and on 2026-11-07 that put unreleased trentina 6.11.0 into
# production at 02:01 through podman-auto-update (RT#1559).
#
# This lives in a script rather than inline in build.yml because it decides
# which image a `podman-auto-update` host pulls. tests/test-floating-tag.sh is
# the whole reason it is here.
#
# Reads GITHUB_REF and GITHUB_REF_NAME from the environment; writes the tag to
# stdout.
set -euo pipefail

: "${GITHUB_REF:?GITHUB_REF is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"

# The stable-release test is an anchored vX.Y.Z match, not a `v*` glob. `v*`
# without a hyphen would hand `latest` to vNext, v2beta or v1.1.0rc1 as
# readily as to v1.1.0, and `latest` is the one tag that must never be guessed
# at. Anything else keeps its own name. A slash is legal in a git ref and not
# in an OCI tag, hence the substitution.
case "$GITHUB_REF" in
  refs/tags/*)
    tag_name=${GITHUB_REF#refs/tags/}
    if [[ $tag_name =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      floating=latest
    else
      # A prerelease or other tag keeps its own name, which is also what
      # `git describe` reports at an exact tag, so the run moves one tag and
      # not two. A tag named after what another case owns is REFUSED rather
      # than quietly renamed: build.yml triggers on `tags: ['v*']`, so this
      # is reachable only by dispatching on a hand-made tag, and a hand-made
      # tag called `latest` is a mistake worth stopping rather than papering
      # over.
      case $tag_name in
        latest | main | pr-* | branch-*)
          echo "refusing to move the reserved tag '$tag_name'" >&2
          exit 1
          ;;
      esac
      floating=${tag_name//\//-}
    fi
    ;;
  refs/pull/*)
    # Strip everything after the number, not just `/merge`: pull_request gives
    # refs/pull/N/merge and pull_request_target gives refs/pull/N/head, and
    # `pr-N/head` is not a legal OCI tag.
    pr=${GITHUB_REF#refs/pull/}
    floating=pr-${pr%%/*}
    ;;
  # The default branch, and only it, owns `main`.
  refs/heads/main)
    floating=main
    ;;
  # Every other branch is namespaced. Not a list of reserved names: a branch
  # may be called anything, including `latest`, `main`, `pr-9` or `v1.2.3`,
  # and workflow_dispatch runs from any branch. A bare branch name would then
  # collide with the release tag of the same name and replace the image
  # consumers expect -- the RT#1559 shape with extra steps. One prefix closes
  # the whole class, and it cannot itself collide: a git tag beginning
  # `branch-` does not match the vX.Y.Z test and keeps its own literal name.
  #
  # workflow_dispatch and repository_dispatch land here too; both run from a
  # branch.
  *)
    floating=branch-${GITHUB_REF_NAME//\//-}
    ;;
esac

printf '%s\n' "$floating"
