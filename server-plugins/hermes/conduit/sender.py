"""Builds Conduit push payloads and sends them to every subscribed device.

Each push is sealed to one device's key (``conduit_webpush.payload.seal``) and
POSTed to its Web Push endpoint with ``conduit_webpush.webpush.headers``. A
404 or 410 means the subscription is dead and it is deleted. Nothing here
raises into Hermes, and logs carry only counts and categories: never
endpoints, keys, ids or text.
"""

from __future__ import annotations

import logging
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Tuple
from urllib.parse import urlsplit

import httpx

from .conduit_webpush import payload as cp
from .conduit_webpush import webpush as wp
from .store import Store

logger = logging.getLogger(__name__)

SOURCE = "hermes"
DEFAULT_EVENTS = ("reply", "reply_failed", "cron")
TIMEOUT_SECONDS = 10.0
DEAD_STATUSES = (404, 410)
# Test hook: an ``httpx`` transport used instead of the network.
HTTP_TRANSPORT: Optional[Any] = None

# httpx logs every request URL at INFO, and a push endpoint's path is the
# device's delivery capability. While this thread sends a push, records from
# httpx and httpcore are dropped. The flag lives on the thread so the filter
# works for every copy of this module (the agent plugin and the dashboard
# routes import it separately).
_QUIET_FLAG = "conduit_push_quiet"
_QUIET_LOGGERS = ("httpx", "httpcore.connection", "httpcore.http11", "httpcore.http2", "httpcore.proxy")


class _QuietWhileSending(logging.Filter):
    conduit_push_quiet_filter = True

    def filter(self, record: logging.LogRecord) -> bool:
        return not getattr(threading.current_thread(), _QUIET_FLAG, False)


for _name in _QUIET_LOGGERS:
    _logger = logging.getLogger(_name)
    if not any(getattr(f, "conduit_push_quiet_filter", False) for f in _logger.filters):
        _logger.addFilter(_QuietWhileSending())


@contextmanager
def _quiet() -> Iterator[None]:
    thread = threading.current_thread()
    previous = getattr(thread, _QUIET_FLAG, False)
    setattr(thread, _QUIET_FLAG, True)
    try:
        yield
    finally:
        setattr(thread, _QUIET_FLAG, previous)


# -- payloads -----------------------------------------------------------------

def _preview(text: Any) -> str:
    """Plain-text preview of a reply or job output.

    Reasoning blocks are dropped, including nested ones and one an
    interrupted turn left open. Only the first ``cp.CLEAN_INPUT_LIMIT``
    characters are read, so a long reply can't stall the patterns.
    """
    text = text if isinstance(text, str) else ""
    cut = len(text) > cp.CLEAN_INPUT_LIMIT
    if cut:
        text = text[: cp.CLEAN_INPUT_LIMIT]
    text = cp.clean_text(cp.strip_hidden(text))
    return text + cp.ELLIPSIS if cut and text else text


def reply_payload(kind: str, session_id: str, turn_id: str, title: str, body: str) -> Dict[str, Any]:
    return cp.build(
        kind, SOURCE,
        ids={"session": session_id, "turn": turn_id},
        title=title, body=_preview(body),
        dedup_key=f"hermes:{session_id}:{turn_id}",
        group=f"hermes:{session_id}",
        clean=False,
    )


def cron_payload(job_id: str, run_id: str, title: str, body: str) -> Dict[str, Any]:
    """A ``cron`` push. Text that names no job, such as the agent's
    ``send_message`` or unwrapped output from Hermes's standalone lane, which
    passes no job id, carries no ``job`` id at all rather than an empty one."""
    return cp.build(
        "cron", SOURCE,
        ids={"job": job_id or None, "run": run_id},
        title=title, body=_preview(body),
        dedup_key=f"cron:{job_id}:{run_id}",
        group=f"cron:{job_id}",
        clean=False,
    )


def payload_for_test(nonce: str) -> Dict[str, Any]:
    return cp.build("test", SOURCE, ids={}, title="", body="", dedup_key=f"test:{nonce}", nonce=nonce)


# -- sending ------------------------------------------------------------------

def _wants(sub: Dict[str, Any], kind: str) -> bool:
    events = sub.get("events")
    if events is None:
        return kind in DEFAULT_EVENTS
    return isinstance(events, list) and kind in events


def post(sub: Dict[str, Any], push: Dict[str, Any]) -> int:
    """Sends one sealed push. Returns the HTTP status, or 0 when nothing was answered."""
    endpoint = str(sub.get("endpoint") or "")
    if urlsplit(endpoint).scheme != "https":
        logger.warning("conduit push: skipped a subscription with a non-https endpoint")
        return 0
    try:
        body = cp.seal(push, sub)
        headers = wp.headers(push["k"], wp.b64u_decode(sub["auth"]), push["dk"])
    except Exception as error:  # bad stored keys, or a payload that cannot fit
        logger.warning("conduit push: could not seal a push (%s)", type(error).__name__)
        return 0
    try:
        with _quiet(), httpx.Client(
            timeout=TIMEOUT_SECONDS, follow_redirects=False, transport=HTTP_TRANSPORT,
        ) as client:
            return client.post(endpoint, content=body, headers=headers).status_code
    except Exception as error:
        logger.info("conduit push: delivery attempt failed (%s)", type(error).__name__)
        return 0


def deliver(
    home: Path, push: Dict[str, Any], *, only_sid: Optional[str] = None, now: Optional[float] = None,
) -> List[Tuple[str, int]]:
    """Sends ``push`` to every subscription that wants its kind (or just ``only_sid``).

    Returns ``(sid, status)`` pairs and deletes the subscriptions whose
    endpoint answered 404/410, by ``(sid, endpoint)``.
    """
    store = Store(home)
    now = time.time() if now is None else now
    kind = push.get("k", "")
    subs = store.subscriptions(now)
    if only_sid is not None:
        targets = [s for s in subs if s.get("sid") == only_sid]
    else:
        targets = [s for s in subs if _wants(s, kind)]
    answers = [(s, post(s, push)) for s in targets]
    dead = [(s.get("sid"), s.get("endpoint")) for s, status in answers if status in DEAD_STATUSES]
    pruned = 0
    if dead:
        try:
            pruned = store.remove_dead(dead, now)
        except Exception as error:
            logger.warning("conduit push: could not prune subscriptions (%s)", type(error).__name__)
    results = [(str(s.get("sid")), status) for s, status in answers]
    if results:
        sent = sum(1 for _, status in results if 200 <= status < 300)
        logger.info(
            "conduit push: kind=%s sent=%d failed=%d pruned=%d",
            kind, sent, len(results) - sent - len(dead), pruned,
        )
    return results


def summarize(results: List[Tuple[str, int]]) -> Tuple[bool, str]:
    """``(delivered_to_any, error_category)`` for a ``deliver`` result."""
    if not results:
        return False, "no subscribed devices"
    if any(200 <= status < 300 for _, status in results):
        return True, ""
    statuses = sorted({status for _, status in results})
    return False, "push rejected (" + ", ".join(str(s) if s else "no answer" for s in statuses) + ")"
