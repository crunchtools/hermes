#!/usr/bin/env python3
"""Tests for tests/verify-pins.py, the guard on the Containerfile's divergence.

verify-pins.py is what makes `uv pip install --no-deps` safe: it is the only
thing that notices a pin that did not land or a dependency floor the comment
got wrong. A guard nobody tests is a guard nobody can trust, so these drive it
against synthetic `.dist-info` trees on PYTHONPATH -- no network, no venv, no
real packages.

Needs `packaging`, which verify-pins.py needs too. Run:  python3 tests/test-verify-pins.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "verify-pins.py"

failures: list[str] = []


def make_site(root: Path, dists: dict[str, tuple[str, list[str]]]) -> Path:
    """Write a fake site-packages: {name: (version, [Requires-Dist lines])}."""
    site = root / "site"
    site.mkdir(parents=True)
    for name, (ver, reqs) in dists.items():
        info = site / f"{name}-{ver}.dist-info"
        info.mkdir()
        lines = ["Metadata-Version: 2.1", f"Name: {name}", f"Version: {ver}"]
        lines += [f"Requires-Dist: {r}" for r in reqs]
        (info / "METADATA").write_text("\n".join(lines) + "\n")
    return site


def make_lazy_deps(root: Path, table: dict[str, tuple[str, ...]]) -> Path:
    """Write a stand-in `tools.lazy_deps` exposing LAZY_DEPS, for --lazy-deps."""
    pkg = root / "lazy" / "tools"
    pkg.mkdir(parents=True)
    (pkg / "__init__.py").write_text("")
    (pkg / "lazy_deps.py").write_text(f"LAZY_DEPS = {table!r}\n")
    return pkg.parent


def run(site: Path, *args: str, extra_path: tuple[Path, ...] = ()) -> subprocess.CompletedProcess:
    # -I so the script cannot pick anything up from the cwd, but then
    # PYTHONPATH is ignored, so pass the fake site-packages via -S-free
    # sys.path injection instead: run a tiny launcher.
    launcher = (
        f"import sys; sys.path.insert(0, {str(site)!r}); "
        f"[sys.path.insert(0, p) for p in {[str(p) for p in extra_path]!r}]; "
        f"sys.argv = ['verify-pins.py', *{list(args)!r}]; "
        f"exec(open({str(SCRIPT)!r}).read())"
    )
    return subprocess.run(
        [sys.executable, "-c", launcher],
        capture_output=True,
        text=True,
    )


def check(label: str, got_code: int, want_code: int, output: str, must_say: str = "") -> None:
    if got_code != want_code:
        failures.append(f"{label}: exit {got_code}, wanted {want_code}\n{output}")
    elif must_say and must_say not in output:
        failures.append(f"{label}: output missing {must_say!r}\n{output}")
    else:
        print(f"  ok  {label}")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        # aiohttp/yarl in miniature: the exact shape the real divergence has.
        clean = make_site(
            root / "clean",
            {
                "aiohttp": ("3.14.4", ["yarl>=1.25.1,<2.0", "attrs>=17.3.0"]),
                "yarl": ("1.25.1", ["idna>=2.0"]),
                "attrs": ("25.4.0", []),
                "idna": ("3.10", []),
            },
        )
        r = run(clean, "aiohttp==3.14.4", "yarl==1.25.1")
        check(
            "exact pins with floors met pass", r.returncode, 0, r.stdout + r.stderr, "pins verified"
        )

        r = run(clean, "aiohttp==3.14.5")
        check(
            "a pin that did not land fails",
            r.returncode,
            1,
            r.stdout + r.stderr,
            "installed 3.14.4, wanted 3.14.5",
        )

        # A name no environment can supply, and hyphen-free so the dist-info
        # directory name is unambiguous: the fake site is PREPENDED to
        # sys.path, so it shadows real packages but does not hide them, and a
        # name like `pillow` would resolve against the host's own install.
        r = run(clean, "hermesfakepackage==1.0.0")
        check("a missing package fails", r.returncode, 1, r.stdout + r.stderr, "not installed")

        # The real break --no-deps causes: aiohttp moved, yarl did not.
        stale = make_site(
            root / "stale",
            {
                "aiohttp": ("3.14.4", ["yarl>=1.25.1,<2.0"]),
                "yarl": ("1.22.0", []),
            },
        )
        r = run(stale, "aiohttp==3.14.4")
        check(
            "an unsatisfied floor fails",
            r.returncode,
            1,
            r.stdout + r.stderr,
            "installed yarl is 1.22.0",
        )

        # `hermesfake*` wherever the test turns on a package being
        # ABSENT. The fake site is prepended to sys.path, so it shadows the
        # host's packages but does not hide them, and a real name like `yarl`
        # or `cryptography` would resolve against whatever the host has.
        missing_dep = make_site(
            root / "missing_dep",
            {"aiohttp": ("3.14.4", ["hermesfakeyarl>=1.25.1"])},
        )
        r = run(missing_dep, "aiohttp==3.14.4")
        check(
            "a required package that is absent fails",
            r.returncode,
            1,
            r.stdout + r.stderr,
            "hermesfakeyarl is not installed",
        )

        # An extra we did not ask for is not a floor we owe, and a marker for
        # another interpreter or platform is not either.
        gated = make_site(
            root / "gated",
            {
                "PyJWT": (
                    "2.14.0",
                    [
                        'hermesfakecrypto>=3.4.0; extra == "crypto"',
                        'typing_extensions>=4.0; python_version < "3.0"',
                    ],
                ),
            },
        )
        r = run(gated, "PyJWT==2.14.0")
        check(
            "unrequested extras and false markers are skipped",
            r.returncode,
            0,
            r.stdout + r.stderr,
            "pins verified",
        )

        # ...but an extra the pin DOES name is in scope. Upstream installs
        # PyJWT[crypto], so skipping it would be the regression that makes the
        # whole floor check decorative.
        r = run(gated, "PyJWT[crypto]==2.14.0")
        check(
            "a named extra's floor is checked",
            r.returncode,
            1,
            r.stdout + r.stderr,
            "hermesfakecrypto is not installed",
        )

        with_extra = make_site(
            root / "with_extra",
            {
                "PyJWT": ("2.14.0", ['hermesfakecrypto>=3.4.0; extra == "crypto"']),
                "hermesfakecrypto": ("50.0.0", []),
            },
        )
        r = run(with_extra, "PyJWT[crypto]==2.14.0")
        check(
            "a named extra that is satisfied passes",
            r.returncode,
            0,
            r.stdout + r.stderr,
            "pins verified",
        )

        # A marker that evaluates TRUE must be enforced, not skipped. Without
        # this case a regression that skipped every marked requirement would
        # still show green.
        true_marker = make_site(
            root / "true_marker",
            {
                "aiohttp": (
                    "3.14.4",
                    [f'yarl>=1.25.1; python_version >= "{sys.version_info[0]}"'],
                ),
                "yarl": ("1.22.0", []),
            },
        )
        r = run(true_marker, "aiohttp==3.14.4")
        check(
            "a marker that applies is enforced",
            r.returncode,
            1,
            r.stdout + r.stderr,
            "installed yarl is 1.22.0",
        )

        # --- check 3: upstream's own LAZY_DEPS gates -------------------------
        # This is the v1.1.0 regression. aiohttp 3.14.4 was installed and
        # correct; upstream's table still declared 3.14.3, so is_available()
        # reported platform.matrix unavailable and Kagetora lost Matrix.
        lazy = make_lazy_deps(
            root / "lazy_bad",
            {
                "platform.matrix": ("mautrix[encryption]==0.21.1", "aiohttp==3.14.3"),
                "tool.vision": ("Pillow==12.3.0",),
            },
        )
        r = run(clean, "--lazy-deps", "aiohttp==3.14.4", extra_path=(lazy,))
        out = r.stdout + r.stderr
        check("a stale LAZY_DEPS pin fails", r.returncode, 1, out, "platform.matrix")
        check("...and says the adapter is skipped", r.returncode, 1, out, "skip its adapter")

        # A feature naming a package we did not pin is none of our business.
        check(
            "...and does not complain about unpinned packages",
            0 if "tool.vision" not in out else 1,
            0,
            out,
        )

        lazy_ok = make_lazy_deps(
            root / "lazy_ok",
            {"platform.matrix": ("mautrix[encryption]==0.21.1", "aiohttp==3.14.4")},
        )
        r = run(clean, "--lazy-deps", "aiohttp==3.14.4", extra_path=(lazy_ok,))
        check(
            "a reconciled LAZY_DEPS pin passes",
            r.returncode,
            0,
            r.stdout + r.stderr,
            "LAZY_DEPS gates agree",
        )

        # Without the flag the table is not consulted at all, so the same
        # stale pin passes -- which is precisely the v1.1.0 build.
        r = run(clean, "aiohttp==3.14.4", extra_path=(lazy,))
        check(
            "without --lazy-deps the stale pin is not seen",
            r.returncode,
            0,
            r.stdout + r.stderr,
            "pins verified",
        )

        # Asking for the check and not being able to run it must NOT pass.
        r = run(clean, "--lazy-deps", "aiohttp==3.14.4")
        check("--lazy-deps with no lazy_deps module fails", r.returncode, 1, r.stdout + r.stderr)

        # 2, not 1: a bad argument is a caller error, distinct from a pin
        # that failed to verify.
        r = run(clean, "aiohttp")
        check(
            "an inexact pin is rejected", r.returncode, 2, r.stdout + r.stderr, "not an exact pin"
        )

        r = run(clean)
        check("no arguments is rejected", r.returncode, 2, r.stdout + r.stderr, "usage:")

    if failures:
        print()
        for f in failures:
            print(f"FAIL {f}")
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nverify-pins.py: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
