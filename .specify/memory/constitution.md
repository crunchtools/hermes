# hermes Constitution

> **Version:** 1.0.0
> **Ratified:** 2026-10-02
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.20.0
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
image.

## Layer 3 — Container & Supply Chain Security

- **Image:** `quay.io/crunchtools/hermes` and `ghcr.io/crunchtools/hermes`.
- **Upstream build, unmodified:** Hermes is cloned at the `HERMES_REF` git
  tag and installed the way upstream's own Dockerfile does it (`uv sync
  --frozen --no-install-project`, then an editable `--no-deps` install).
  Upstream stopped publishing to PyPI after 0.19.0 and blocks wheel and sdist
  builds. Upstream's `uv.lock` decides every dependency: no overrides, no
  forced upgrades. The one addition is `pypdf`.
- **Extras:** `mcp`, `matrix`, `vision`, `cron`, `pty`, `web`, `youtube`. Left
  out: Google, Discord/Telegram/Slack messaging, voice/wake/TTS (no audio
  device), the LLM-provider and search/memory backends (reached through the
  gateway) and computer-use (headless).
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
- **Trivy:** blocking (exit code 1) with `.trivyignore`. This deviates from
  the fleet's advisory Trivy step on purpose: turning a security gate advisory
  is not a CI-cleanup side effect. Each ignore entry records why the finding
  is unreachable or blocked upstream, and when to revisit it. SBOM (SPDX)
  generated per build; cosign signing is deferred to Phase 4.
- **No `schedule:` trigger:** the image rebuilds on `parent-image-updated`,
  which Hermes fires at itself as part of its weekly pulse to every root.
- **Runtime:** rootless (UID 65532), `--read-only` root filesystem with
  `--tmpfs /tmp:rw,nosuid`, SELinux `:Z` volume labels, published on
  `127.0.0.1:18790` only.

## Layer 4 — Runtime Security & Behavioral Controls

Entry point `hermes gateway run`, unattended. Circuit breakers, rate limits
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
