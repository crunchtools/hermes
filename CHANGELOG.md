# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- A readiness line. `/usr/local/bin/hermes-entrypoint` starts the same
  `hermes gateway run` the image has always started, then polls the read-only
  `hermes cron list` until the scheduler answers and prints
  `hermes: serving: cron list answered after Ns`. If it never answers within
  `HERMES_READY_TIMEOUT` (default 120s) it prints
  `hermes: gave up: cron list did not answer in Ns` instead, and it stops
  waiting at once if the gateway has already died. The two lines share no
  substring, so a watcher matching `serving:` cannot be satisfied by the
  failure. This container exposes no port, so that line is the only signal
  the crunchtools deploy robot (crunchtools/deployer#17) can verify the
  service by; the banner Hermes prints is printed at launch, which is the
  wrong side of ready. Refs crunchtools/deployer#17.
- `tests/test-entrypoint.sh`, run by a new `CI` workflow. It exercises the
  entrypoint against a stand-in `hermes` on `PATH`, so no gateway is started:
  ready, ready-late, never-ready, dead-gateway, exit status, TERM forwarding
  and stdin.
- The `anthropic` extra (upstream's pin, `anthropic==0.87.0`). Kagetora moves
  to Claude on the `anthropic_messages` wire through Trentina's
  `/llm/anthropic`, and without the SDK Hermes refuses the request instead of
  falling back.

### Fixed
- Base image back to Hummingbird Python 3.13: hermes-agent requires
  Python <3.14, so the 3.14 bump (#14) broke the image build. Dependabot now
  skips Python 3.14+ until upstream supports it.

### Changed

- `ENTRYPOINT` is `/usr/local/bin/hermes-entrypoint` rather than
  `hermes gateway run` directly. The wrapper runs `hermes gateway run "$@"`, so
  a container's arguments are still appended to the gateway command as the
  exec-form `ENTRYPOINT` appended them; the gateway still gets the container's
  stdin and the runtime's TERM/INT, and the container still ends with the
  gateway's own exit status.
- `timeout` added to the coreutils symlinks, so the entrypoint can bound each
  readiness probe. Each probe is bounded by whatever is left of
  `HERMES_READY_TIMEOUT` as well, so a slow probe cannot push the failure line
  past the timeout a watcher's window is set against.
- A change under `rootfs/` now triggers the build workflow on a push to `main`.
  It did not, because the `paths:` filter named only `Containerfile`,
  `.trivyignore` and the workflow.
- Corrected the README's Composition list, which still described a `pip`
  install from PyPI, a `HERMES_VERSION` build arg, a `python:latest` base and
  a healthcheck. None of those have been true since the image was built
  upstream's way; there is no `HEALTHCHECK` at all.
- Added a v1.18.0 manifest constitution at `.specify/memory/constitution.md`.
- Constitution validation is pinned to the inherited release via
  `.github/workflows/constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.

## [1.0.2] - 2026-10-01

### Security

- Added `.trivyignore` entries for six PyJWT 2.13.0 findings (CVE-2026-102266,
  -102267, -102268 CRITICAL, -102271, -102272, -102273) and two urllib3 2.7.0
  findings (CVE-2026-97687, -97689). They were disclosed after 1.0.1 was
  built and are not introduced by this bump: upstream's `uv.lock` pins the
  same two versions at v2026.8.31, v2026.9.24 and on main, so the 1.0.1 image
  carries them too. No upstream release fixes them yet
  (NousResearch/hermes-agent#128979 is open). Accepted by Scott (2026-10-01)
  as unchanged exposure behind Trentina; remove when upstream's lockfile moves.

### Changed

- Bumped upstream Hermes Agent from v0.21.0 (`v2026.8.31`) to v0.21.5
  (`v2026.9.24`). Only `HERMES_REF` changes; the build method and the extras
  are the same, and upstream's `uv.lock` still decides every dependency.

### Fixed

- Matrix sync no longer stops for good on a transient failure. v0.21.0
  classified a sync error as a permanent auth failure when its message
  contained "401" or "403" anywhere, and a timeout message includes the
  request URL with its numeric `since` token, so an ordinary timeout could
  match and end the sync loop until the next restart. Upstream classifies on
  the structured Matrix error code since v0.21.4.
- Picks up upstream's v0.21.2 session-store fixes: second writers cancelling
  each other's locks, healthy WAL databases reported as corrupt, and
  full-text-index damage failing the whole conversation.

## [1.0.1] - 2026-09-20

### Security

- Added `.trivyignore` entries for CVE-2026-63374 (anyio 4.12.1, CRITICAL TLS
  cert spoofing), CVE-2026-84381 (httpcore2 2.7.0, HIGH plaintext WebSocket
  via SOCKS5), and CVE-2026-84382 (httpx2 2.7.0, HIGH DoS via streaming
  decompression). All three versions are pinned by the `mcp` PyPI package's
  own extras metadata, not by hermes-agent or this Containerfile -- checked
  upstream's three newer tags (v2026.9.7, .9.11, .9.14) directly against
  their uv.lock, all still pin the same vulnerable versions. Blocked on the
  `mcp` package itself, upstream of upstream; no hermes-agent bump fixes it.
  Accepted by Scott (2026-09-20): Kagetora runs behind Trentina, not directly
  internet-reachable, more isolated than the existing pip-vendor exceptions
  already in this file. Revisit when `mcp` ships a fix.

## [1.0.0] - 2026-09-20

First tagged release. This image has been running in production since
before it had version control; this release marks the current state as
the baseline going forward.
