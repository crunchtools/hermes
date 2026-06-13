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

# Stage 1: Install hermes-agent + signal-cli on UBI10-minimal.
#
# Why UBI10-minimal instead of the distroless Hummingbird python:3.13 we use for
# pure-Python MCP servers: Hermes is an *autonomous agent* that legitimately needs
# /bin/sh and standard userspace tools to orchestrate its work (subprocess.run,
# os.system, signal-cli wrapper). The distroless runtime was rejecting Hermes's
# internal shell-outs with "FileNotFoundError: '/bin/sh'". UBI10-minimal includes a
# real shell while staying ~120MB before our Python adds.
FROM registry.access.redhat.com/ubi10/ubi-minimal AS builder

USER 0
WORKDIR /build

# Builder needs Python + pip + tar/gzip to fetch signal-cli.
RUN microdnf install -y --nodocs python3.13 python3.13-pip tar gzip && \
    microdnf clean all

# hermes-agent is published on PyPI; install into an isolated venv we copy into
# the runtime image. Pinned for reproducible builds.
#
# IMPORTANT: the [mcp] extra pulls mcp>=1.26 which provides
# mcp.client.streamable_http — required for Hermes to consume the streamable-http
# MCP servers running on lotor (mcp-slack, mcp-mediawiki, mcp-airlock, etc.).
# Without this extra, `hermes mcp add` saves configs but shows "✗ disabled" and
# never connects, regardless of server availability.
ARG HERMES_VERSION=0.16.0
RUN python3.13 -m venv /app/venv && \
    /app/venv/bin/pip install --no-cache-dir "hermes-agent[mcp]==${HERMES_VERSION}"

# signal-cli native binary (GraalVM, no JVM at runtime). Matches the pattern
# crunchtools/openclaw uses for the same purpose.
ARG SIGNAL_CLI_VERSION=0.14.5
RUN curl -sL "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz" \
        -o /tmp/signal-cli.tar.gz && \
    mkdir -p /build/signal-cli/bin && \
    tar -xzf /tmp/signal-cli.tar.gz -C /build/signal-cli/bin && \
    chmod +x /build/signal-cli/bin/signal-cli && \
    rm /tmp/signal-cli.tar.gz

# Stage 2: Runtime — UBI10-minimal with Python 3.13 + libstdc++ for signal-cli JNI.
FROM registry.access.redhat.com/ubi10/ubi-minimal

LABEL maintainer="fatherlinux <scott.mccarty@crunchtools.com>"
LABEL description="Hermes Agent autonomous AI agent — crunchtools deployment under the Autonomous Agent constitution profile (Signal messaging, weekly orchestration of crunchtools GHA cascade, ops watchers)."
LABEL org.opencontainers.image.source="https://github.com/crunchtools/hermes"
LABEL org.opencontainers.image.title="hermes"
LABEL org.opencontainers.image.description="Hermes Agent containerized for crunchtools per profiles/autonomous-agent.md"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"
LABEL org.opencontainers.image.vendor="crunchtools"

USER 0
# Runtime needs Python 3.13 (to run hermes-agent), ca-certs for HTTPS, and
# libstdc++ which signal-cli's GraalVM JNI bridge dlopen()s at startup.
RUN microdnf install -y --nodocs python3.13 ca-certificates libstdc++ && \
    microdnf clean all

WORKDIR /app

COPY --from=builder /app/venv /app/venv
COPY --from=builder /build/signal-cli /app/signal-cli

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
ENTRYPOINT ["hermes", "gateway", "run"]
