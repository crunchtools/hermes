#!/usr/bin/env python3
"""Make upstream's LAZY_DEPS pins agree with the versions this image ships.

Why this exists, in one paragraph. hermes-agent's ``tools/lazy_deps.py`` holds
a ``LAZY_DEPS`` table of EXACT pins, and ``is_available(feature)`` compares the
installed version against them. A platform's registry ``check_fn`` is that
call, so a feature whose declared version does not match what is installed is
reported unavailable and its adapter is never created. v1.1.0 pinned aiohttp
3.14.4 over upstream's locked 3.14.3, every other package in the matrix group
was present, and Kagetora came up with no Matrix channel at all: "Platform
'Matrix' requirements not met". The gate is a string comparison, not an import,
so nothing about the image was actually broken -- only its self-description.

Upstream's pins are FLOORS, by their own account. The matrix extra in their
pyproject.toml says "aiohttp 3.14.3: prior CVEs + ... (mautrix/aiohttp-socks
only cap aiohttp<4 / >=3.10, so pin the patched floor directly)", and
``LAZY_DEPS``'s own header calls them "shared patched floors". They are written
as ``==`` because upstream resolves one version and wants exactness about it,
not because a later patch release is incompatible. Measured in the shipped
image rather than assumed: mautrix 0.21.1 requires ``aiohttp<4,>=3`` and
``yarl<2,>=1.5``, aiohttp-socks 0.11.0 requires ``aiohttp>=3.10.0``, and both
import against aiohttp 3.14.4 / yarl 1.25.1.

So this rewrites the version in those literals to the version actually
installed, for exactly the packages the Containerfile's divergence block moved
and nothing else. It is a narrower and more honest divergence than silencing
the CVEs the upgrade fixes: the alternative was to revert aiohttp and add three
.trivyignore entries, which keeps a lie in a different file.

This changes a cloned third-party source file at build time, so it is loud:
every rewrite is printed. It does not fail when a pin is absent from the table
-- certifi, yarl and pypdf are not in it at all -- because the invariant is
checked separately and properly by ``verify-pins.py --lazy-deps``, which fails
the build if any shipped version still violates a LAZY_DEPS spec that names it.

Usage: reconcile-lazy-deps.py path/to/tools/lazy_deps.py NAME==VERSION [...]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from packaging.requirements import InvalidRequirement, Requirement
from packaging.utils import canonicalize_name

USAGE = "usage: reconcile-lazy-deps.py LAZY_DEPS_PY NAME==VERSION [...]"
USAGE_ERROR = 2  # distinct from 1: bad invocation, not a reconciliation that failed
MIN_ARGS = 2  # the target file plus at least one pin

# A quoted requirement literal: "name[extras]==version".
SPEC = re.compile(
    r"""(?P<q>["'])(?P<name>[A-Za-z0-9._-]+)(?P<extras>\[[^\]]*\])?==(?P<ver>[^"']+)(?P=q)"""
)


def parse_pins(argv: list[str]) -> dict[str, str]:
    """``['PyJWT[crypto]==2.14.0']`` to ``{'pyjwt': '2.14.0'}``, keys canonical."""
    pins: dict[str, str] = {}
    for spec in argv:
        try:
            req = Requirement(spec)
        except InvalidRequirement as exc:
            raise ValueError(f"not a requirement: {spec!r} ({exc})") from exc
        clauses = list(req.specifier)
        if len(clauses) != 1 or clauses[0].operator != "==":
            raise ValueError(f"not an exact pin: {spec!r}")
        pins[canonicalize_name(req.name)] = clauses[0].version
    return pins


def reconcile(text: str, pins: dict[str, str]) -> tuple[str, list[str]]:
    """Rewrite matching literals; return the new text and one line per rewrite."""
    rewrites: list[str] = []

    def replace(match: re.Match[str]) -> str:
        name, old = match["name"], match["ver"]
        want = pins.get(canonicalize_name(name))
        if want is None or want == old:
            return match[0]
        extras = match["extras"] or ""
        rewrites.append(f"{name}{extras}=={old} -> {name}{extras}=={want}")
        return f"{match['q']}{name}{extras}=={want}{match['q']}"

    return SPEC.sub(replace, text), rewrites


def main(argv: list[str]) -> int:
    if len(argv) < MIN_ARGS:
        print(USAGE, file=sys.stderr)
        return USAGE_ERROR
    target = Path(argv[0])
    try:
        pins = parse_pins(argv[1:])
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return USAGE_ERROR
    if not target.is_file():
        print(f"not a file: {target}", file=sys.stderr)
        return USAGE_ERROR

    text = target.read_text(encoding="utf-8")
    new_text, rewrites = reconcile(text, pins)
    if not rewrites:
        print(f"{target}: nothing to reconcile; every declared pin already matches")
        return 0
    target.write_text(new_text, encoding="utf-8")
    print(f"{target}: reconciled {len(rewrites)} declared pin(s) to the shipped versions")
    for line in rewrites:
        print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
