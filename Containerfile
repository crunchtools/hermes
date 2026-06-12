# Hermes Agent — crunchtools deployment
# Autonomous AI agent (Nous Research Hermes) running under the
# crunchtools Autonomous Agent constitution profile.
#
# Build:
#   podman build -t quay.io/crunchtools/hermes .
#
# Run (mirrors openclaw deployment shape):
#   podman run -d --name hermes.crunchtools.com \
#     --rm --read-only --tmpfs /tmp:rw,nosuid \
#     --network crunchtools \
#     -p 127.0.0.1:18790:18790 \
#     -v /srv/hermes.crunchtools.com/data/hermes:/app/.hermes:Z \
#     -v /srv/hermes.crunchtools.com/data/signal:/app/.local/share/signal-cli:Z \
#     -v /srv/hermes.crunchtools.com/logs:/app/logs:Z \
#     --env-file /srv/hermes.crunchtools.com/config/env \
#     quay.io/crunchtools/hermes

# Stage 1: Install hermes-agent and signal-cli into staging dirs
FROM quay.io/hummingbird/python:3.13-builder AS builder

# Hummingbird's distroless builder defaults to a non-root user that can't
# write to /app — switch to root for the build stage (it's discarded anyway).
# Same pattern as crunchtools/mcp-airlock.
USER 0

WORKDIR /build

# hermes-agent is published on PyPI; install into an isolated venv we can
# copy into the runtime image. Pinned for reproducible builds.
ARG HERMES_VERSION=0.16.0
RUN python3.13 -m venv /app/venv && \
    /app/venv/bin/pip install --no-cache-dir "hermes-agent==${HERMES_VERSION}"

# signal-cli native binary (GraalVM, no JVM at runtime). Matches the
# pattern crunchtools/openclaw uses for the same purpose.
ARG SIGNAL_CLI_VERSION=0.14.0
RUN curl -sL "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz" \
        -o /tmp/signal-cli.tar.gz && \
    mkdir -p /build/signal-cli/bin && \
    python3.13 -c "import tarfile; tarfile.open('/tmp/signal-cli.tar.gz').extractall('/build/signal-cli/bin', filter='data')" && \
    python3.13 -c "import os; os.chmod('/build/signal-cli/bin/signal-cli', 0o755); os.remove('/tmp/signal-cli.tar.gz')"

# Stage 2: Minimal runtime — no build tools, no package manager
FROM quay.io/hummingbird/python:3.13

LABEL maintainer="fatherlinux <scott.mccarty@crunchtools.com>"
LABEL description="Hermes Agent autonomous AI agent — crunchtools deployment under the Autonomous Agent constitution profile (Signal messaging, weekly orchestration of crunchtools GHA cascade, ops watchers)."
LABEL org.opencontainers.image.source="https://github.com/crunchtools/hermes"
LABEL org.opencontainers.image.title="hermes"
LABEL org.opencontainers.image.description="Hermes Agent containerized for crunchtools per profiles/autonomous-agent.md"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"
LABEL org.opencontainers.image.vendor="crunchtools"

WORKDIR /app

# Bring in the installed hermes-agent venv and signal-cli native binary
COPY --from=builder /app/venv /app/venv
COPY --from=builder /build/signal-cli /app/signal-cli

# signal-cli's GraalVM native binary extracts a JNI bridge to /tmp at startup
# (libsignal_jni_amd64.so) and dlopen()s it — that .so depends on libstdc++.so.6
# which the distroless Hummingbird python:3.13 runtime doesn't carry (pure Python
# doesn't need C++ runtime). Copy libstdc++ from the builder stage. Same pattern
# as crunchtools/mcp-airlock.
COPY --from=builder /usr/lib64/libstdc++.so.6* /usr/lib64/

ENV PATH="/app/venv/bin:/app/signal-cli/bin:${PATH}" \
    HOME=/app \
    HERMES_CONFIG_DIR=/app/.hermes \
    PYTHONUNBUFFERED=1

EXPOSE 18790

# Health probe via hermes's own self-diagnostic
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD hermes doctor --json >/dev/null 2>&1 || exit 1

# Start the messaging gateway in unattended mode. Signal channel + bot
# pairing is configured via files under /app/.hermes (bind-mounted).
ENTRYPOINT ["hermes", "gateway", "start"]
