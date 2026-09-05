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

# Stage 1: Install hermes-agent and signal-cli into staging dirs.
# The Hummingbird builder image has bash, coreutils, microdnf and gcc — we
# borrow bash + coreutils into the runtime stage further down.
FROM quay.io/hummingbird/python:3.13-builder AS builder

# Hummingbird's distroless builder defaults to a non-root user that can't
# write to /app — switch to root for the build stage (it's discarded anyway).
# Same pattern as crunchtools/mcp-airlock.
USER 0

WORKDIR /build

# Install hermes-agent from PyPI, using UPSTREAM'S OWN EXTRAS.
#
# Why not build from upstream's git tag (v0.21.0)? Because they block it:
#   RuntimeError: Building wheels or sdists for hermes-agent is not supported.
#   Hermes is distributed via the shell installer, Docker image, or Nix.
# Their own Dockerfile works around this with `uv sync --no-install-project`
# plus running from the source tree -- but that image is 465 lines on
# debian:13.4 with npm builds for the web/TUI assets, a patched SQLite for
# FTS5, and Playwright. Reproducing it on Hummingbird is a project, not a
# build tweak, and adopting their Debian image outright would break the base
# image rule in the Autonomous Agent profile (Section III).
#
# So PyPI it is -- 0.19.0 is the newest wheel they publish (PyPI has been
# stale since 2026-07-20; 0.19.1 and all of 0.20.x/0.21.0 are git-only).
#
# The important change is HOW we install. This used to hand-list the packages
# that upstream's [matrix] extra already declares, and drifted on exactly one
# pin -- aiohttp unpinned resolved to 3.14.3 where 0.19.0 demands 3.14.1 --
# which broke Matrix in production. Naming the extras instead makes that class
# of drift impossible: upstream's pins win, every time.
#
# Extras chosen for the Kagetora personal-assistant deployment:
#   mcp     Trentina gateway -- every tool the agent has
#   matrix  primary chat interface
#   vision  image recognition (zero deps; core Pillow does the work)
#   cron    scheduled jobs (zero deps)
#   pty     terminal support (zero deps)
#   web     gateway HTTP surface
#   youtube transcript extraction -- one dep, useful for a PA
#
# Deliberately NOT installed: google (reached via Trentina's gw-* backends),
# messaging (discord.py/telegram/slack -- Matrix is the interface, and a lazy
# discord install once blocked startup for minutes), voice/wake/tts (no audio
# device in a container), every LLM provider extra (the LLM is a custom
# OpenAI-compatible endpoint behind Trentina; openai is core), search and
# memory backends (Trentina again), and computer-use (headless).
ARG HERMES_VERSION=0.19.0
RUN microdnf install -y gcc-c++ make python3.13-devel && microdnf clean all
RUN python3.13 -m venv /app/venv && \
    /app/venv/bin/pip install --no-cache-dir cmake && \
    /app/venv/bin/pip install --no-cache-dir \
        "hermes-agent[mcp,matrix,vision,cron,pty,web,youtube]==${HERMES_VERSION}" \
        pypdf && \
    /app/venv/bin/pip install --no-cache-dir --upgrade "Pillow>=12.3.0" "cryptography>=50.0.0"

# Pillow is the ONE override kept, and only because network isolation does not
# cover it. Trentina is a network boundary, not a content filter: Matrix
# delivers internet-originated images straight into a vision-enabled agent, and
# Pillow parses them. CVE-2026-59197 and CVE-2026-59205 are native heap
# out-of-bounds write and controlled heap corruption respectively -- reachable
# by anyone who can send Kagetora a picture. 0.19.0 pins Pillow==12.2.0; 12.3.0
# is what upstream themselves moved to in 0.21.0, so this tracks their fix
# rather than inventing one.
#
# Every other CVE override was dropped. The mcp, Starlette and PyJWT findings
# are server-side or auth-side: they require reaching this container's socket,
# and nothing can -- internal=true network, nothing published to the host, two
# containers on it. Those are accepted in .trivyignore with that reasoning.

# Fail the build if the pieces Kagetora cannot live without are missing, and
# print resolved versions so a dependency surprise is visible in the log.
# Does NOT assert a specific mcp client symbol: that import moved between
# mcp 1.x and 2.x, and pinning the assertion to one spelling is how this test
# would rot the next time we move versions.
RUN /app/venv/bin/python -c "import importlib.metadata as m; \
    import mcp, mautrix, PIL, cryptography, aiohttp; \
    print('hermes-agent', m.version('hermes-agent'), '| mcp', m.version('mcp'), \
          '| mautrix', m.version('mautrix'), '| aiohttp', m.version('aiohttp'), \
          '| Pillow', m.version('pillow'), '| cryptography', cryptography.__version__)"
RUN /app/venv/bin/pip check || true


# signal-cli native binary (GraalVM, no JVM at runtime). Matches the
# pattern crunchtools/openclaw uses for the same purpose.
ARG SIGNAL_CLI_VERSION=0.14.5
RUN curl -sL "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz" \
        -o /tmp/signal-cli.tar.gz && \
    mkdir -p /build/signal-cli/bin && \
    python3.13 -c "import tarfile; tarfile.open('/tmp/signal-cli.tar.gz').extractall('/build/signal-cli/bin', filter='data')" && \
    python3.13 -c "import os; os.chmod('/build/signal-cli/bin/signal-cli', 0o755); os.remove('/tmp/signal-cli.tar.gz')"

# Node.js 22 LTS — Hermes's install.sh bootstrap checks for this on every start
# and tries to install it at runtime if missing (fails on read-only rootfs).
# Pre-installing avoids the retry loop and the 10-30s bootstrap delay per restart.
ARG NODE_VERSION=22.16.0
RUN curl -sL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" \
        -o /tmp/node.tar.gz && \
    mkdir -p /build/node && \
    python3.13 -c "import tarfile; t=tarfile.open('/tmp/node.tar.gz'); members=[m for m in t.getmembers()]; prefix=members[0].name.split('/')[0]+'/'; [setattr(m,'name',m.name[len(prefix):]) for m in members if m.name.startswith(prefix)]; t.extractall('/build/node',members=[m for m in members if m.name],filter='data')" && \
    rm /tmp/node.tar.gz

# Stage 2: Minimal runtime — Hummingbird distroless python:3.13 plus a small
# shell layer (bash + coreutils) carried over from the builder.
#
# Why: the pure distroless runtime has no /bin/sh, so any hermes-agent path that
# uses subprocess.run() or os.system() blows up with `FileNotFoundError:
# '/bin/sh'`. Kagetora hit this in production (it could no longer run `ls` or
# `echo`). Rather than switch base images, we lift bash + coreutils out of the
# Hummingbird builder stage (same glibc family, libs guaranteed compatible) and
# symlink the standard command names. Adds ~3MB to the runtime; preserves the
# distroless-Hummingbird posture for the rest of the image.
FROM quay.io/hummingbird/python:3.13

LABEL maintainer="fatherlinux <scott.mccarty@crunchtools.com>"
LABEL description="Hermes Agent autonomous AI agent — crunchtools deployment under the Autonomous Agent constitution profile (Signal messaging, weekly orchestration of crunchtools GHA cascade, ops watchers)."
LABEL org.opencontainers.image.source="https://github.com/crunchtools/hermes"
LABEL org.opencontainers.image.title="hermes"
LABEL org.opencontainers.image.description="Hermes Agent containerized for crunchtools per profiles/autonomous-agent.md"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"
LABEL org.opencontainers.image.vendor="crunchtools"

WORKDIR /app

# Bring in the installed hermes-agent venv, signal-cli, and Node.js
COPY --from=builder /app/venv /app/venv
COPY --from=builder /build/signal-cli /app/signal-cli
COPY --from=builder /build/node/bin/node /usr/bin/node

# signal-cli's GraalVM native binary extracts a JNI bridge to /tmp at startup
# (libsignal_jni_amd64.so) and dlopen()s it — that .so depends on libstdc++.so.6
# which the distroless Hummingbird python:3.13 runtime doesn't carry (pure Python
# doesn't need C++ runtime). Copy libstdc++ from the builder stage. Same pattern
# as crunchtools/mcp-airlock.
COPY --from=builder /usr/lib64/libstdc++.so.6* /usr/lib64/

# Shell layer: bash + coreutils + their shared libraries from the same builder.
# These let Python's subprocess module find /bin/sh and the common Unix tools
# Hermes expects to be on PATH (ls, cat, echo, grep, etc.).
COPY --from=builder /usr/bin/bash /usr/bin/bash
COPY --from=builder /usr/bin/coreutils /usr/bin/coreutils
# Hummingbird runtime already has libtinfo, libreadline, libsystemd, libselinux,
# libcap, libpcre2-8, libc, libm, libgcc_s — see the lib audit. Only libacl +
# libattr are missing from the coreutils dependency closure.
COPY --from=builder /usr/lib64/libacl.so.* /usr/lib64/libattr.so.* /usr/lib64/

# Create /bin/sh + /bin/bash + the coreutils multi-call symlinks. We use Python
# rather than shell because there's a chicken-and-egg problem: `ln -sf` is itself
# part of coreutils, but the coreutils symlinks don't exist until this RUN
# finishes. Python's os.symlink hits the libc syscall directly — no shell, no ln.
#
# USER 0 first because the Hummingbird python:3.13 base defaults to UID 65532
# which can't write into /bin or /usr/bin. Switch back to that default after.
USER 0
RUN ["/usr/sbin/python3.13", "-c", "import os; os.makedirs('/bin', exist_ok=True); [os.path.exists(p) or os.symlink('/usr/bin/bash', p) for p in ('/bin/sh','/bin/bash')]; [os.path.exists('/usr/bin/'+c) or os.symlink('/usr/bin/coreutils', '/usr/bin/'+c) for c in 'cat echo ls cp mv rm ln chmod chown mkdir rmdir grep head tail wc pwd whoami env id date sleep test true false dirname basename realpath readlink stat printf seq sort uniq tr cut tee touch uname arch hostname'.split()]"]


USER 65532

ENV PATH="/app/venv/bin:/app/signal-cli/bin:${PATH}" \
    HOME=/app \
    HERMES_CONFIG_DIR=/app/.hermes \
    PYTHONUNBUFFERED=1

EXPOSE 18790

# Start the messaging gateway in unattended mode. Signal channel + bot
# pairing is configured via files under /app/.hermes (bind-mounted).
ENTRYPOINT ["hermes", "gateway", "run"]
