"""The JSON operations Conduit sends to the plugin.

One handler serves both entry points: the gateway's
``POST [/p/<profile>]/api/platforms/conduit/events`` (API server mode) and the
dashboard's ``POST /api/plugins/conduit/v1/events`` (desktop mode). Requests
and responses are JSON objects; errors are ``{"ok": false, "error": "<code>"}``.

    {"op": "hello"}
    {"op": "subscribe", "sub": {sid, did, endpoint, p256dh, auth, events, label, platform, proto}}
    {"op": "unsubscribe", "sid": "..."}
    {"op": "list"}                                  -> {"ok": true, "sids": [...]}
    {"op": "watch", "session_id": "...", "ttl": 3600}
    {"op": "test", "sid": "...", "nonce": "..."}    -> {"ok": true, "push_status": 201}
"""

from __future__ import annotations

import logging
import re
import time
from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Optional
from urllib.parse import urlsplit

from . import PLUGIN_NAME, PROTO, VERSION, sender
from .conduit_webpush import payload as cp
from .conduit_webpush import webpush as wp
from .store import MAX_WATCH_TTL, Store

logger = logging.getLogger(__name__)

_B64U = re.compile(r"^[A-Za-z0-9_-]+$")
_TOKEN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_SESSION = re.compile(r"^[^\s\x00-\x1f]{1,256}$")
MAX_ENDPOINT = 2048
DEFAULT_WATCH_TTL = 3600
SUBSCRIBABLE_EVENTS = ("reply", "reply_failed", "cron")


class OpError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def hello() -> Dict[str, Any]:
    return {"ok": True, "plugin": PLUGIN_NAME, "version": VERSION, "proto": PROTO}


def _b64u_bytes(value: Any, length: int, code: str) -> bytes:
    if not isinstance(value, str) or not _B64U.match(value):
        raise OpError(code)
    try:
        raw = wp.b64u_decode(value)
    except Exception:
        raise OpError(code) from None
    if len(raw) != length:
        raise OpError(code)
    return raw


def _sid(value: Any) -> str:
    if not isinstance(value, str) or len(value) != 22:
        raise OpError("invalid_sid")
    _b64u_bytes(value, 16, "invalid_sid")
    return value


def _text(value: Any, limit: int) -> str:
    return cp.clip(value if isinstance(value, str) else "", limit)


def _validate_subscription(raw: Any) -> Dict[str, Any]:
    if not isinstance(raw, Mapping):
        raise OpError("invalid_subscription")
    sid = _sid(raw.get("sid"))
    did = raw.get("did")
    if not isinstance(did, str) or not _TOKEN.match(did):
        raise OpError("invalid_did")
    endpoint = raw.get("endpoint")
    if not isinstance(endpoint, str) or len(endpoint) > MAX_ENDPOINT:
        raise OpError("invalid_endpoint")
    parts = urlsplit(endpoint)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password:
        raise OpError("invalid_endpoint")
    p256dh = _b64u_bytes(raw.get("p256dh"), 65, "invalid_p256dh")
    try:
        wp._load_public(p256dh)
    except Exception:
        raise OpError("invalid_p256dh") from None
    _b64u_bytes(raw.get("auth"), 16, "invalid_auth")
    proto = raw.get("proto", PROTO)
    if proto != PROTO:
        raise OpError("unsupported_proto")
    events = raw.get("events", list(SUBSCRIBABLE_EVENTS))
    if not isinstance(events, list) or len(events) > 16 or not all(isinstance(e, str) for e in events):
        raise OpError("invalid_events")
    return {
        "sid": sid,
        "did": did,
        "endpoint": endpoint,
        "p256dh": raw["p256dh"],
        "auth": raw["auth"],
        "events": [e for e in dict.fromkeys(events) if e in SUBSCRIBABLE_EVENTS],
        "label": _text(raw.get("label"), 64),
        "platform": _text(raw.get("platform"), 16),
        "proto": PROTO,
    }


def _subscribe(req: Mapping[str, Any], store: Store, now: float) -> Dict[str, Any]:
    store.subscribe(_validate_subscription(req.get("sub")), now)
    return {"ok": True}


def _unsubscribe(req: Mapping[str, Any], store: Store, now: float) -> Dict[str, Any]:
    removed = store.remove([_sid(req.get("sid"))], now)
    return {"ok": True, "removed": bool(removed)}


def _list(req: Mapping[str, Any], store: Store, now: float) -> Dict[str, Any]:
    return {"ok": True, "sids": store.sids(now)}


def _watch(req: Mapping[str, Any], store: Store, now: float) -> Dict[str, Any]:
    session_id = req.get("session_id")
    if not isinstance(session_id, str) or not _SESSION.match(session_id):
        raise OpError("invalid_session_id")
    ttl = req.get("ttl", DEFAULT_WATCH_TTL)
    if isinstance(ttl, bool) or not isinstance(ttl, int) or ttl <= 0:
        raise OpError("invalid_ttl")
    expires = store.watch(session_id, min(ttl, MAX_WATCH_TTL), now)
    return {"ok": True, "expires": expires}


def _test(req: Mapping[str, Any], store: Store, now: float) -> Dict[str, Any]:
    sid = _sid(req.get("sid"))
    nonce = req.get("nonce")
    if not isinstance(nonce, str) or not _TOKEN.match(nonce) or len(nonce) > 64:
        raise OpError("invalid_nonce")
    if store.get(sid, now) is None:
        raise OpError("unknown_sid")
    results = sender.deliver(store.dir.parent, sender.payload_for_test(nonce), only_sid=sid, now=now)
    status = results[0][1] if results else 0
    return {"ok": True, "push_status": status}


_OPS: Dict[str, Callable[[Mapping[str, Any], Store, float], Dict[str, Any]]] = {
    "subscribe": _subscribe,
    "unsubscribe": _unsubscribe,
    "list": _list,
    "watch": _watch,
    "test": _test,
}


def handle(request: Any, home: Path, *, now: Optional[float] = None) -> Dict[str, Any]:
    """Runs one operation for the profile at ``home``. Never raises."""
    if not isinstance(request, Mapping):
        return {"ok": False, "error": "invalid_request"}
    op = request.get("op")
    if op == "hello":
        return hello()
    handler = _OPS.get(op) if isinstance(op, str) else None
    if handler is None:
        return {"ok": False, "error": "unknown_op"}
    try:
        return handler(request, Store(home), time.time() if now is None else now)
    except OpError as error:
        return {"ok": False, "error": error.code}
    except Exception as error:
        logger.warning("conduit push: %s failed (%s)", op, type(error).__name__)
        return {"ok": False, "error": "internal"}
