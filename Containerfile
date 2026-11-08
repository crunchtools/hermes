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

# Install Hermes exactly the way upstream does it.
#
# Upstream does not publish to PyPI (stale since 0.19.0, 2026-07-20) and
# deliberately blocks wheel/sdist builds from source:
#   "Building wheels or sdists for hermes-agent is not supported.
#    Hermes is distributed via the shell installer, Docker image, or Nix."
#
# Their own Dockerfile's sequence, reproduced here verbatim in shape:
#   1. uv sync --frozen --no-install-project <extras>   -- dependencies only
#   2. bring in the source
#   3. uv pip install --no-deps -e "."                  -- editable, no wheel
#
# No version overrides, no forced upgrades, no dependency pinning of our own.
# uv.lock decides everything; whatever CVEs that implies are reported, not
# fought. That is the point of building it their way.
ARG HERMES_REF=v2026.9.24

# Extras for the Kagetora personal-assistant deployment. vision, cron and pty
# carry zero dependencies -- image recognition is a feature flag over core
# Pillow. Left out: google (reached via Trentina's gw-* backends), messaging
# (discord/telegram/slack -- Matrix is the interface), voice/wake/tts (no audio
# device), the other LLM provider extras (OpenRouter is a custom
# OpenAI-compatible endpoint behind Trentina), search/memory backends
# (Trentina), computer-use (headless). anthropic is in: Kagetora runs Claude on
# the anthropic_messages wire through Trentina's /llm/anthropic, and Hermes
# needs the SDK for that route.
ARG HERMES_EXTRAS="--extra mcp --extra matrix --extra vision --extra cron --extra pty --extra web --extra youtube --extra anthropic"

RUN microdnf install -y gcc-c++ make python3.13-devel git && microdnf clean all
# Pin uv to the image's own interpreter. Left to itself uv downloads a managed
# CPython into /tmp/.local/share/uv/python/ and builds the venv against that --
# which is both the wrong version (it picked 3.11, the floor in pyproject) and
# a path that is a tmpfs at runtime. The venv then works in the builder and
# dies on first exec in the runtime image.
# Only ever use the image's own interpreter -- never let uv provision one.
# NOT UV_PYTHON: that is a global default and it hijacks `uv pip install`,
# retargeting it at the system interpreter instead of the project venv, so the
# editable install lands somewhere else and no console script is created. The
# interpreter is chosen per-command below instead.
ENV UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON_PREFERENCE=only-system

RUN python3.13 -m venv /opt/uvenv && /opt/uvenv/bin/pip install --no-cache-dir uv

RUN git clone --depth 1 --branch "${HERMES_REF}" \
        https://github.com/NousResearch/hermes-agent.git /app/hermes

WORKDIR /app/hermes
# Step 1: dependency closure straight from uv.lock. --frozen uses the lockfile
# as committed rather than re-resolving.
RUN /opt/uvenv/bin/uv sync --frozen --no-install-project --python /usr/sbin/python3.13 ${HERMES_EXTRAS}
# Step 2: the project itself, editable and without touching deps. This is what
# creates .venv/bin/hermes without going near the blocked wheel path.
RUN /opt/uvenv/bin/uv pip install --no-cache-dir --no-deps \
        --python /app/hermes/.venv/bin/python -e "."

# crunchtools addition upstream does not declare.
# uv-created venvs ship no pip, so add it with uv rather than assuming one.
#
# PINNED, and the pin is the fix for seven blocking Trivy findings, not
# housekeeping. Unpinned it resolved to 6.21.2, which carries CVE-2026-119203
# through -119209 (all HIGH, denial of service on crafted PDFs); 6.21.4 fixes
# all seven. This is the one package in the image that is ours rather than
# upstream's -- it is absent from hermes-agent's uv.lock -- so pinning it is
# not a version override of upstream's resolution and the "uv.lock decides
# everything" rule above does not cover it.
#
# Nothing watches this automatically: dependabot.yml tracks the docker and
# github-actions ecosystems only, there being no language manifest here. Bump
# it by hand when Trivy reports the next one.
#
# --exclude-newer-package IS THE POINT OF THIS LINE, so read before removing
# it. This install resolves inside /app/hermes, so it inherits upstream's
# [tool.uv] from their pyproject.toml, and that holds
# `exclude-newer = "14 days"`: a ROLLING supply-chain quarantine on every
# package the resolver can see. 6.21.4 was published 2026-10-28 and the fix
# therefore cannot be resolved at all for fourteen days after that -- the
# reproducibility control and the CVE fix are in direct conflict, and without
# this flag the build fails in resolution rather than at the Trivy gate.
#
# So the quarantine is lifted for pypdf and for nothing else. The global
# cutoff is deliberately untouched: moving it forward would silently
# re-resolve upstream's entire closure for the sake of one package's CVE set.
# This is upstream's own remedy, not an invention -- their
# [tool.uv.exclude-newer-package] table exempts dozens of packages on the
# reasoning that an exact pin gains nothing from the quarantine, because the
# version cannot float without a reviewed bump, while the cutoff can still
# brick the install. `pypdf==` is an exact pin, and the bump was the review.
#
# What it buys: CVE-2026-119203, -119204, -119205 (fixed in 6.21.4) and
# -119206 through -119209 (fixed in 6.21.3). Seven HIGH findings in all.
#
# The exemption is TEMPORARY BY CONSTRUCTION and is not a standing opt-out.
# The window is rolling, so once 6.21.4 is more than fourteen days old -- from
# about 2026-11-11 -- the flag stops doing anything and the pin resolves on its
# own. It earns its keep again only at the next bump, and at that bump the same
# reasoning has to be made again rather than inherited.
#
# The comment lives here because it cannot live next to the cutoff: that is a
# line in a third-party pyproject.toml cloned at build time, and this is the
# place a reader of THIS repo meets it.
ARG PYPDF_VERSION=6.21.4
RUN /opt/uvenv/bin/uv pip install --no-cache-dir \
        --exclude-newer-package "pypdf=false" \
        --python /app/hermes/.venv/bin/python \
        "pypdf==${PYPDF_VERSION}"

# ─── Five pins that DIVERGE from upstream's uv.lock ───────────────────────
#
# READ THIS BEFORE TOUCHING ANY VERSION BELOW. Everything above installs
# hermes-agent exactly as upstream prescribes and lets uv.lock decide every
# version. These five are the deliberate exception and the only one.
#
# Why: from 2026-10-21 the blocking Trivy gate reported 35 HIGH/CRITICAL
# findings in upstream's locked closure, so quay.io/crunchtools/hermes:latest
# stopped publishing altogether and the Kagetora seat on gloval ran a
# three-week-old image (crunchtools/hermes#40). Upstream has shipped no tag
# that resolves clean. Scott ruled on 2026-11-08: upgrade it, do not accept
# it. So these are upgrades, not .trivyignore lines.
#
# What each one buys, against the gate's own report (run 42442873113):
#   pillow  12.3.0    -> 13.0.0      28 findings, 5 CRITICAL -- heap overflow
#     in the TIFF/JPEG/FlashPix decoders and argument injection into the
#     Ghostscript call. REACHABLE, measured, not assumed: the gateway accepts
#     inbound image attachments, upstream's tools/vision_tools.py hands them
#     to PIL.Image.open through _normalize_to_supported_image, and this image
#     installs --extra vision on purpose.
#   aiohttp 3.14.3    -> 3.14.4      3 HIGH -- DoS via a missing initial
#     request timeout and via file-descriptor exhaustion on multipart.
#     REACHABILITY NOT TRACED. aiohttp is in the image because the matrix
#     extra depends on it, and both findings are server-side; whether Hermes
#     ever listens with it was not established. Bumped anyway because the fix
#     is a patch release and establishing it is more work than taking it.
#   yarl    1.22.0    -> 1.25.1      no findings of its own, so reachability
#     does not arise. FORCED: aiohttp 3.14.4 requires yarl>=1.25.1 and
#     upstream locks 1.22.0. Named here so the version is reviewed rather
#     than whatever a resolver reached for.
#   PyJWT   2.13.0    -> 2.14.0      1 HIGH (GHSA-pxh4-856f-4h89) plus the six
#     PyJWT CVEs .trivyignore used to carry. All seven are fixed in 2.14.0,
#     so this bump DELETES ignore lines instead of adding one.
#     REACHABILITY NOT TRACED, and .trivyignore said as much when it accepted
#     these on 2026-10-01: where Hermes verifies a JWT was never established.
#     That was an argument for accepting them; it is not an argument against
#     a one-minor-version bump that ends the question.
#   certifi 2026.5.20 -> 2026.10.18  1 CRITICAL -- bundled emSign roots whose
#     intermediate CA keys were compromised. REACHABLE by construction: this
#     is the trust store every outbound TLS call in the venv validates
#     against, so a bad root is reachable from any of them. Nothing to trace.
#
# --no-deps IS DELIBERATE: it installs exactly these five versions and moves
# nothing else, so the divergence is auditable and cannot quietly grow. The
# cost is that nothing raises a dependency floor for us -- aiohttp 3.14.4
# wants yarl>=1.25.1 where upstream locks 1.22.0, which is the whole reason
# yarl is in this list. That is not left to this comment to get right:
# tests/verify-pins.py runs after the install and asserts both the exact
# versions and every requirement these packages declare, against what is
# actually in the venv. It is handed the same specs, extras included --
# PyJWT[crypto] is upstream's spelling and the extra's own floor
# (cryptography>=3.4.0, locked at 50.0.0) is part of what gets checked. A
# floor missed here fails the build, not the container.
#
# No --exclude-newer-package here, unlike pypdf above: upstream's rolling
# 14-day quarantine is already satisfied. pillow 13.0.0 was published
# 2026-10-16, aiohttp 3.14.4 2026-10-05, yarl 1.25.1 2026-09-15, PyJWT 2.14.0
# 2026-09-11, certifi 2026.10.18 2026-10-18. They only get older, so the
# quarantine never blocks these pins and no exemption is owed.
#
# Nothing watches these. dependabot.yml covers the docker and github-actions
# ecosystems only, there being no language manifest in this repo, so the next
# finding arrives as a red gate. Each pin is to be DROPPED, not bumped, the
# moment upstream's uv.lock reaches the same floor; until then a bump is a
# hand review against the Trivy report.
#
# Left alone on purpose: the anyio / httpcore2 / httpx2 and urllib3 entries
# still in .trivyignore. Those are accepted findings, not blocking ones, and
# widening this block to chase them would widen the divergence without
# unblocking anything.
ARG PILLOW_VERSION=13.0.0
ARG AIOHTTP_VERSION=3.14.4
ARG YARL_VERSION=1.25.1
ARG PYJWT_VERSION=2.14.0
ARG CERTIFI_VERSION=2026.10.18
RUN /opt/uvenv/bin/uv pip install --no-cache-dir --no-deps \
        --python /app/hermes/.venv/bin/python \
        "pillow==${PILLOW_VERSION}" \
        "aiohttp==${AIOHTTP_VERSION}" \
        "yarl==${YARL_VERSION}" \
        "PyJWT[crypto]==${PYJWT_VERSION}" \
        "certifi==${CERTIFI_VERSION}"

# Report what actually landed, and fail the build if the pieces Kagetora cannot
# run without are missing.
# Run the real entry point, not just an import. The previous deploy failed with
# "exec /app/hermes/.venv/bin/hermes: No such file or directory" because the
# venv had been built at a different path -- an import-only test cannot see
# that, because it never invokes the console script.
RUN /app/hermes/.venv/bin/hermes --version

RUN /app/hermes/.venv/bin/python -c "import importlib.metadata as m; \
    import mcp, mautrix, PIL, cryptography, aiohttp, yarl, jwt, certifi, pypdf; \
    print('hermes-agent', m.version('hermes-agent'), '| mcp', m.version('mcp'), \
          '| mautrix', m.version('mautrix'), '| cryptography', cryptography.__version__)"

# The divergence above is only as good as this check. --no-deps installs
# blind, so verify-pins.py asserts both halves of what that block claims: the
# six pins landed at exactly these versions, and every requirement those
# packages declare is satisfied by what is installed. The second half is why
# it is a script and not a comment -- aiohttp 3.14.4's `yarl>=1.25.1` against
# upstream's locked 1.22.0 is caught here whether or not anyone remembered to
# write the floor down, and so is the next one.
COPY tests/verify-pins.py /tmp/verify-pins.py
RUN /app/hermes/.venv/bin/python /tmp/verify-pins.py \
        "pillow==${PILLOW_VERSION}" \
        "aiohttp==${AIOHTTP_VERSION}" \
        "yarl==${YARL_VERSION}" \
        "PyJWT[crypto]==${PYJWT_VERSION}" \
        "certifi==${CERTIFI_VERSION}" \
        "pypdf==${PYPDF_VERSION}" \
    && rm /tmp/verify-pins.py

WORKDIR /build


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
LABEL version="1.0.2"
LABEL description="Hermes Agent autonomous AI agent — crunchtools deployment under the Autonomous Agent constitution profile (Signal messaging, weekly orchestration of crunchtools GHA cascade, ops watchers)."
LABEL org.opencontainers.image.source="https://github.com/crunchtools/hermes"
LABEL org.opencontainers.image.title="hermes"
LABEL org.opencontainers.image.description="Hermes Agent containerized for crunchtools per profiles/autonomous-agent.md"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"
LABEL org.opencontainers.image.vendor="crunchtools"

WORKDIR /app

# Bring in the installed hermes-agent venv, signal-cli, and Node.js
# Editable install: the venv points back at the source tree, so BOTH move.
COPY --from=builder /app/hermes /app/hermes
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
RUN ["/usr/sbin/python3.13", "-c", "import os; os.makedirs('/bin', exist_ok=True); [os.path.exists(p) or os.symlink('/usr/bin/bash', p) for p in ('/bin/sh','/bin/bash')]; [os.path.exists('/usr/bin/'+c) or os.symlink('/usr/bin/coreutils', '/usr/bin/'+c) for c in 'cat echo ls cp mv rm ln chmod chown mkdir rmdir grep head tail wc pwd whoami env id date sleep test true false dirname basename realpath readlink stat printf seq sort uniq tr cut tee touch uname arch hostname timeout'.split()]"]

# This pip is the BASE IMAGE's, not ours and not upstream's: Hummingbird's
# python:3.13 ships pip 26.2 in /usr/local/lib/python3.13/site-packages, which
# is why Trivy files its findings under the aggregate "Python" target with no
# path and no "(METADATA)" marker and why they look like they come from
# nowhere. Measured by walking a pulled image, not inferred.
#
# pip 26.2 vendors certifi 2026.6.17 (GHSA-6q48-6c7w-9gw2, CRITICAL) and
# msgpack 1.1.2 (CVE-2026-114613 and GHSA-6v7p-g79w-8964, both HIGH). pip 26.3
# revendors certifi 2026.10.23 and msgpack 1.2.4 and fixes all three; it
# carries no advisory of its own. Its vendored setuptools is STILL 70.3.0, so
# the two setuptools entries in .trivyignore stay exactly as they are.
#
# Not deleted instead: .trivyignore has recorded since 2026-10-01 that
# removing pip is unsafe because hermes-agent's tools/lazy_deps.py self-heals
# a lean install at runtime. Upgrading is the smaller move, and this line
# should be DROPPED -- not bumped -- as soon as Hummingbird's python:3.13
# ships pip >= 26.3, because then it is pure duplication.
#
# Shell form, and it has to sit after the symlink RUN above: exec form does
# not expand ARGs, and /bin/sh does not exist until that RUN creates it.
ARG PIP_VERSION=26.3
RUN /usr/sbin/python3.13 -m pip install --no-cache-dir --root-user-action=ignore \
        --upgrade "pip==${PIP_VERSION}" && \
    /usr/sbin/python3.13 -c "import pip, sys; sys.exit(0 if pip.__version__ == '${PIP_VERSION}' else 'pip still ' + pip.__version__)"


# The entrypoint wrapper. It starts the same `hermes gateway run` this image
# has always started and adds one readiness line, because this container
# exposes no port and the deploy robot can only verify it by waiting for a
# line in the log. `timeout` is in the coreutils list above for it: it bounds
# each readiness probe. See rootfs/usr/local/bin/hermes-entrypoint.
COPY rootfs/ /
RUN chmod 0755 /usr/local/bin/hermes-entrypoint && \
    bash -n /usr/local/bin/hermes-entrypoint && \
    timeout --help > /dev/null

# Prove the shipped venv actually executes in THIS image. The builder-stage
# check passed while the runtime image was broken, twice: once on a stale
# shebang path, once on a venv bound to a downloaded interpreter that does not
# exist here. Running the entry point after the COPY is the only check that
# sees either.
RUN ["/app/hermes/.venv/bin/hermes", "--version"]

USER 65532

ENV PATH="/app/hermes/.venv/bin:/app/signal-cli/bin:${PATH}" \
    HOME=/app \
    HERMES_CONFIG_DIR=/app/.hermes \
    PYTHONUNBUFFERED=1

EXPOSE 18790

# Start the messaging gateway in unattended mode. Signal channel + bot
# pairing is configured via files under /app/.hermes (bind-mounted).
#
# The wrapper runs `hermes gateway run "$@"`, so a container's arguments are
# appended to the gateway command exactly as the old exec-form ENTRYPOINT
# appended them. Overriding --entrypoint is how you run anything else.
ENTRYPOINT ["/usr/local/bin/hermes-entrypoint"]
