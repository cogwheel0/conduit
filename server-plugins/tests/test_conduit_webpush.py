import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from conduit_webpush import payload as cp
from conduit_webpush import webpush as wp

VECTORS = Path(__file__).resolve().parents[2] / "push" / "test-vectors"


def _load(name):
    return json.loads((VECTORS / name).read_text(encoding="utf-8"))


def test_rfc8291_appendix_a():
    v = _load("rfc8291.json")
    u = wp.b64u_decode
    body = wp.encrypt(
        u(v["plaintext"]), u(v["ua_public"]), u(v["auth"]),
        pad=False, as_private=u(v["as_private"]), salt=u(v["salt"]),
    )
    assert wp.b64u_encode(body) == v["body"]
    assert wp.decrypt(body, u(v["ua_private"]), u(v["auth"])) == u(v["plaintext"])


@pytest.mark.parametrize("case", _load("cp1_vectors.json")["cases"], ids=lambda c: c["name"])
def test_cp1_vectors_decrypt(case):
    u = wp.b64u_decode
    body = u(case["body"])
    assert len(body) == wp.HEADER_LEN + case["bucket"]
    assert case["bucket"] in wp.BUCKETS
    plaintext = wp.decrypt(body, u(case["ua_private"]), u(case["auth"]))
    assert plaintext == u(case["plaintext"])
    assert json.loads(plaintext) == case["payload"]
    assert case["topic"] == wp.topic(u(case["auth"]), case["payload"]["dk"])


@pytest.mark.parametrize("name", sorted(_load("cp1_vectors.json")["reject"]["bodies"]))
def test_reject_vectors(name):
    r = _load("cp1_vectors.json")["reject"]
    with pytest.raises(wp.DecryptError):
        wp.decrypt(wp.b64u_decode(r["bodies"][name]), wp.b64u_decode(r["ua_private"]), wp.b64u_decode(r["auth"]))


@pytest.mark.parametrize(
    "size,bucket",
    [(0, 512), (495, 512), (496, 1024), (1007, 1024), (1008, 2048), (2031, 2048)],
)
def test_buckets(size, bucket):
    private = os.urandom(32)
    key = wp.load_private(private)
    auth = os.urandom(16)
    body = wp.encrypt(b"a" * size, wp.public_bytes_of(key), auth)
    assert len(body) == wp.HEADER_LEN + bucket
    assert wp.decrypt(body, private, auth) == b"a" * size


def test_too_large_for_any_bucket():
    key = wp.load_private(os.urandom(32))
    with pytest.raises(wp.PayloadTooLarge):
        wp.encrypt(b"a" * 2032, wp.public_bytes_of(key), os.urandom(16))


def test_fresh_salt_and_key_per_message():
    key = wp.load_private(os.urandom(32))
    auth = os.urandom(16)
    first = wp.encrypt(b"same", wp.public_bytes_of(key), auth)
    second = wp.encrypt(b"same", wp.public_bytes_of(key), auth)
    assert first[:16] != second[:16]
    assert first[21:86] != second[21:86]


def test_rejects_bad_subscription_keys():
    with pytest.raises(ValueError):
        wp.encrypt(b"x", b"\x04" + b"\x00" * 63, os.urandom(16))
    with pytest.raises(ValueError):
        wp.encrypt(b"x", wp.public_bytes_of(wp.load_private(os.urandom(32))), os.urandom(15))


def test_topic_is_short_url_safe_and_keyed():
    auth = b"\x01" * 16
    topic = wp.topic(auth, "chat:a:b")
    assert len(topic) == 22
    assert set(topic) <= set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    assert topic == wp.topic(auth, "chat:a:b")
    assert topic != wp.topic(b"\x02" * 16, "chat:a:b")


def test_headers():
    assert wp.headers("cron", b"\x00" * 16, "cron:j:r")["Urgency"] == "normal"
    assert wp.headers("cron", b"\x00" * 16, "cron:j:r")["TTL"] == "259200"
    reply = wp.headers("reply", b"\x00" * 16, "chat:c:m")
    assert reply["Urgency"] == "high"
    assert reply["TTL"] == "86400"
    assert reply["Content-Encoding"] == "aes128gcm"
    assert wp.headers("test", b"\x00" * 16, "test:n")["TTL"] == "300"


@pytest.mark.parametrize("case", _load("preview_cases.json")["cases"], ids=lambda c: c["name"])
def test_preview_cleaning(case):
    assert cp.clip(cp.clean_text(case["input"]), cp.BODY_LIMIT) == case["expected"]


def test_preview_cleaning_is_bounded():
    for case in _load("preview_cases.json")["cases"]:
        assert len(case["expected"]) <= cp.BODY_LIMIT
        assert "<details" not in case["expected"]
        assert "```" not in case["expected"]


MEGABYTE = 1_000_000
# Far above what linear cleaning takes, far below what the quadratic patterns
# took (25 KB of "[" took 1.3 s).
FAST_ENOUGH_S = 0.25

PATHOLOGICAL = {
    "brackets": "[" * MEGABYTE,
    "images": "![" * (MEGABYTE // 2),
    "link_targets": "[a](" * (MEGABYTE // 4),
    "nested_targets": "[a](x(" * (MEGABYTE // 6),
    "details": "<details>" * (MEGABYTE // 9),
    "tags": "<a " * (MEGABYTE // 3),
    "fences": "\n```" * (MEGABYTE // 4),
    "whitespace": " " * MEGABYTE,
}


def _elapsed(fn, *args):
    start = time.perf_counter()
    fn(*args)
    return time.perf_counter() - start


@pytest.mark.parametrize("name", sorted(PATHOLOGICAL))
def test_preview_cleaning_of_a_huge_input_is_fast(name):
    text = PATHOLOGICAL[name]
    assert _elapsed(lambda: cp.build("reply", "owui", ids={}, title=text, body=text, dedup_key="d")) < FAST_ENOUGH_S


@pytest.mark.parametrize("pattern", ["_IMAGE", "_LINK"])
@pytest.mark.parametrize("name", ["brackets", "images", "link_targets", "nested_targets"])
def test_link_patterns_are_linear_without_the_input_limit(pattern, name):
    assert _elapsed(getattr(cp, pattern).sub, "", PATHOLOGICAL[name]) < FAST_ENOUGH_S


def test_preview_cleaning_reads_only_the_start_of_a_long_text():
    assert cp.clean_text("word " * 2000) == ("word " * 800).strip() + cp.ELLIPSIS
    assert cp.clean_text("x" * cp.CLEAN_INPUT_LIMIT) == "x" * cp.CLEAN_INPUT_LIMIT
    # A reasoning block the limit cuts open is dropped, never shown.
    for tag in ("details", "think", "THINKING"):
        cut_open = "Answer first. <%s>" % tag + "secret reasoning " * 400 + "</%s> More." % tag
        assert cp.clean_text(cut_open) == "Answer first." + cp.ELLIPSIS
    assert cp.clean_text("<think>" + "secret " * 1000) == ""
    # Below the limit an unclosed tag is just markup, as before.
    assert cp.clean_text("Use the <details> element.") == "Use the element."


@pytest.mark.parametrize("text,expected", [
    ("Answer.<think>secret reasoning", "Answer."),
    ("<think>secret reasoning", ""),
    ("<THINKING>plan</THINKING>Visible", "Visible"),
    ("<details><summary>Tool</summary><details>inner</details>secret</details>Visible", "Visible"),
    ('<details type="reasoning" done="false">\n<summary>Thinking…</summary>\nsecret', ""),
    ("<|begin_of_thought|>plan<|end_of_thought|><|begin_of_solution|>Answer<|end_of_solution|>", "Answer"),
    ("◁think▷plan◁/think▷Answer", "Answer"),
    ("A stray </think> close", "A stray close"),
    ("No markup at all", "No markup at all"),
])
def test_strip_hidden_counts_nesting_and_drops_an_open_block(text, expected):
    assert cp.clean_text(cp.strip_hidden(text)) == expected


def test_links_with_parentheses_in_the_target():
    assert cp.clean_text("See [Bracket](https://en.wikipedia.org/wiki/Bracket_(disambiguation)) now") == (
        "See Bracket now"
    )
    assert cp.clean_text('A [titled](https://x.y "Title") link and ![](https://x.y/p.png)') == "A titled link and"


def test_build_validates_and_caps():
    with pytest.raises(ValueError):
        cp.build("poke", "owui", ids={}, title="", body="", dedup_key="x")
    with pytest.raises(ValueError):
        cp.build("reply", "telegram", ids={}, title="", body="", dedup_key="x")
    built = cp.build(
        "channel", "owui", ids={"channel": 9, "msg": None, "user": "drop"},
        title="t" * 300, body="b" * 900, author="a" * 99, dedup_key="channel:9:1", ts=5,
    )
    assert built["ids"] == {"channel": "9"}
    assert len(built["t"]) == cp.TITLE_LIMIT and built["t"].endswith(cp.ELLIPSIS)
    assert len(built["b"]) == cp.BODY_LIMIT
    assert len(built["a"]) == cp.AUTHOR_LIMIT
    assert "g" not in built and "n" not in built


def test_encode_fitting_shortens_preview_only_when_needed():
    huge_ids = {"chat": "c" * 800, "msg": "m" * 800}
    payload = cp.build("reply", "owui", ids=huge_ids, title="T", body="x" * 200, dedup_key="d" * 300)
    data = cp.encode_fitting(payload)
    assert len(data) <= wp.BUCKETS[-1] - wp.TAG_LEN - 1
    assert json.loads(data)["ids"] == huge_ids
    assert len(json.loads(data)["b"]) < 200

    with pytest.raises(wp.PayloadTooLarge):
        cp.encode_fitting(cp.build("reply", "owui", ids={"chat": "c" * 2100}, title="", body="", dedup_key="d"))


def test_seal_roundtrip():
    private = os.urandom(32)
    auth = os.urandom(16)
    subscription = {
        "p256dh": wp.b64u_encode(wp.public_bytes_of(wp.load_private(private))),
        "auth": wp.b64u_encode(auth),
    }
    payload = cp.build("reply", "owui", ids={"chat": "c", "msg": "m"}, title="T", body="B", dedup_key="chat:c:m")
    assert json.loads(wp.decrypt(cp.seal(payload, subscription), private, auth)) == payload


def test_vectors_are_up_to_date():
    result = subprocess.run(
        [sys.executable, str(VECTORS / "generate.py"), "--check"], capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr
