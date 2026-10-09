#!/usr/bin/env python3
"""Builds a simulator push from a cp/1 test vector, wrapped as the relay sends it.

    python3 tool/push/make_apns.py > test.apns
    xcrun simctl push booted app.cogwheel.conduit.debug test.apns

Debug builds seed the vectors' debug subscription (sid
Y29uZHVpdC1kZWJ1Zy12MQ), and only the `test` case is encrypted to it, so
`test` is the one that decrypts on the simulator. Every other case keeps the
sid and key it was generated with; the app doesn't know them, so it shows
those as the passive generic notification, which exercises the unknown-sid
path. See docs/push/PROTOCOL.md section 5 for the relay's APNs payload.

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

VECTORS = Path(__file__).resolve().parents[2] / "push" / "test-vectors" / "cp1_vectors.json"


def apns_payload(case: dict, bundle: str) -> dict:
    return {
        "aps": {
            "alert": {"title-loc-key": "push.fallback.title", "loc-key": "push.fallback.body"},
            "mutable-content": 1,
            "sound": "default",
        },
        "cp": {"v": 1, "s": case["sid"], "d": case["body"]},
        "Simulator Target Bundle": bundle,
    }


def main() -> int:
    cases = {case["name"]: case for case in json.loads(VECTORS.read_text(encoding="utf-8"))["cases"]}
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--case", default="test", choices=sorted(cases), help="vector case (default: test)")
    parser.add_argument(
        "--bundle",
        default="app.cogwheel.conduit.debug",
        help="app to deliver to (default: app.cogwheel.conduit.debug)",
    )
    args = parser.parse_args()
    json.dump(apns_payload(cases[args.case], args.bundle), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
