"""Generates the shared Conduit push test vectors.

    python push/test-vectors/generate.py          # rewrite the JSON files
    python push/test-vectors/generate.py --check  # fail if they are stale

Every value is derived from fixed seeds, so the output is reproducible. The
Swift, Kotlin, Rust and Dart test suites read these files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "server-plugins" / "common"))

from conduit_webpush import payload as cp  # noqa: E402
from conduit_webpush import webpush as wp  # noqa: E402

TS = 1760000000


def _seed(label: str, size: int = 32) -> bytes:
    return hashlib.sha256(f"conduit-push-vector:{label}".encode()).digest()[:size]


def _keypair(label: str):
    private = _seed(label)
    return private, wp.public_bytes_of(wp.load_private(private))


def rfc8291() -> dict:
    u = wp.b64u_decode
    inputs = {
        "plaintext": "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24",
        "as_public": "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
        "as_private": "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
        "ua_public": "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
        "ua_private": "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
        "salt": "DGv6ra1nlYgDCS1FRnbzlw",
        "auth": "BTBZMqHH6r4Tts7J_aSIgg",
    }
    # RFC 8291 Appendix A: the 86-octet header followed by the ciphertext.
    expected = wp.b64u_decode(
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml"
        "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
    ) + wp.b64u_decode(
        "8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ"
    )
    produced = wp.encrypt(
        u(inputs["plaintext"]),
        u(inputs["ua_public"]),
        u(inputs["auth"]),
        pad=False,
        as_private=u(inputs["as_private"]),
        salt=u(inputs["salt"]),
    )
    # Explicit raises, not assert, so `python -O` can't skip a check.
    if produced != expected:
        raise AssertionError("Python Web Push does not match RFC 8291 Appendix A")
    return {
        "description": "RFC 8291 Appendix A. Unpadded, so it only checks the key schedule and AES-GCM.",
        **inputs,
        "body": wp.b64u_encode(expected),
    }


DEBUG_SID = wp.b64u_encode(b"conduit-debug-v1")


def _case(name, sid_label, scope, payload_obj, *, sid=None):
    ua_private, ua_public = _keypair(f"{name}:ua")
    auth = _seed(f"{name}:auth", 16)
    as_private = _seed(f"{name}:as")
    salt = _seed(f"{name}:salt", 16)
    plaintext = cp.encode_fitting(payload_obj)
    body = wp.encrypt(plaintext, ua_public, auth, as_private=as_private, salt=salt)
    if wp.decrypt(body, ua_private, auth) != plaintext:
        raise AssertionError(f"vector {name} does not decrypt to its plaintext")
    return {
        "name": name,
        "sid": sid or wp.b64u_encode(_seed(f"{sid_label}:sid", 16)),
        "scope": scope,
        "ua_private": wp.b64u_encode(ua_private),
        "ua_public": wp.b64u_encode(ua_public),
        "auth": wp.b64u_encode(auth),
        "as_private": wp.b64u_encode(as_private),
        "salt": wp.b64u_encode(salt),
        "payload": json.loads(plaintext.decode("utf-8")),
        "plaintext": wp.b64u_encode(plaintext),
        "body": wp.b64u_encode(body),
        "bucket": len(body) - wp.HEADER_LEN,
        "app_dedup_key": f"{scope}|{payload_obj['dk']}",
        "topic": wp.topic(auth, payload_obj["dk"]),
    }


def cp1() -> dict:
    cases = [
        _case(
            "owui_reply",
            "owui_reply",
            "owui:acct-1",
            cp.build(
                "reply", "owui",
                ids={"chat": "4f1c2a7e", "msg": "b9d0e3f1"},
                title="Trip ideas",
                body="<details type=\"reasoning\">\n<summary>Thought</summary>\n> hmm\n</details>\n"
                "Here are **three** routes along the [coast](https://example.com):",
                dedup_key="chat:4f1c2a7e:b9d0e3f1", group="chat:4f1c2a7e", ts=TS,
            ),
        ),
        _case(
            "owui_reply_failed",
            "owui_reply",
            "owui:acct-1",
            cp.build(
                "reply_failed", "owui",
                ids={"chat": "4f1c2a7e", "msg": "c0ffee00"},
                title="Trip ideas", body="",
                dedup_key="chat:4f1c2a7e:c0ffee00", group="chat:4f1c2a7e", ts=TS,
            ),
        ),
        _case(
            "owui_channel_unicode",
            "owui_channel",
            "owui:acct-2",
            cp.build(
                "channel", "owui",
                ids={"channel": "ch-9", "msg": "m-42"},
                title="#général", body="Réunion à 15 h 🗓️ — 会议改到下午三点",
                author="Zoë 🦊", dedup_key="channel:ch-9:m-42", group="channel:ch-9", ts=TS,
            ),
        ),
        _case(
            "hermes_reply",
            "hermes",
            "hermes:5d3e8c1a-0b7f-4c2e-9a6d-1f2e3d4c5b6a",
            cp.build(
                "reply", "hermes",
                ids={"session": "20261010_101500_ab12cd", "turn": "t-7"},
                title="Refactor plan", body="Done. I split the parser into three modules and the tests pass.",
                dedup_key="hermes:20261010_101500_ab12cd:t-7",
                group="hermes:20261010_101500_ab12cd", ts=TS,
            ),
        ),
        _case(
            "hermes_cron",
            "hermes",
            "hermes:5d3e8c1a-0b7f-4c2e-9a6d-1f2e3d4c5b6a",
            cp.build(
                "cron", "hermes",
                ids={"job": "a1b2c3d4e5f6", "run": "1760000000"},
                title="Morning briefing", body="3 new issues, 1 failing build on main.",
                dedup_key="cron:a1b2c3d4e5f6:1760000000", group="cron:a1b2c3d4e5f6", ts=TS,
            ),
        ),
        _case(
            "test",
            "debug",
            "owui:acct-1",
            cp.build(
                "test", "owui", ids={}, title="", body="",
                dedup_key="test:Nn3wq0Xk", nonce="Nn3wq0Xk", ts=TS,
            ),
            sid=DEBUG_SID,
        ),
        _case(
            "middle_bucket",
            "owui_reply",
            "owui:acct-1",
            cp.build(
                "reply", "owui",
                ids={"chat": "4f1c2a7e", "msg": "d00dfeed"},
                title="Long title " * 9, body="会议" * 100,
                dedup_key="chat:4f1c2a7e:d00dfeed", group="chat:4f1c2a7e", ts=TS,
            ),
        ),
        _case(
            "largest_bucket",
            "owui_reply",
            "owui:acct-1",
            cp.build(
                "reply", "owui",
                ids={"chat": "c" * 36, "msg": "m" * 36},
                title="🦊" * 120, body="会议" * 150,
                dedup_key="chat:%s:%s" % ("c" * 36, "m" * 36), group="chat:" + "c" * 36, ts=TS,
            ),
        ),
    ]
    debug_private, debug_public = _keypair("test:ua")
    return {
        "description": "cp/1 payloads encrypted with fixed keys. Decrypt `body` with `ua_private` and `auth`; "
        "the result must equal `plaintext` byte for byte.",
        "debug_subscription": {
            "description": "Seeded into debug builds so `xcrun simctl push` fixtures decrypt.",
            "sid": DEBUG_SID,
            "ua_private": wp.b64u_encode(debug_private),
            "ua_public": wp.b64u_encode(debug_public),
            "auth": wp.b64u_encode(_seed("test:auth", 16)),
        },
        "cases": cases,
        "reject": _rejects(),
        "payload_reject": [
            {"name": "version_2", "plaintext": '{"v":2,"k":"reply","src":"owui","ids":{},"t":"","b":"","ts":1,"dk":"x"}'},
            {"name": "unknown_kind", "plaintext": '{"v":1,"k":"poke","src":"owui","ids":{},"t":"","b":"","ts":1,"dk":"x"}'},
            {"name": "missing_dk", "plaintext": '{"v":1,"k":"reply","src":"owui","ids":{},"t":"","b":"","ts":1}'},
            {"name": "not_an_object", "plaintext": '["v",1]'},
            {"name": "not_json", "plaintext": "hello"},
        ],
    }


def _rejects():
    ua_private, ua_public = _keypair("reject:ua")
    auth = _seed("reject:auth", 16)
    other_auth = _seed("reject:other-auth", 16)
    as_private = _seed("reject:as")
    salt = _seed("reject:salt", 16)
    text = b'{"v":1}'

    def enc(**kw):
        return wp.encrypt(text, ua_public, kw.pop("auth", auth), as_private=as_private, salt=salt, **kw)

    good = enc()
    bad_idlen = bytearray(good)
    bad_idlen[20] = 64
    small_rs = bytearray(good)
    small_rs[16:20] = (17).to_bytes(4, "big")
    cases = {
        "wrong_auth": enc(auth=other_auth),
        "not_last_record_delimiter": enc(_delimiter=0x01),
        "keyid_not_65": bytes(bad_idlen),
        "record_size_too_small": bytes(small_rs),
        "truncated": good[:-1],
        "flipped_tag_bit": good[:-1] + bytes([good[-1] ^ 0x01]),
        "too_large": wp.encrypt(b"x" * 2100, ua_public, auth, pad=False, as_private=as_private, salt=salt),
    }
    for name, body in cases.items():
        try:
            wp.decrypt(body, ua_private, auth)
        except wp.DecryptError:
            continue
        raise AssertionError(f"reject vector {name} decrypted")
    return {
        "description": "Every body must be rejected when decrypted with this key and auth secret.",
        "ua_private": wp.b64u_encode(ua_private),
        "ua_public": wp.b64u_encode(ua_public),
        "auth": wp.b64u_encode(auth),
        "bodies": {name: wp.b64u_encode(body) for name, body in cases.items()},
    }


def preview_cases() -> dict:
    # Every expected preview is written by hand. Computing it with the cleaner
    # under test would let a regeneration approve a cleaning bug.
    cases = [
        ("plain", "Hello there", "Hello there"),
        (
            "reasoning_block",
            '<details type="reasoning" done="true">\n<summary>Thought for 3 seconds</summary>\n> plan\n</details>\nThe answer is 42.',
            "The answer is 42.",
        ),
        ("think_tags", "<think>internal</think>Visible answer", "Visible answer"),
        (
            "markdown",
            "# Title\n\n- **Bold** item\n- [link](https://x.y) and ![pic](https://x.y/p.png)\n> quoted `code`",
            "Title Bold item link and pic quoted code",
        ),
        ("fenced_code", "Run this:\n```bash\nrm -rf /tmp/x\n```\nThen restart.", "Run this: Then restart."),
        ("open_fence", "Here you go:\n```python\nprint('unterminated')", "Here you go:"),
        ("long", "word " * 80, ("word " * 40).strip() + "…"),
        ("emoji_cut", "🦊" * 250, "🦊" * 199 + "…"),
        ("html", "a <b>bold</b> move, and 3 < 4 > 2", "a bold move, and 3 < 4 > 2"),
        ("empty", "", ""),
    ]
    for name, text, expected in cases:
        cleaned = cp.clip(cp.clean_text(text), cp.BODY_LIMIT)
        if cleaned != expected:
            raise AssertionError(f"preview case {name}: cleaned to {cleaned!r}, expected {expected!r}")
    return {
        "description": "Preview cleaning: clip(clean_text(input), 200).",
        "cases": [{"name": name, "input": text, "expected": expected} for name, text, expected in cases],
    }


FILES = {
    "rfc8291.json": rfc8291,
    "cp1_vectors.json": cp1,
    "preview_cases.json": preview_cases,
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for filename, build in FILES.items():
        text = json.dumps(build(), ensure_ascii=False, indent=2) + "\n"
        path = HERE / filename
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(filename)
        else:
            path.write_text(text, encoding="utf-8")
    if stale:
        print("Stale test vectors: " + ", ".join(stale) + ". Run python push/test-vectors/generate.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
