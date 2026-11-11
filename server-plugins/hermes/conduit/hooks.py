"""Reply pushes from the agent's turn hooks.

Hermes fires ``post_llm_call`` and then ``on_session_end`` at the end of every
turn, synchronously on the agent thread (``agent/turn_finalizer.py``). The
first hook only remembers the reply; the second decides what it was:

* finished turn -> ``reply`` with the final text,
* ``failed`` and not ``interrupted`` -> ``reply_failed``,
* interrupted -> nothing.

Only sessions Conduit started push. A ``mobile`` session is a Conduit desktop
chat (``source: "mobile"`` over the dashboard socket). An ``api_server``
session pushes only while Conduit holds a ``watch`` on it, so Open WebUI and
other API clients sharing the gateway stay quiet. Cron runs, Telegram and
everything else never push replies; cron reaches devices only through
``deliver: conduit``.

Sending happens on two daemon threads behind a bounded queue, so a slow relay
never holds up a turn and nothing here can raise into Hermes.
"""

from __future__ import annotations

import logging
import os
import queue
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, NamedTuple, Optional, Tuple

from . import sender
from .store import Store

logger = logging.getLogger(__name__)

PUSH_PLATFORMS = ("mobile", "api_server")
WATCHED_ONLY = ("api_server",)
_PENDING_MAX = 256
_PENDING_TTL = 900.0
_MISSING: Any = object()


def _hermes_home() -> Path:
    from hermes_constants import get_hermes_home

    return Path(get_hermes_home())


class _Reply(NamedTuple):
    at: float
    platform: str
    text: str
    home: Path


class _Job(NamedTuple):
    kind: str
    home: Path
    platform: str
    session_id: str
    turn_id: str
    text: str


_pending: Dict[Tuple[str, str], _Reply] = {}
_pending_lock = threading.Lock()


class Dispatcher:
    """A small bounded queue drained by daemon threads (they never block exit)."""

    def __init__(self, workers: int = 2, maxsize: int = 64) -> None:
        self._workers = workers
        self._queue: "queue.Queue[Tuple[Callable[..., Any], tuple]]" = queue.Queue(maxsize=maxsize)
        self._lock = threading.Lock()
        self._pid: Optional[int] = None

    def _start(self) -> None:
        with self._lock:
            if self._pid == os.getpid():
                return
            self._pid = os.getpid()
            for index in range(self._workers):
                threading.Thread(
                    target=self._loop, name=f"conduit-push-{index}", daemon=True,
                ).start()

    def submit(self, fn: Callable[..., Any], *args: Any) -> bool:
        self._start()
        try:
            self._queue.put_nowait((fn, args))
            return True
        except queue.Full:
            logger.warning("conduit push: send queue full, dropped a push")
            return False

    def _loop(self) -> None:
        while True:
            fn, args = self._queue.get()
            try:
                fn(*args)
            except Exception as error:
                logger.warning("conduit push: background send failed (%s)", type(error).__name__)
            finally:
                self._queue.task_done()

    def join(self) -> None:
        """Waits until every queued push has been handled (tests)."""
        self._queue.join()


dispatcher = Dispatcher()


def session_title(home: Path, session_id: str) -> str:
    """The session's title from ``state.db`` when it already has one, else ""."""
    path = Path(home) / "state.db"
    if not path.is_file():
        return ""
    try:
        conn = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True, timeout=0.5)
        try:
            row = conn.execute("SELECT title FROM sessions WHERE id = ?", (session_id,)).fetchone()
        finally:
            conn.close()
    except Exception:
        return ""
    return str(row[0]) if row and row[0] else ""


def _send_reply(job: _Job) -> None:
    now = time.time()
    if job.platform in WATCHED_ONLY and not Store(job.home).is_watched(job.session_id, now):
        return
    push = sender.reply_payload(
        job.kind, job.session_id, job.turn_id, session_title(job.home, job.session_id), job.text,
    )
    sender.deliver(job.home, push, now=now)


def _prune(now: float) -> None:
    stale = [key for key, reply in _pending.items() if now - reply.at > _PENDING_TTL]
    for key in stale:
        _pending.pop(key, None)
    while len(_pending) >= _PENDING_MAX:
        _pending.pop(next(iter(_pending)))


def on_post_llm_call(
    session_id: Any = None, turn_id: Any = None, assistant_response: Any = None,
    platform: Any = None, **_: Any,
) -> None:
    """Remembers a finished reply until ``on_session_end`` says how the turn ended."""
    try:
        if platform not in PUSH_PLATFORMS or not session_id:
            return None
        reply = _Reply(time.time(), str(platform), assistant_response if isinstance(assistant_response, str) else "",
                       _hermes_home())
        with _pending_lock:
            _prune(reply.at)
            _pending[(str(session_id), str(turn_id or ""))] = reply
    except Exception as error:
        logger.warning("conduit push: post_llm_call hook failed (%s)", type(error).__name__)
    return None


def on_session_end(
    session_id: Any = None, turn_id: Any = None, failed: Any = _MISSING, interrupted: Any = False,
    platform: Any = None, **_: Any,
) -> None:
    """Queues the reply (or failure) push for a turn that just ended."""
    try:
        if failed is _MISSING or not session_id:
            return None  # a session boundary (new/close), not the end of a turn
        key = (str(session_id), str(turn_id or ""))
        with _pending_lock:
            reply = _pending.pop(key, None)
        if interrupted:
            return None
        platform = reply.platform if reply else platform
        if platform not in PUSH_PLATFORMS:
            return None
        if failed:
            kind, text = "reply_failed", (reply.text if reply else "")
        elif reply is not None:
            kind, text = "reply", reply.text
        else:
            return None
        home = reply.home if reply else _hermes_home()
        dispatcher.submit(_send_reply, _Job(kind, home, str(platform), key[0], key[1], text))
    except Exception as error:
        logger.warning("conduit push: on_session_end hook failed (%s)", type(error).__name__)
    return None


def register(ctx) -> None:
    ctx.register_hook("post_llm_call", on_post_llm_call)
    ctx.register_hook("on_session_end", on_session_end)
