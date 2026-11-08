#!/usr/bin/env python3
"""Tests for scripts/reconcile-lazy-deps.py.

That script edits a cloned third-party source file at image-build time. If it
rewrites too little, Matrix stays dead (the v1.1.0 outage). If it rewrites too
much, it changes upstream pins nobody reviewed. Both directions are driven
here, against the real shape of upstream's table rather than a toy string.

Run:  python3 tests/test-reconcile-lazy-deps.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "reconcile-lazy-deps.py"

# Trimmed from hermes-agent v2026.9.24 tools/lazy_deps.py, spellings intact:
# `Pillow` capitalised, `aiohttp` repeated across features, extras in specs.
SAMPLE = """LAZY_DEPS: dict[str, tuple[str, ...]] = {
    "provider.anthropic": ("anthropic==0.87.0",),
    "platform.discord": (
        "discord.py[voice]==2.7.1",
        "aiohttp==3.14.3",
    ),
    "platform.matrix": (
        "mautrix[encryption]==0.21.1",
        "aiohttp-socks==0.11.0",
        "aiohttp==3.14.3",
    ),
    "tool.vision": ("Pillow==12.3.0",),
    "tool.computer_use": ("mcp==2.0.0", "httpx2==2.7.0"),
}
"""

USAGE_ERROR = 2  # reconcile-lazy-deps.py's exit code for a bad invocation
AIOHTTP_OCCURRENCES = 2  # platform.discord and platform.matrix in SAMPLE
EXPECTED_REWRITES = 3  # two aiohttp, one Pillow

failures: list[str] = []


def run(target: Path, *pins: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-I", str(SCRIPT), str(target), *pins],
        capture_output=True,
        text=True,
    )


def check(label: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok  {label}")
    else:
        print(f"  FAIL {label}")
        failures.append(f"{label}\n{detail}")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        # The outage: aiohttp moved, upstream's table did not.
        target = root / "lazy_deps.py"
        target.write_text(SAMPLE)
        r = run(target, "aiohttp==3.14.4", "pillow==13.0.0")
        text = target.read_text()
        check("exits 0", r.returncode == 0, r.stdout + r.stderr)
        check(
            "rewrites every aiohttp occurrence",
            text.count('"aiohttp==3.14.4"') == AIOHTTP_OCCURRENCES
            and '"aiohttp==3.14.3"' not in text,
            text,
        )
        check(
            "matches the name case-insensitively and keeps upstream's spelling",
            '"Pillow==13.0.0"' in text,
            text,
        )
        check("reports each rewrite", r.stdout.count("->") == EXPECTED_REWRITES, r.stdout)

        # Must not touch a package nobody asked it to touch, and must not be
        # fooled by a similar name: `aiohttp-socks` is not `aiohttp`.
        check("leaves aiohttp-socks alone", '"aiohttp-socks==0.11.0"' in text, text)
        check(
            "leaves unrelated pins alone",
            '"mcp==2.0.0"' in text and '"httpx2==2.7.0"' in text,
            text,
        )
        check("leaves extras specs alone", '"discord.py[voice]==2.7.1"' in text, text)
        check(
            "preserves the rest of the file byte for byte",
            text.replace('"aiohttp==3.14.4"', '"aiohttp==3.14.3"').replace(
                '"Pillow==13.0.0"', '"Pillow==12.3.0"'
            )
            == SAMPLE,
            text,
        )

        # An extras-bearing pin names the same distribution.
        target2 = root / "b.py"
        target2.write_text('X = ("mautrix[encryption]==0.21.1",)\n')
        r = run(target2, "mautrix[encryption]==0.22.0")
        check(
            "an extras-bearing pin rewrites the extras-bearing literal",
            '"mautrix[encryption]==0.22.0"' in target2.read_text(),
            target2.read_text(),
        )

        # Idempotent: running it twice changes nothing the second time.
        before = target.read_text()
        r = run(target, "aiohttp==3.14.4", "pillow==13.0.0")
        check("is idempotent", target.read_text() == before and r.returncode == 0, r.stdout)
        check("says so when there is nothing to do", "nothing to reconcile" in r.stdout, r.stdout)

        # A pin absent from the table is not an error: certifi, yarl and pypdf
        # are not in LAZY_DEPS at all. verify-pins --lazy-deps owns the
        # invariant; this script only edits.
        r = run(target, "certifi==2026.10.18")
        check("a pin absent from the table is not an error", r.returncode == 0, r.stdout + r.stderr)

        # Bad input is refused rather than guessed at.
        r = run(target, "aiohttp")
        check("an inexact pin is refused", r.returncode == USAGE_ERROR, r.stdout + r.stderr)
        r = run(target, "aiohttp>=3.14.4")
        check("a range is refused", r.returncode == USAGE_ERROR, r.stdout + r.stderr)
        r = run(root / "nope.py", "aiohttp==3.14.4")
        check("a missing file is refused", r.returncode == USAGE_ERROR, r.stdout + r.stderr)
        r = run(target)
        check("no pins is refused", r.returncode == USAGE_ERROR, r.stdout + r.stderr)

    print()
    if failures:
        for f in failures:
            print(f"FAIL {f}")
        print(f"{len(failures)} failure(s)")
        return 1
    print("reconcile-lazy-deps.py: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
