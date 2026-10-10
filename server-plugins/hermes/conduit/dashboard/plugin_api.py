"""Dashboard routes for Conduit push, mounted at ``/api/plugins/conduit/``.

Desktop Conduit talks to ``hermes serve`` (the dashboard), where the gateway's
API server usually is not running, so subscriptions are managed here instead.
The dashboard's own session auth protects these routes.

    GET  /api/plugins/conduit/v1/hello
    POST /api/plugins/conduit/v1/events[?profile=<name>]   body: one ops request

Routes are mounted when the dashboard starts, so a freshly installed plugin
answers only after Hermes restarts.
"""

from __future__ import annotations

import asyncio
import importlib
import importlib.util
import json
import sys
import threading
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

router = APIRouter()

_CORE = "hermes_conduit_push_core"
_MAX_BODY = 16384
_core_lock = threading.Lock()


def _ops():
    """The plugin's ``ops`` module, imported from the package next to this folder."""
    with _core_lock:
        if _CORE not in sys.modules:
            root = Path(__file__).resolve().parent.parent
            spec = importlib.util.spec_from_file_location(
                _CORE, root / "__init__.py", submodule_search_locations=[str(root)])
            if spec is None or spec.loader is None:
                raise ImportError("conduit plugin package not found")
            package = importlib.util.module_from_spec(spec)
            sys.modules[_CORE] = package
            try:
                spec.loader.exec_module(package)
            except BaseException:
                sys.modules.pop(_CORE, None)
                raise
    return importlib.import_module(f"{_CORE}.ops")


def profile_home(profile: Optional[str]) -> Tuple[Optional[Path], Optional[str], int]:
    """``(home, error, status)`` for the ``profile`` query parameter.

    Empty or ``current`` means the dashboard's own profile.
    """
    from hermes_constants import get_hermes_home

    name = (profile or "").strip().lower()
    if not name or name == "current":
        return Path(get_hermes_home()), None, 200
    from hermes_cli import profiles

    try:
        profiles.validate_profile_name(name)
    except ValueError:
        return None, "invalid_profile", 400
    if not profiles.profile_exists(name):
        return None, "unknown_profile", 404
    return Path(profiles.get_profile_dir(name)), None, 200


def handle_events(raw: bytes, profile: Optional[str]) -> Tuple[int, Dict[str, Any]]:
    """Validates one request body and runs it; ``(status, json)``."""
    if len(raw) > _MAX_BODY:
        return 413, {"ok": False, "error": "too_large"}
    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return 400, {"ok": False, "error": "invalid_json"}
    if not isinstance(body, dict):
        return 400, {"ok": False, "error": "invalid_request"}
    home, error, status = profile_home(profile)
    if home is None:
        return status, {"ok": False, "error": error}
    return 200, _ops().handle(body, home)


@router.get("/v1/hello")
async def hello() -> Dict[str, Any]:
    return _ops().hello()


async def read_capped(request: Request, limit: int = _MAX_BODY) -> Optional[bytes]:
    """The request body, or None as soon as it is known to be over ``limit`` bytes.

    A declared Content-Length is checked before anything is read, and the
    stream is read only until it passes the limit, so an oversized or chunked
    body is never held in memory.
    """
    try:
        declared = int(request.headers.get("content-length") or 0)
    except ValueError:
        declared = 0
    if declared > limit:
        return None
    chunks = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
            return None
        chunks.append(chunk)
    return b"".join(chunks)


@router.post("/v1/events")
async def events(request: Request, profile: Optional[str] = None):
    raw = await read_capped(request)
    if raw is None:
        return JSONResponse({"ok": False, "error": "too_large"}, status_code=413)
    status, result = await asyncio.to_thread(handle_events, raw, profile)
    return JSONResponse(result, status_code=status)
