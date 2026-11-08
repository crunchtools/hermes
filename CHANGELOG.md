# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.0] - 2026-11-08

### Security

- **Five packages now pinned above upstream's `uv.lock`, and the base image's
  `pip` bumped, to clear the 35 HIGH/CRITICAL findings that had stopped
  `quay.io/crunchtools/hermes:latest` from publishing since 2026-10-17.** The
  Kagetora seat on gloval ran that three-week-old image the whole time
  (crunchtools/hermes#40). This repo's rule had been that `uv.lock` decides
  every version and whatever CVEs that implies are reported, not fought;
  upstream has shipped no tag that resolves clean, so the rule and a
  publishable image were in direct conflict. Scott ruled on 2026-11-08:
  upgrade it, do not accept it. The divergence is as narrow as the findings
  allow and every pin is a build arg with its reasoning next to it in the
  Containerfile.

  | package | upstream locks | pinned | clears |
  | --- | --- | --- | --- |
  | `pillow` | 12.3.0 | 13.0.0 | 28 findings, 5 CRITICAL |
  | `aiohttp` | 3.14.3 | 3.14.4 | 3 HIGH |
  | `yarl` | 1.22.0 | 1.25.1 | nothing of its own — forced by aiohttp 3.14.4 |
  | `PyJWT` | 2.13.0 | 2.14.0 | 1 HIGH, plus 6 already-accepted |
  | `certifi` | 2026.5.20 | 2026.10.18 | 1 CRITICAL |
  | `pip` (base image) | 26.2 | 26.3 | 1 CRITICAL, 2 HIGH, all vendored |

  Pillow is where the weight is: heap buffer overflows in the TIFF, JPEG and
  FlashPix decoders and argument injection into the Ghostscript call. It is
  also reachable, measured rather than assumed — the gateway accepts inbound
  image attachments, upstream's `tools/vision_tools.py` hands them to
  `PIL.Image.open` through `_normalize_to_supported_image`, and this image
  installs `--extra vision` on purpose. So the usual "not reachable behind
  Trentina" argument does not apply to these; an image sent to Kagetora over
  Matrix is attacker-controlled bytes going into a C decoder.

  `pip` is the odd one out: it is the Hummingbird base image's, not upstream's
  and not ours, which is why Trivy files its findings under the aggregate
  "Python" target with no path and they look like they come from nowhere.
  pip 26.2 vendors certifi 2026.6.17 and msgpack 1.1.2; 26.3 revendors
  certifi 2026.10.23 and msgpack 1.2.4. Drop the bump when Hummingbird ships
  pip >= 26.3.

  The install uses `--no-deps` so it moves exactly these five versions and
  nothing else. The cost is that nothing raises a dependency floor for us,
  which is why `yarl` is on the list at all, so `tests/verify-pins.py` runs
  after the install and asserts both the exact versions and every requirement
  those packages declare — extras included, so `PyJWT[crypto]`'s own
  `cryptography>=3.4.0` is checked too — against what is actually in the venv. A floor a
  comment got wrong now fails the build rather than the container. Unlike
  the `pypdf` pin below it needs no
  `--exclude-newer-package`: every one of these versions is already older than
  upstream's rolling 14-day quarantine and only gets older.

  Each pin is to be **dropped, not bumped**, the moment upstream's `uv.lock`
  reaches the same floor. Nothing watches them — `dependabot.yml` covers the
  docker and github-actions ecosystems only, there being no language manifest
  in this repo — so the next finding arrives as a red gate.

- Seven `.trivyignore` entries deleted, because the upgrades fix them rather
  than hide them: the six PyJWT 2.13.0 findings accepted in 1.0.2
  (CVE-2026-102266, -102267, -102268 CRITICAL, -102271, -102272, -102273) and
  one msgpack 1.1.2 finding (GHSA-6v7p-g79w-8964). The file's header now says
  it is for findings no pin can reach, and names upgrading as the first
  resort.

  Still accepted, deliberately: `anyio` / `httpcore2` / `httpx2`, which the
  `mcp` package pins upstream of upstream, and the two urllib3 2.7.0 findings.
  Those were never blocking the gate, and widening the divergence to chase
  them would have widened it without unblocking anything. `urllib3>=2.8.0` is
  the obvious next candidate.

- `pypdf` pinned to 6.21.4. Unpinned it resolved to 6.21.2, which carries
  CVE-2026-119203 through -119209 (seven HIGH findings, denial of service on
  crafted PDFs); 6.21.4 fixes all seven. `pypdf` is this repo's own addition
  and is absent from hermes-agent's `uv.lock`, so pinning it overrides nothing
  of upstream's resolution. Nothing watches it automatically:
  `dependabot.yml` tracks the docker and github-actions ecosystems only.

  The pin needs `uv pip install --exclude-newer-package pypdf=false`. The
  install resolves inside upstream's project, whose `[tool.uv]` sets
  `exclude-newer = "14 days"`, a rolling supply-chain quarantine; 6.21.4 was
  published 2026-10-28, so without the exception the fix cannot be resolved
  for fourteen days and the build fails in resolution rather than at the
  gate. The quarantine is lifted for `pypdf` alone and the global cutoff is
  untouched, because moving it would silently re-resolve upstream's whole
  closure. Upstream's own `[tool.uv.exclude-newer-package]` table does the
  same for dozens of packages, on the reasoning that an exact pin gains
  nothing from a quarantine it cannot float past. The exemption is temporary
  by construction: the window is rolling, so from about 2026-11-11 the flag
  does nothing and the pin resolves on its own.

  On its own this pin cleared seven of the 42 HIGH/CRITICAL findings the
  blocking scan reported. The other 35 were upstream's `uv.lock` and the base
  image's `pip`, and they are cleared by the pins above rather than by an
  ignore line.

### Added
- `scripts/floating-tag.sh` and `tests/test-floating-tag.sh`. The tag logic
  was inline shell in the build workflow, which means it decided which image a
  `podman-auto-update` host pulls and nothing could test it. Writing the tests
  found a bug in the first draft: `refs/pull/N/head`, which
  `pull_request_target` produces, yielded `pr-N/head` — a slash, so not a
  legal OCI tag at all.
- `tests/verify-pins.py`, run in the build after the diverged pins are
  installed, and `tests/test-verify-pins.py`, run by `ci.yml` against
  synthetic `.dist-info` trees. It asserts the exact versions and every
  requirement the pinned packages declare, which is what makes `--no-deps`
  safe to use. With the repo's first Python files come a `ruff-pre-commit`
  hook and a `pyproject.toml` that holds nothing but `[tool.ruff]` — no
  `[project]`, no `[build-system]`, no dependencies, so it is a linter config
  and not a manifest.
- A readiness line. `/usr/local/bin/hermes-entrypoint` starts the same
  `hermes gateway run` the image has always started, then polls the read-only
  `hermes cron list` until it answers and prints
  `hermes: ready: cron list answered after Ns`. If it never answers within
  `HERMES_READY_TIMEOUT` (default 120s) it prints
  `hermes: gave up: no answer from cron list in Ns` instead, and it stops
  waiting at once if the gateway has already died. The two lines share no
  substring, so a watcher matching `ready:` cannot be satisfied by the
  failure. This container exposes no port, so that line is the only signal
  the crunchtools deploy robot (crunchtools/deployer#17) can verify the
  service by; the banner Hermes prints is printed at launch, which is the
  wrong side of ready.

  It says `ready:` and not `serving:` on purpose. Upstream's
  `hermes_cli/cron.py` at v2026.9.24 serves `cron list` from the local jobs
  store and exits 0 whether or not the scheduler is ready, printing a warning
  when it is not, so there is no exit status here that tells "serving" from
  "forked". What an answer does prove is that the shipped venv's console
  script executes in this image, that `HERMES_CONFIG_DIR` is readable and
  that the jobs store parses, all of it after launch. That is the claim the
  line makes. Refs crunchtools/deployer#17.
- `tests/test-entrypoint.sh`, run by a new `CI` workflow. It exercises the
  entrypoint against a stand-in `hermes` on `PATH`, so no gateway is started:
  ready, ready-late, never-ready, dead-gateway, exit status, TERM forwarding
  and stdin.
- The `anthropic` extra (upstream's pin, `anthropic==0.87.0`). Kagetora moves
  to Claude on the `anthropic_messages` wire through Trentina's
  `/llm/anthropic`, and without the SDK Hermes refuses the request instead of
  falling back.

### Fixed
- Base image back to Hummingbird Python 3.13: hermes-agent requires
  Python <3.14, so the 3.14 bump (#14) broke the image build. Dependabot now
  skips Python 3.14+ until upstream supports it.

### Changed

- `ENTRYPOINT` is `/usr/local/bin/hermes-entrypoint` rather than
  `hermes gateway run` directly. The wrapper runs `hermes gateway run "$@"`, so
  a container's arguments are still appended to the gateway command as the
  exec-form `ENTRYPOINT` appended them; the gateway still gets the container's
  stdin and the runtime's TERM/INT, and the container still ends with the
  gateway's own exit status.
- `timeout` added to the coreutils symlinks, so the entrypoint can bound each
  readiness probe. Each probe is bounded by whatever is left of
  `HERMES_READY_TIMEOUT` as well, so a slow probe cannot push the failure line
  past the timeout a watcher's window is set against.
- **`:latest` is now the newest stable release, not the newest build of the
  default branch** (constitution 1.33.0). A merge to `main` moves `:main`, a
  pull request moves `:pr-N`, a prerelease tag moves only itself, and only a
  `vX.Y.Z` tag moves `:latest`. Each run moves exactly one floating tag,
  computed in the version step, so no code path can move `:latest` by
  accident. `latest` and `pr-*` are reserved names, and so is `main` for
  anything that is not the default branch: `workflow_dispatch` runs from any
  branch, so a branch called `latest` would otherwise have pushed an
  unreleased build straight to the release tag. Prompted by RT#1559 in a
  sibling repo: `:latest` tracking `main` put an unreleased build into
  production through `podman-auto-update`.
- **The build workflow's `paths:` filter is gone, and should not come back.**
  It listed `Containerfile`, `rootfs/**`, `.trivyignore` and the workflow, on
  the reasoning that nothing else can change the image. That is true of the
  image content and false of the thing that matters: the filter also decides
  whether a commit on `main` is built at all, so five merges in a row that
  touched only docs, `CHANGELOG.md` or `.specify/` produced no build and no
  push, and the head of the default branch had no image behind it for three
  weeks. A doc-only rebuild costs five minutes of a runner; a default branch
  whose head was never built costs a stale agent in production. GitHub does
  not evaluate path filters on tag pushes, so only the branch half was ever
  affected. (The earlier half-fix, adding `rootfs/**` to the filter, is
  superseded by removing it.)
- Corrected the README's Composition list, which still described a `pip`
  install from PyPI, a `HERMES_VERSION` build arg, a `python:latest` base and
  a healthcheck. None of those have been true since the image was built
  upstream's way; there is no `HEALTHCHECK` at all.
- Added a v1.18.0 manifest constitution at `.specify/memory/constitution.md`.
- Constitution validation is pinned to the inherited release via
  `.github/workflows/constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.

## [1.0.2] - 2026-10-01

### Security

- Added `.trivyignore` entries for six PyJWT 2.13.0 findings (CVE-2026-102266,
  -102267, -102268 CRITICAL, -102271, -102272, -102273) and two urllib3 2.7.0
  findings (CVE-2026-97687, -97689). They were disclosed after 1.0.1 was
  built and are not introduced by this bump: upstream's `uv.lock` pins the
  same two versions at v2026.8.31, v2026.9.24 and on main, so the 1.0.1 image
  carries them too. No upstream release fixes them yet
  (NousResearch/hermes-agent#128979 is open). Accepted by Scott (2026-10-01)
  as unchanged exposure behind Trentina; remove when upstream's lockfile moves.

### Changed

- Bumped upstream Hermes Agent from v0.21.0 (`v2026.8.31`) to v0.21.5
  (`v2026.9.24`). Only `HERMES_REF` changes; the build method and the extras
  are the same, and upstream's `uv.lock` still decides every dependency.

### Fixed

- Matrix sync no longer stops for good on a transient failure. v0.21.0
  classified a sync error as a permanent auth failure when its message
  contained "401" or "403" anywhere, and a timeout message includes the
  request URL with its numeric `since` token, so an ordinary timeout could
  match and end the sync loop until the next restart. Upstream classifies on
  the structured Matrix error code since v0.21.4.
- Picks up upstream's v0.21.2 session-store fixes: second writers cancelling
  each other's locks, healthy WAL databases reported as corrupt, and
  full-text-index damage failing the whole conversation.

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
