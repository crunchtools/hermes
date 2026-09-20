# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
