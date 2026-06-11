# crunchtools/hermes

Hermes Agent (Nous Research) containerized for the crunchtools fleet under the
[Autonomous Agent constitution profile](https://github.com/crunchtools/constitution/blob/main/profiles/autonomous-agent.md).

Sister project to `crunchtools/openclaw`. Runs alongside OpenClaw on lotor.
Owns the weekly orchestration of the crunchtools GHA cascade plus a set of ops
watchers (DB backup verification, Quay image freshness, Zabbix issue summary,
periodic environment reports). Messaging via Signal.

**Status: Phase 1 (MVP container) — build is unverified at first commit.**

## Phased delivery

| Phase | What | Status |
|---|---|---|
| 1 | Containerfile + GHA build (Buildah → Trivy → SBOM → Quay + GHCR) | this repo |
| 2 | Trust boundary (P-Agent/Q-Agent), circuit breakers, audit logging | next |
| 3 | Configured ops timers (GHA pulse, backups, Quay, Zabbix, reports) | next |
| 4 | Per-repo constitution at `.specify/memory/constitution.md`, cosign signing, production gates | next |

## Build

```bash
podman build -t quay.io/crunchtools/hermes .
```

## Run (mirrors openclaw layout on lotor)

```bash
podman run -d --name hermes.crunchtools.com \
  --rm --read-only --tmpfs /tmp:rw,nosuid \
  --network crunchtools \
  -p 127.0.0.1:18790:18790 \
  -v /srv/hermes.crunchtools.com/data/hermes:/app/.hermes:Z \
  -v /srv/hermes.crunchtools.com/data/signal:/app/.local/share/signal-cli:Z \
  -v /srv/hermes.crunchtools.com/logs:/app/logs:Z \
  --env-file /srv/hermes.crunchtools.com/config/env \
  quay.io/crunchtools/hermes
```

## Composition

- Base: `quay.io/hummingbird/python:latest` (per profile §III base image requirements)
- `hermes-agent` installed via `pip` from PyPI, pinned version (`HERMES_VERSION` build arg)
- `signal-cli` native binary baked in for Signal channel (`SIGNAL_CLI_VERSION` build arg)
- Multi-stage build; runtime image carries no build tools or package manager
- Healthcheck via `hermes doctor --json`

## Why no `schedule:` trigger

Per the org-wide cleanup completed 2026-06-10 (see
[crunchtools/constitution#4 / `validate-cascade.py`](https://github.com/crunchtools/constitution)),
no workflow in the crunchtools org has a `schedule:` trigger. Weekly rebuilds
are pulsed by Hermes itself via `workflow_dispatch` and `repository_dispatch`.
Hermes's own image self-refreshes because Hermes pulses every root in its
weekly list, including its own.
