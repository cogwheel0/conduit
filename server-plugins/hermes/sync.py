#!/usr/bin/env python3
"""Copies the shared Web Push library into the Hermes plugin.

The Hermes plugin is published on its own (as the root of the
cogwheel0/conduit-hermes-push mirror), so it carries a verbatim copy of
server-plugins/common/conduit_webpush/*.py in conduit/conduit_webpush/.

    python server-plugins/hermes/sync.py           # refresh the copy
    python server-plugins/hermes/sync.py --check   # exit 1 when it is stale
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, List

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "common" / "conduit_webpush"
TARGET = HERE / "conduit" / "conduit_webpush"


def _sources(source: Path) -> Dict[str, bytes]:
    return {path.name: path.read_bytes() for path in sorted(source.glob("*.py"))}


def stale(source: Path = SOURCE, target: Path = TARGET) -> List[str]:
    """Names of files that are missing, different, or extra in the copy."""
    wanted = _sources(source)
    if not wanted:
        raise SystemExit(f"no Python files in {source}")
    present = {path.name: path.read_bytes() for path in target.glob("*.py")} if target.is_dir() else {}
    names = sorted(set(wanted) | set(present))
    return [name for name in names if wanted.get(name) != present.get(name)]


def sync(source: Path = SOURCE, target: Path = TARGET) -> List[str]:
    """Rewrites the copy; returns the names it changed."""
    changed = stale(source, target)
    wanted = _sources(source)
    target.mkdir(parents=True, exist_ok=True)
    for name in changed:
        if name in wanted:
            (target / name).write_bytes(wanted[name])
        else:
            (target / name).unlink()
    return changed


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if the copy is out of date")
    args = parser.parse_args(argv)
    if args.check:
        names = stale()
        if names:
            print(
                "server-plugins/hermes/conduit/conduit_webpush is out of date: "
                + ", ".join(names)
                + "\nRun: python server-plugins/hermes/sync.py",
                file=sys.stderr,
            )
            return 1
        print("Hermes plugin copy of conduit_webpush is up to date.")
        return 0
    changed = sync()
    print("Updated: " + ", ".join(changed) if changed else "Already up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
