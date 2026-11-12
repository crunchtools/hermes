# hermes Constitution

> **Version:** 2.2.0
> **Ratified:** 2026-10-02
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.41.0
> **Profile:** Autonomous Agent

Hermes Agent (Nous Research) packaged as a container for the crunchtools
fleet; sister project to `crunchtools/openclaw`. It owns the weekly pulse of
the crunchtools GHA cascade and runs ops watchers: database backup
verification, Quay image freshness, a Nagios issue summary and periodic
environment reports.

This file holds what is specific to this deployment. The fleet rules and the
Autonomous Agent profile (the six layers' requirements, quality gates,
naming) apply at the inherited version and are checked against this repo's
files by `constitution.yml`. They are not restated here.

## Trust Boundary

The container has no direct egress: it runs on an internal-only network and
reaches every tool through an MCP gateway, which is the deterministic
boundary between the agent and its backends. A P-Agent/Q-Agent split, circuit
breakers and audit logging are Phase 2 in the README and are not yet
configured in this repo.

## Layer 1 — Trust Boundary Architecture

Single agent behind the MCP gateway; no P-Agent/Q-Agent split yet (Phase 2).

## Layer 2 — MCP Server Governance

Tools come only through the MCP gateway (the `mcp` extra). Search, memory,
Google services and the LLM provider are reached through it rather than
through Hermes's own provider and backend extras, which are left out of the
image. The one provider extra in the image is `anthropic`: it is the wire
client for Trentina's `/llm/anthropic` route, not a way around the gateway.
Every model call still goes to Trentina, which holds the provider key.

## Layer 3 — Container & Supply Chain Security

- **Image:** `quay.io/crunchtools/hermes` (Quay.io is the only registry).
- **Tags:** built once per change by the inherited `container-release.yml`
  (constitution 1.39.1): a pull request builds and gates its head, the merge
  promotes that gated digest to `:main` with no rebuild, and a `vX.Y.Z` tag
  copies it to the version tags and `:latest`. `:latest` is the newest stable
  **release**. Nothing else in this repository publishes an image. The
  workflow carries **no `paths:` filter**: the filter once decided whether a
  commit on the default branch was built at all, and five doc-only merges in a
  row left the head of `main` with no image behind it. The boot gate is
  `tests/boot-gate.sh`, run against the pushed digest.
- **Upstream build, then a named security divergence:** Hermes is cloned at
  the `HERMES_REF` git tag and installed the way upstream's own Dockerfile
  does it (`uv sync --frozen --no-install-project`, then an editable
  `--no-deps` install). Upstream stopped publishing to PyPI after 0.19.0 and
  blocks wheel and sdist builds. Upstream's `uv.lock` decides every dependency
  **except** the packages listed in the Containerfile's divergence block, and
  the one addition, `pypdf`.

  Until 2026-11-08 the rule here was absolute: no overrides, no forced
  upgrades, whatever CVEs the lockfile implies are reported rather than
  fought. That rule and a publishable image stopped being compatible.
  Upstream shipped no tag that resolves clean, the blocking Trivy gate failed
  on every build from 2026-10-21, and `:latest` went three weeks without
  moving while the Kagetora seat ran the stale image
  (crunchtools/hermes#40). Scott ruled on 2026-11-08: upgrade it as
  necessary. So the rule is now bounded rather than absolute, and the bounds
  are what matter:

  - a divergence MUST be a **security** upgrade — a package with a
    HIGH/CRITICAL finding and a published fixed version, or a dependency
    forced by one;
  - it MUST be the smallest version that clears the finding, installed with
    `--no-deps` so the closure cannot drift, with its dependency floors
    checked against upstream's lock and **asserted in the build**;
  - it MUST carry, in the Containerfile beside the pin, what it fixes, why a
    `.trivyignore` entry was not the answer, and what reachability was
    actually measured;
  - it is to be **dropped, not bumped**, the moment upstream's `uv.lock`
    reaches the same floor. A divergence that outlives its finding is a bug;
  - it MUST leave upstream's own **runtime** dependency gates satisfied. A
    version is not only packaging metadata here: `tools/lazy_deps.py` declares
    exact pins and `is_available(feature)` compares installed versions against
    them, and a platform's registry `check_fn` is that call, so a pin the table
    does not expect takes the platform offline while every import still works.
    A divergence that moves such a pin MUST reconcile the table in the same
    change and MUST prove the affected gate open in the build.

  An upgrade is always preferred to an ignore entry. `.trivyignore` is for
  findings no pin can reach.
- **Extras:** `mcp`, `matrix`, `vision`, `cron`, `pty`, `web`, `youtube`,
  `anthropic` (the SDK for the `anthropic_messages` wire to Trentina). Left
  out: Google, Discord/Telegram/Slack messaging, voice/wake/TTS (no audio
  device), the other LLM-provider and the search/memory backends (reached
  through the gateway) and computer-use (headless).
- **Builder:** `quay.io/hummingbird/python:3.13-builder`. **Runtime:**
  `quay.io/hummingbird/python:3.13` (distroless), plus:
  - bash and coreutils copied from the builder, with `/bin/sh` and the common
    command symlinks, because Hermes calls `subprocess` and `os.system` and
    the distroless runtime has no shell;
  - `libstdc++` from the builder, because signal-cli's JNI bridge needs it;
  - Node.js 22 (`NODE_VERSION`), because Hermes's bootstrap otherwise tries to
    install it at start and fails on the read-only root;
  - signal-cli as the GraalVM native binary (`SIGNAL_CLI_VERSION`).
- **uv never provisions an interpreter** (`UV_PYTHON_DOWNLOADS=never`); the
  interpreter is chosen per command, not with `UV_PYTHON`. The build runs
  `hermes --version` in the runtime stage, because builder-stage checks
  passed twice while the shipped image was broken.
- **Vulnerability scanning:** none at build time; published images are scanned on a schedule by the fleet CVE check (grype + Nagios), which pages on a new fixable Critical (constitution 1.40.0, RT #1551). The blocking
  Trivy gate this repo kept on purpose is retired with the fleet's; the fleet
  scan covers this image and pages on a new fixable Critical, which is the
  security property the gate existed for. `.trivyignore` stays as the written
  record of accepted findings that the Containerfile cites: each entry says
  why the finding is unreachable or blocked upstream, and when to revisit it.
  No scanner reads it. SBOM (SPDX)
  generated per build; cosign signing is deferred to Phase 4.
- **No `schedule:` trigger:** the image rebuilds on `parent-image-updated`,
  which Hermes fires at itself as part of its weekly pulse to every root.
- **Runtime:** rootless (UID 65532), `--read-only` root filesystem with
  `--tmpfs /tmp:rw,nosuid`, SELinux `:Z` volume labels, published on
  `127.0.0.1:18790` only.

## Layer 4 — Runtime Security & Behavioral Controls

Entry point `/usr/local/bin/hermes-entrypoint`, which runs
`hermes gateway run` unattended and prints one readiness line once the agent's
CLI answers `cron list` (see README, Readiness). Circuit breakers, rate limits
and audit logging are Phase 2 and have no deployment values in this repo yet.

## Layer 5 — Credential & Identity Management

Secrets come only from the environment file passed with `--env-file`
(`/srv/<service>/config/env`); none are baked into the image. Channel
pairing for Matrix and Signal lives in the bind-mounted `/app/.hermes`.

## Layer 6 — Monitoring, Detection & Response

Kill switch: stop the container. Detection and response values (alerting,
anomaly checks) are not yet recorded in this repo.

## Service

| Attribute | Value |
|-----------|-------|
| Container name | `hermes.crunchtools.com` |
| Port | 18790, `127.0.0.1` only |
| Host directory | `/srv/<service>/` (`data/hermes` → `/app/.hermes`, `data/signal` → signal-cli data, `logs` → `/app/logs`, `config/env`) |
| Messaging | Matrix (`matrix` extra) and Signal (bundled signal-cli) |

## History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-10-02 | First constitution, written as a v1.18.0 manifest from the README, Containerfile, build workflow and `.trivyignore` |
| 1.1.0 | 2026-10-17 | `anthropic` extra admitted as the wire client for Trentina's `/llm/anthropic`; every model call still goes through the gateway |
| 2.1.0 | 2026-11-08 | Fifth condition on a security divergence: it must leave upstream's runtime dependency gates satisfied, reconcile `tools/lazy_deps.py` in the same change, and prove the affected gate open in the build. Prompted by v1.1.0, which shipped aiohttp 3.14.4 over upstream's declared `aiohttp==3.14.3` and took Kagetora's Matrix channel down with every package present and importable |
| 2.0.0 | 2026-11-08 | Breaking: "upstream's `uv.lock` decides every dependency, no overrides" becomes a bounded rule rather than an absolute one. A security divergence is permitted under four conditions and must be dropped when upstream catches up; an upgrade is preferred to a `.trivyignore` entry. Ruled by Scott after the blocking Trivy gate failed on every build from 2026-10-21 over 35 HIGH/CRITICAL findings in upstream's closure, leaving `:latest` three weeks stale (crunchtools/hermes#40). Also records `:latest` as the newest stable release per inherited constitution 1.33.0 |
| 2.2.0 | 2026-11-11 | The blocking per-build Trivy gate is retired with the fleet's (constitution 1.40.0): published images are scanned on a schedule by the fleet CVE check (RT #1551). `.trivyignore` is kept as the accepted-findings record |
