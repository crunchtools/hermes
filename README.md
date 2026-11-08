# crunchtools/hermes

Hermes Agent (Nous Research) containerized for the crunchtools fleet under the
[Autonomous Agent constitution profile](https://github.com/crunchtools/constitution/blob/main/profiles/autonomous-agent.md).

Sister project to `crunchtools/openclaw`. Runs alongside OpenClaw.
Owns the weekly orchestration of the crunchtools GHA cascade plus a set of ops
watchers (DB backup verification, Quay image freshness, Nagios issue summary,
periodic environment reports). Messaging via Signal.

**Status: Phase 1 (MVP container) — build is unverified at first commit.**

## Phased delivery

| Phase | What | Status |
|---|---|---|
| 1 | Containerfile + GHA build (Buildah → Trivy → SBOM → Quay + GHCR) | this repo |
| 2 | Trust boundary (P-Agent/Q-Agent), circuit breakers, audit logging | next |
| 3 | Configured ops timers (GHA pulse, backups, Quay, Nagios, reports) | next |
| 4 | Per-repo constitution at `.specify/memory/constitution.md`, cosign signing, production gates | next |

## Build

```bash
podman build -t quay.io/crunchtools/hermes .
```

## Run (mirrors the openclaw layout)

```bash
podman run -d --name hermes.crunchtools.com \
  --rm --read-only --tmpfs /tmp:rw,nosuid \
  --network crunchtools \
  -p 127.0.0.1:18790:18790 \
  -v /srv/<service>/data/hermes:/app/.hermes:Z \
  -v /srv/<service>/data/signal:/app/.local/share/signal-cli:Z \
  -v /srv/<service>/logs:/app/logs:Z \
  --env-file /srv/<service>/config/env \
  quay.io/crunchtools/hermes
```

## Readiness

The container exposes no port on the hosts that run it, so Nagios can only say
that the container is running and the crunchtools deploy robot
([crunchtools/deployer#17](https://github.com/crunchtools/deployer/issues/17))
has to verify the service by waiting for a line in the container log.

`/usr/local/bin/hermes-entrypoint` starts `hermes gateway run` and then polls
the read-only `hermes cron list` until the scheduler answers:

| Line | Meaning |
|---|---|
| `hermes: serving: cron list answered after Ns` | the gateway is up and answering. **Watch for `serving:`.** |
| `hermes: gave up: cron list did not answer in Ns` | it never answered inside the timeout, or the gateway died first |

Hermes's own `☤ Hermes Gateway Starting...` banner is printed at launch, which
is the wrong side of ready: a watcher waiting for it would call the container
healthy while it was still coming up. The two lines above share no substring on
purpose, so a watcher matching `serving:` cannot be satisfied by the failure.

| Variable | Default | What |
|---|---|---|
| `HERMES_READY_TIMEOUT` | `120` | seconds to wait for the scheduler before giving up |
| `HERMES_READY_PROBE_TIMEOUT` | `10` | seconds any one `cron list` probe may take |

Arguments given to the container are appended to `hermes gateway run`, which is
what the old exec-form `ENTRYPOINT` did with them, so a unit file that passes
gateway flags keeps working. To run something else in the image, override the
entrypoint:

```bash
podman run --rm --entrypoint hermes ... quay.io/crunchtools/hermes cron list
```

The entrypoint's tests (`tests/test-entrypoint.sh`, run by the `CI` workflow)
drive it against a stand-in `hermes` on `PATH`. Nothing in this repo starts a
real gateway: a second `hermes gateway run` logs in to Matrix as the live agent
and takes over its identity.

## Composition

- Base: `quay.io/hummingbird/python:3.13` (per profile §III base image requirements).
  Not 3.14: hermes-agent requires Python <3.14
- `hermes-agent` installed the way upstream installs it, from a shallow git
  clone at a pinned tag (`HERMES_REF` build arg) with `uv sync --frozen` and
  an editable `uv pip install --no-deps`. Upstream publishes no usable PyPI
  release and blocks wheel builds from source
- `signal-cli` native binary baked in for Signal channel (`SIGNAL_CLI_VERSION` build arg)
- Multi-stage build; runtime image carries no build tools or package manager
- No `HEALTHCHECK`: the container exposes no port on the hosts that run it, so
  readiness is the log line above rather than a probe

## Why no `schedule:` trigger

Per the org-wide cleanup completed 2026-06-10 (see
[crunchtools/constitution#4 / `validate-cascade.py`](https://github.com/crunchtools/constitution)),
no workflow in the crunchtools org has a `schedule:` trigger. Weekly rebuilds
are pulsed by Hermes itself via `workflow_dispatch` and `repository_dispatch`.
Hermes's own image self-refreshes because Hermes pulses every root in its
weekly list, including its own.
