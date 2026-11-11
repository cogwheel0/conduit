"""Subscriptions and session watches, stored per Hermes profile.

Files live in ``<HERMES_HOME>/conduit_push/`` (mode 0700): ``subscriptions.json``
and ``watches.json``, both mode 0600. Every write takes an exclusive ``flock``
on ``.lock``, re-reads, and atomically replaces the file, so the gateway and
the dashboard can share one profile safely. Readers never see a partial file.
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional

try:  # POSIX only; Windows falls back to the in-process lock.
    import fcntl
except ImportError:  # pragma: no cover - exercised on Windows only
    fcntl = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)

DIR_NAME = "conduit_push"
SUBSCRIPTIONS = "subscriptions.json"
WATCHES = "watches.json"
MAX_SUBSCRIPTIONS = 10
SEEN_TTL = 30 * 86400
MAX_WATCH_TTL = 21600
MAX_WATCHES = 256

_thread_lock = threading.RLock()


class Store:
    """One profile's push state. Cheap to construct; holds no open files."""

    def __init__(self, home: os.PathLike) -> None:
        self.dir = Path(home) / DIR_NAME

    # -- low level -----------------------------------------------------------

    def _ensure_dir(self) -> None:
        self.dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.dir, 0o700)
        except OSError:
            pass

    @contextmanager
    def _locked(self) -> Iterator[None]:
        self._ensure_dir()
        with _thread_lock:
            fd = os.open(str(self.dir / ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                if fcntl is not None:
                    fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                if fcntl is not None:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_UN)
                    except OSError:
                        pass
                os.close(fd)

    def _read(self, name: str) -> Dict[str, Any]:
        path = self.dir / name
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            logger.warning("conduit push: unreadable state file, starting fresh")
            return {}
        return data if isinstance(data, dict) else {}

    def _write(self, name: str, data: Dict[str, Any]) -> None:
        fd, tmp = tempfile.mkstemp(prefix=f".{name}.", suffix=".tmp", dir=str(self.dir))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.dir / name)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    # -- subscriptions -------------------------------------------------------

    @staticmethod
    def _live(subs: List[Dict[str, Any]], now: float) -> List[Dict[str, Any]]:
        cutoff = now - SEEN_TTL
        return [s for s in subs if isinstance(s, dict) and float(s.get("seen") or 0) >= cutoff]

    def subscriptions(self, now: Optional[float] = None) -> List[Dict[str, Any]]:
        """Subscriptions seen in the last 30 days."""
        now = time.time() if now is None else now
        subs = self._read(SUBSCRIPTIONS).get("subs")
        return self._live(subs if isinstance(subs, list) else [], now)

    def get(self, sid: str, now: Optional[float] = None) -> Optional[Dict[str, Any]]:
        return next((s for s in self.subscriptions(now) if s.get("sid") == sid), None)

    def sids(self, now: Optional[float] = None) -> List[str]:
        return [str(s.get("sid")) for s in self.subscriptions(now)]

    def subscribe(self, sub: Dict[str, Any], now: Optional[float] = None) -> None:
        """Adds or replaces a subscription (same sid or did) and refreshes ``seen``.

        Entries not seen for 30 days are dropped, and the oldest are evicted
        beyond ten per profile.
        """
        now = time.time() if now is None else now
        entry = dict(sub, seen=int(now))
        with self._locked():
            current = self.subscriptions(now)
            kept = [
                s for s in current
                if s.get("sid") != entry["sid"] and not (entry.get("did") and s.get("did") == entry["did"])
            ]
            kept.append(entry)
            kept.sort(key=lambda s: float(s.get("seen") or 0), reverse=True)
            self._write(SUBSCRIPTIONS, {"v": 1, "subs": kept[:MAX_SUBSCRIPTIONS]})

    def remove(self, sids: List[str], now: Optional[float] = None) -> int:
        """Deletes the given sids; returns how many were removed."""
        if not sids:
            return 0
        now = time.time() if now is None else now
        drop = set(sids)
        with self._locked():
            current = self.subscriptions(now)
            kept = [s for s in current if s.get("sid") not in drop]
            self._write(SUBSCRIPTIONS, {"v": 1, "subs": kept})
        return len(current) - len(kept)

    # -- watches -------------------------------------------------------------

    def _watches(self, now: float) -> Dict[str, float]:
        raw = self._read(WATCHES).get("watches")
        if not isinstance(raw, dict):
            return {}
        return {str(k): float(v) for k, v in raw.items() if isinstance(v, (int, float)) and v > now}

    def watch(self, session_id: str, ttl: int, now: Optional[float] = None) -> int:
        """Marks a session as started by Conduit until ``now + ttl``; returns the expiry."""
        now = time.time() if now is None else now
        expires = int(now + min(max(int(ttl), 1), MAX_WATCH_TTL))
        with self._locked():
            watches = self._watches(now)
            watches[session_id] = max(expires, int(watches.get(session_id, 0)))
            if len(watches) > MAX_WATCHES:
                keep = sorted(watches.items(), key=lambda item: item[1], reverse=True)[:MAX_WATCHES]
                watches = dict(keep)
            self._write(WATCHES, {"v": 1, "watches": watches})
        return expires

    def is_watched(self, session_id: str, now: Optional[float] = None) -> bool:
        now = time.time() if now is None else now
        return bool(session_id) and session_id in self._watches(now)
