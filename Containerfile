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

# hermes-agent is published on PyPI; install into an isolated venv we can
# copy into the runtime image. Pinned for reproducible builds.
#
# IMPORTANT: the [mcp] extra pulls mcp>=1.26 which provides
# mcp.client.streamable_http — required for Hermes to consume the streamable-http
# MCP servers running on lotor (mcp-slack, mcp-mediawiki, mcp-airlock, etc.).
# Without this extra, `hermes mcp add` saves configs but shows "✗ disabled" and
# never connects, regardless of server availability.
ARG HERMES_VERSION=0.19.0
RUN microdnf install -y gcc-c++ make python3.13-devel && microdnf clean all
RUN python3.13 -m venv /app/venv && \
    /app/venv/bin/pip install --no-cache-dir cmake && \
    /app/venv/bin/pip install --no-cache-dir "hermes-agent[mcp]==${HERMES_VERSION}" aiohttp \
        "mautrix[encryption]==0.21.0" Markdown "aiosqlite==0.22.1" "asyncpg==0.31.0" "aiohttp-socks==0.11.0" \
        pypdf

# CVE remediation for the 0.19.0 dependency tree.
#
# hermes-agent 0.19.0 hard-pins its dependencies with `==` (cryptography==46.0.7,
# Pillow==12.2.0, mcp==1.26.0, starlette==1.0.1). Several of those pinned
# versions ship known HIGH CVEs, so satisfying the Trivy gate means deliberately
# overriding upstream's pins. That is a considered trade, not an oversight:
#
#   pillow        12.2.0 -> >=12.3.0  (10 CVEs; native heap OOB write + heap
#                                      corruption, and Pillow parses untrusted
#                                      image input)
#   cryptography  46.0.7 -> >=50.0.0  (CVE-2026-69247, CVE-2026-69249)
#   mcp           1.26.0 -> HELD. See .trivyignore -- forcing it resolves to
#                                      mcp 2.1.1 (the MCP 2.x SDK) and breaks
#                                      the streamable-http client API that
#                                      hermes-agent 0.19.0 is written against.
#   setuptools    70.3.0 -> >=78.1.1  (CVE-2025-47273)
#   msgpack        1.1.2 -> >=1.2.1    (GHSA-6v7p-g79w-8964, OOB read on
#                                      Unpacker reuse; transitive, unpinned by
#                                      hermes-agent, so no conflict introduced)
#
# RISK: cryptography backs mautrix E2EE (Matrix). mcp backs the streamable-http
# transport to Trentina and is deliberately NOT forced -- a build-time smoke
# test proved forcing it breaks that transport outright.
# `pip check` runs below and prints the resulting conflicts
# rather than failing, so the mismatch against upstream's pins is visible in the
# build log. Runtime verification against a copy of the real data directory is
# the actual gate before this reaches production.
RUN /app/venv/bin/pip install --no-cache-dir --upgrade \
        "Pillow>=12.3.0" "cryptography>=50.0.0" "setuptools>=78.1.1" "msgpack>=1.2.1"

# Surface the dependency-resolution damage from overriding those pins. Non-fatal
# on purpose: we expect hermes-agent to declare conflicts against the versions
# we forced, and we want to read them, not be blocked by them.
RUN /app/venv/bin/pip check || true

# Prove the two libraries we forced still import and still expose the entry
# points this deployment depends on. Cheap, and it catches an ABI break at build
# time instead of at 3am on lotor.
RUN ["/app/venv/bin/python", "-c", "import cryptography; from mcp.client.streamable_http import streamablehttp_client; from mautrix.crypto import OlmMachine; print('cryptography', cryptography.__version__, '- mautrix OlmMachine OK - mcp streamablehttp_client OK')"]

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

# Collapse the duplicated venv site-packages tree.
#
# In the builder, `python3.13 -m venv` makes lib64/ the real site-packages and
# lib/ a symlink to it (or the reverse). `COPY --from=builder /app/venv` above
# DEREFERENCES that symlink, so the runtime image ends up with two real
# site-packages directories instead of one directory and a link.
#
# Two consequences, both bad: the image carries a full duplicate of every
# installed package, and Trivy scans both copies. That is where the phantom
# findings came from -- setuptools 70.3.0 and msgpack 1.1.2 kept being reported
# as vulnerable while the copy under lib/ scanned clean at 84.0.0 and 1.2.2.
# The stale duplicate was real all along; it just had no path in the summary.
#
# Restore the symlink: keep whichever tree is larger (the one pip actually
# populated) and point the other at it.
RUN ["/usr/sbin/python3.13", "-c", "import os, shutil; a='/app/venv/lib'; b='/app/venv/lib64';\nimport sys\nif os.path.isdir(a) and os.path.isdir(b) and not os.path.islink(a) and not os.path.islink(b):\n    sa=sum(f.stat().st_size for f in __import__('pathlib').Path(a).rglob('*') if f.is_file())\n    sb=sum(f.stat().st_size for f in __import__('pathlib').Path(b).rglob('*') if f.is_file())\n    keep, drop = (a, b) if sa >= sb else (b, a)\n    shutil.rmtree(drop); os.symlink(os.path.basename(keep), drop)\n    print('venv dedup: kept', keep, '- linked', drop, '->', os.path.basename(keep))\nelse:\n    print('venv dedup: nothing to do')"]

USER 65532

ENV PATH="/app/venv/bin:/app/signal-cli/bin:${PATH}" \
    HOME=/app \
    HERMES_CONFIG_DIR=/app/.hermes \
    PYTHONUNBUFFERED=1

EXPOSE 18790

# Start the messaging gateway in unattended mode. Signal channel + bot
# pairing is configured via files under /app/.hermes (bind-mounted).
ENTRYPOINT ["hermes", "gateway", "run"]
