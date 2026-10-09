"""The `cp/1` notification payload: what a Conduit push says once decrypted.

See docs/push/PROTOCOL.md section 2. Servers build the payload, clean the
preview text, and fit it into the largest padding bucket.
"""

from __future__ import annotations

import json
import re
import time
from typing import Any, Dict, Mapping, Optional

from . import webpush

KINDS = ("reply", "reply_failed", "channel", "cron", "test")
SOURCES = ("owui", "hermes")
ID_KEYS = ("chat", "msg", "channel", "session", "turn", "job", "run")
TITLE_LIMIT = 100
BODY_LIMIT = 200
AUTHOR_LIMIT = 64
# A preview is cleaned from at most this many characters. Some of the patterns
# below backtrack on long runs of unclosed markup, and a channel message or a
# reply can be any length, so they never see more than this.
CLEAN_INPUT_LIMIT = 4000
ELLIPSIS = "…"

_BLOCKS = [
    re.compile(r"<details\b[^>]*>.*?</details\s*>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<think\b[^>]*>.*?</think\s*>", re.IGNORECASE | re.DOTALL),
    re.compile(r"<thinking\b[^>]*>.*?</thinking\s*>", re.IGNORECASE | re.DOTALL),
    # A fence left open by a truncated or still-streaming reply runs to the end.
    re.compile(r"(^|\n)[ \t]*(```|~~~).*?(\n[ \t]*\2[ \t]*(?=\n|$)|$)", re.DOTALL),
]
# The start of a block that CLEAN_INPUT_LIMIT cut off before its end.
_OPEN_BLOCK = re.compile(r"<(?:details|think|thinking)\b", re.IGNORECASE)
# Link text can't contain brackets and a target can't contain parentheses,
# except one nested pair as in Wikipedia URLs. That keeps each attempt short,
# so a run of unclosed "[" or "(" takes linear time, not quadratic.
_IMAGE = re.compile(r"!\[([^\[\]]*)\]\([^()]*(?:\([^()]*\)[^()]*)*\)")
_LINK = re.compile(r"\[([^\[\]]+)\]\([^()]*(?:\([^()]*\)[^()]*)*\)")
_TAG = re.compile(r"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>")
_LINE_MARKER = re.compile(r"^[ \t]*(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+|\d+[.)][ \t]+)", re.MULTILINE)
_EMPHASIS = re.compile(r"(\*\*|__|~~|`)")
_SPACE = re.compile(r"\s+")


def clean_text(text: Optional[str]) -> str:
    """Turns a Markdown reply into one line of plain text for a preview.

    Only the first CLEAN_INPUT_LIMIT characters are read. When that cuts the
    text short, a reasoning block it leaves open is dropped to the end, like
    an open code fence, and the result ends in an ellipsis.
    """
    if not text:
        return ""
    cut = len(text) > CLEAN_INPUT_LIMIT
    if cut:
        text = text[:CLEAN_INPUT_LIMIT]
    for pattern in _BLOCKS:
        text = pattern.sub("\n", text)
    if cut:
        opened = _OPEN_BLOCK.search(text)
        if opened:
            text = text[: opened.start()]
    text = _IMAGE.sub(lambda m: m.group(1), text)
    text = _LINK.sub(lambda m: m.group(1), text)
    text = _TAG.sub("", text)
    text = _LINE_MARKER.sub("", text)
    text = _EMPHASIS.sub("", text)
    text = _SPACE.sub(" ", text).strip()
    return text + ELLIPSIS if cut and text else text


def clip(text: Optional[str], limit: int) -> str:
    """Cuts on code points, never inside a UTF-16 pair or UTF-8 sequence."""
    text = _SPACE.sub(" ", text or "").strip()
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + ELLIPSIS


def build(
    kind: str,
    src: str,
    *,
    ids: Mapping[str, Any],
    title: Optional[str],
    body: Optional[str],
    dedup_key: str,
    group: Optional[str] = None,
    author: Optional[str] = None,
    nonce: Optional[str] = None,
    ts: Optional[int] = None,
    clean: bool = True,
) -> Dict[str, Any]:
    if kind not in KINDS:
        raise ValueError(f"unknown kind {kind!r}")
    if src not in SOURCES:
        raise ValueError(f"unknown source {src!r}")
    payload: Dict[str, Any] = {
        "v": 1,
        "k": kind,
        "src": src,
        "ids": {key: str(value) for key, value in ids.items() if key in ID_KEYS and value is not None},
        "t": clip(title, TITLE_LIMIT),
        "b": clip(clean_text(body) if clean else body, BODY_LIMIT),
        "ts": int(ts if ts is not None else time.time()),
        "dk": dedup_key,
    }
    if group:
        payload["g"] = group
    if author:
        payload["a"] = clip(author, AUTHOR_LIMIT)
    if nonce:
        payload["n"] = nonce
    return payload


def encode(payload: Mapping[str, Any]) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def encode_fitting(payload: Dict[str, Any]) -> bytes:
    """Encodes the payload, shortening the preview until it fits the largest bucket.

    Only reachable with very long ids; titles and previews are already capped.
    """
    limit = webpush.BUCKETS[-1] - webpush.TAG_LEN - 1
    data = encode(payload)
    while len(data) > limit and payload.get("b"):
        body = payload["b"]
        payload["b"] = clip(body, len(body) // 2) if len(body) > 1 else ""
        data = encode(payload)
    if len(data) > limit:
        raise webpush.PayloadTooLarge("payload does not fit the largest bucket")
    return data


def seal(payload: Dict[str, Any], subscription: Mapping[str, Any]) -> bytes:
    """Encrypts a payload for one stored subscription (`p256dh`, `auth`)."""
    return webpush.encrypt(
        encode_fitting(dict(payload)),
        webpush.b64u_decode(subscription["p256dh"]),
        webpush.b64u_decode(subscription["auth"]),
    )
