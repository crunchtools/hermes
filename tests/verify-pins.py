#!/usr/bin/env python3
"""Verify the Containerfile's diverged security pins, inside the built venv.

Three checks. The second and third are the ones that earn their keep.

1. Every pin named on the command line is installed at exactly that version.
   ``uv pip install --no-deps`` installs blind, so a skipped or substituted
   wheel would otherwise ship and surface only when Kagetora imports it.

2. Every runtime requirement declared *by* those packages is satisfied by what
   is actually installed. ``--no-deps`` means nothing raised the floors for
   us, so aiohttp 3.14.4's ``yarl>=1.25.1`` against upstream's locked yarl
   1.22.0 is exactly the break this catches -- and it catches the next one
   without anyone remembering to write it down. The Containerfile's comment
   claims those floors were checked; this is what makes the claim testable.

Deliberately NOT a whole-closure check. hermes-agent's own metadata pins
``Pillow==12.3.0``, so verifying every installed distribution would fail on
the divergence itself. The pinned packages' forward requirements are the part
that has to hold.

3. With ``--lazy-deps``: no shipped version violates a pin that upstream's own
   ``LAZY_DEPS`` table declares for it. That table is not packaging metadata --
   ``tools.lazy_deps.is_available(feature)`` compares against it at runtime and
   a platform's registry ``check_fn`` is that call, so a version the table does
   not expect makes the feature report itself unavailable and its adapter is
   never created. v1.1.0 shipped aiohttp 3.14.4 against a declared
   ``aiohttp==3.14.3`` and Kagetora came up with no Matrix channel. Checks 1
   and 2 both passed that build, which is exactly why this third one exists.

A pin may name its extras, and they are part of the contract: upstream
installs ``PyJWT[crypto]``, so ``PyJWT[crypto]==2.14.0`` checks the ``crypto``
extra's floors too. Extras nobody asked for are skipped, because an extra that
is not installed is not a floor we owe.

Needs ``packaging``, which upstream's own closure pins.

Usage: verify-pins.py [--lazy-deps] NAME[extras]==VERSION [...]
"""

from __future__ import annotations

import sys
from importlib.metadata import PackageNotFoundError, requires, version

from packaging.requirements import InvalidRequirement, Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version

USAGE = "usage: verify-pins.py [--lazy-deps] NAME[extras]==VERSION [...]"


def installed(name: str) -> str | None:
    """Installed version of ``name``, or None when it is absent."""
    try:
        return version(name)
    except PackageNotFoundError:
        return None


def parse_pin(spec: str) -> tuple[str, str, frozenset[str]]:
    """``'PyJWT[crypto]==2.14.0'`` to ``('PyJWT', '2.14.0', {'crypto'})``."""
    try:
        req = Requirement(spec)
    except InvalidRequirement as exc:
        raise ValueError(f"not a requirement: {spec!r} ({exc})") from exc
    clauses = list(req.specifier)
    if len(clauses) != 1 or clauses[0].operator != "==" or req.marker is not None:
        raise ValueError(f"not an exact pin: {spec!r}")
    return req.name, clauses[0].version, frozenset(req.extras)


def wrong_versions(pins: dict[str, tuple[str, frozenset[str]]]) -> list[str]:
    """Pins that are absent or installed at some other version."""
    problems = []
    for name, (want, _) in sorted(pins.items()):
        got = installed(name)
        if got is None:
            problems.append(f"{name}: not installed, wanted {want}")
        elif Version(got) != Version(want):
            problems.append(f"{name}: installed {got}, wanted {want}")
    return problems


def unmet_floors(name: str, extras: frozenset[str]) -> list[str]:
    """Requirements ``name`` declares that what is installed does not satisfy.

    A requirement is in scope if its marker holds with no extra or under one of
    the pin's own extras. The empty string is passed explicitly because an
    extra-gated marker raises UndefinedEnvironmentName otherwise.
    """
    contexts = [{"extra": ""}] + [{"extra": extra} for extra in sorted(extras)]
    problems = []
    for raw in requires(name) or ():
        req = Requirement(raw)
        if req.marker is not None and not any(req.marker.evaluate(c) for c in contexts):
            continue
        got = installed(req.name)
        if got is None:
            problems.append(f"{name} needs {raw!r}: {req.name} is not installed")
        elif not req.specifier.contains(got, prereleases=True):
            problems.append(f"{name} needs {raw!r}: installed {req.name} is {got}")
    return problems


def lazy_deps_conflicts(pins: dict[str, tuple[str, frozenset[str]]]) -> list[str]:
    """LAZY_DEPS specs naming a pinned package that the shipped version fails.

    Imports upstream's table, so a caller that asks for this check and cannot
    reach it gets an error rather than a silent pass -- a skipped check here is
    how a dead Matrix channel shipped.
    """
    from tools.lazy_deps import LAZY_DEPS

    wanted = {canonicalize_name(name) for name in pins}
    problems = []
    for feature, specs in sorted(LAZY_DEPS.items()):
        for raw in specs:
            req = Requirement(raw)
            if canonicalize_name(req.name) not in wanted:
                continue
            got = installed(req.name)
            if got is None:
                problems.append(
                    f"LAZY_DEPS[{feature!r}] declares {raw!r}: {req.name} is not installed"
                )
            elif not req.specifier.contains(got, prereleases=True):
                problems.append(
                    f"LAZY_DEPS[{feature!r}] declares {raw!r} but {req.name} is {got} -- "
                    f"upstream will report feature {feature!r} unavailable and skip its adapter"
                )
    return problems


def main(argv: list[str]) -> int:
    check_lazy = "--lazy-deps" in argv
    argv = [a for a in argv if a != "--lazy-deps"]
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    pins: dict[str, tuple[str, frozenset[str]]] = {}
    for spec in argv:
        try:
            name, want, extras = parse_pin(spec)
        except ValueError as exc:
            print(exc, file=sys.stderr)
            return 2
        pins[name] = (want, extras)

    problems = wrong_versions(pins)
    for name, (_, extras) in sorted(pins.items()):
        if installed(name) is not None:
            problems += unmet_floors(name, extras)
    if check_lazy:
        problems += lazy_deps_conflicts(pins)

    for name in sorted(pins):
        print(f"  {name}=={installed(name)}")

    if problems:
        print()
        for problem in problems:
            print(f"FAIL {problem}")
        print(f"{len(problems)} problem(s) with the diverged security pins", file=sys.stderr)
        return 1

    tail = ", upstream's LAZY_DEPS gates agree" if check_lazy else ""
    print(f"pins verified: versions exact, declared floors satisfied{tail}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
