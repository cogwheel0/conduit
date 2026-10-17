"""The ``conduit`` gateway platform.

It has no inbound chat. It exists so that:

* cron jobs can ``deliver: conduit``. The live adapter's ``send`` and the
  out-of-process ``standalone_send`` both turn the job's output into an
  encrypted ``cron`` push for every subscribed device. The agent's
  ``send_message`` tool reaches the same two entry points, so its text
  arrives the same way, titled "Hermes" because it names no job;
* Conduit can manage subscriptions over the API server:
  ``POST [/p/<profile>]/api/platforms/conduit/events``. That route does not
  check ``API_SERVER_KEY`` itself, so ``verify_http_event_request`` compares
  the bearer token with the API server's key for the requested profile, in
  constant time, and refuses keys shorter than 16 characters.

The home channel ``devices`` is seeded at config load so a bare
``deliver: conduit`` resolves without any setup.
"""

from __future__ import annotations

import asyncio
import hmac
import logging
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import BasePlatformAdapter, SendResult

from . import ops, sender

try:
    from gateway.platforms._shared import get_scoped_secret as _scoped_secret
except ImportError:  # older Hermes: no profile secret scopes
    def _scoped_secret(name: str, default: Any = None) -> Any:
        return os.getenv(name, default)

logger = logging.getLogger(__name__)

PLATFORM = "conduit"
HOME_ENV = "CONDUIT_HOME_CHANNEL"
HOME_CHAT_ID = "devices"
HOME_NAME = "Conduit devices"
MIN_KEY_LENGTH = 16
UNSCHEDULED_TITLE = "Hermes"

# cron/scheduler_delivery.py wraps output unless ``cron.wrap_response: false``:
# a header, the output, and a one-line footer. Only the header is matched with a
# regex, on a bounded prefix; the footer is found with rfind. One regex over the
# whole output backtracked quadratically on a long run of whitespace.
_CRON_HEADER = re.compile(r"Cronjob Response: (?P<name>[^\n]*)\n\(job_id: (?P<job>[^)\n]*)\)\n-+\n\n")
_CRON_HEADER_LIMIT = 4096
_CRON_FOOTER = "\n\nTo stop or manage this job, send me a new message"


def _hermes_home() -> Path:
    from hermes_constants import get_hermes_home

    return Path(get_hermes_home())


# -- cron ---------------------------------------------------------------------

def _job_name(job_id: str) -> str:
    try:
        from cron.jobs import get_job

        job = get_job(job_id) or {}
        return str(job.get("name") or "")
    except Exception:
        return ""


def parse_cron_content(content: str, job_id: Optional[str] = None) -> Tuple[str, str, str]:
    """``(job_id, job_name, body)`` from what cron hands a platform."""
    text = (content or "").strip()
    match = _CRON_HEADER.match(text, 0, _CRON_HEADER_LIMIT)
    if match:
        body = text[match.end():]
        footer = body.rfind(_CRON_FOOTER)
        # The footer is the last line; anything after it means it is part of the output.
        if footer >= 0 and not body[footer + len(_CRON_FOOTER):].partition("\n")[2].strip():
            body = body[:footer]
        job = job_id or match.group("job").strip()
        return job, match.group("name").strip(), body.strip()
    job = str(job_id or "")
    return job, _job_name(job) if job else "", text


def push_cron(home: Path, content: str, job_id: Optional[str] = None) -> Tuple[bool, str, str]:
    """Pushes one cron delivery to every device that wants cron pushes.

    Text that names no cron job, which is what the agent's ``send_message``
    tool sends, is titled "Hermes" rather than shown as a job's output.
    Returns ``(delivered, dedup_key, error_category)``.
    """
    job, name, body = parse_cron_content(content, job_id)
    title = name if job else UNSCHEDULED_TITLE
    push = sender.cron_payload(job, str(int(time.time() * 1000)), title, body)
    delivered, error = sender.summarize(sender.deliver(home, push))
    return delivered, push["dk"], error


async def standalone_send(
    pconfig: Any, chat_id: str, message: str, *, thread_id: Optional[str] = None,
    media_files: Optional[List[str]] = None, force_document: bool = False,
) -> Dict[str, Any]:
    """Cron delivery when no gateway adapter is live (``hermes serve`` ticks cron itself)."""
    try:
        home = _hermes_home()
        delivered, dedup_key, error = await asyncio.to_thread(push_cron, home, message)
    except Exception as exc:
        logger.warning("conduit push: cron delivery failed (%s)", type(exc).__name__)
        return {"error": "conduit: push failed"}
    if not delivered:
        return {"error": f"conduit: {error}"}
    return {"success": True, "platform": PLATFORM, "chat_id": chat_id, "message_id": dedup_key}


# -- adapter ------------------------------------------------------------------

def _bearer(header: Any) -> str:
    if not isinstance(header, str):
        return ""
    scheme, _, token = header.strip().partition(" ")
    return token.strip() if scheme.lower() == "bearer" else ""


class ConduitAdapter(BasePlatformAdapter):
    """Delivers cron output as pushes and accepts Conduit's subscription ops."""

    supports_async_delivery = False
    interactive_resume = False
    splits_long_messages = True  # one push per delivery; never chunked
    MAX_MESSAGE_LENGTH = 1_000_000

    def __init__(self, config: PlatformConfig) -> None:
        super().__init__(config=config, platform=Platform(PLATFORM))
        # The gateway builds each profile's adapters inside that profile's scope, but
        # sends later run on the shared event loop without it: bind the home now.
        self._home = _hermes_home()
        try:  # no "gateway online / restarting" pings on users' lock screens
            config.gateway_restart_notification = False
        except Exception:
            pass

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        self._mark_connected()
        return True

    async def disconnect(self) -> None:
        self._mark_disconnected()

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        return {"name": HOME_NAME, "type": "dm"}

    async def send(
        self, chat_id: str, content: str, reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        job_id = (metadata or {}).get("job_id")
        try:
            delivered, dedup_key, error = await asyncio.to_thread(
                push_cron, self._home, content, str(job_id) if job_id else None,
            )
        except Exception as exc:
            logger.warning("conduit push: cron delivery failed (%s)", type(exc).__name__)
            return SendResult(success=False, error="conduit: push failed")
        if not delivered:
            return SendResult(success=False, error=f"conduit: {error}")
        return SendResult(success=True, message_id=dedup_key)

    # -- POST /api/platforms/conduit/events ----------------------------------

    def _expected_key(self) -> str:
        """The API server key for the profile this request was routed to."""
        runner = getattr(self, "gateway_runner", None)
        adapters = getattr(runner, "adapters", None)
        api_server = None
        if isinstance(adapters, dict):
            try:
                api_server = adapters.get(Platform.API_SERVER)
            except Exception:
                api_server = None
        expected = getattr(api_server, "_expected_api_key", None)
        if callable(expected):
            key = expected()
        else:
            key = _scoped_secret("API_SERVER_KEY", "")
        return key.strip() if isinstance(key, str) else ""

    async def verify_http_event_request(self, auth_header: Any) -> Tuple[bool, Optional[str]]:
        try:
            key = self._expected_key()
        except Exception as exc:
            logger.warning("conduit push: could not resolve the API server key (%s)", type(exc).__name__)
            return False, "conduit_auth_unavailable"
        if len(key) < MIN_KEY_LENGTH:
            return False, "conduit_api_key_unusable"
        token = _bearer(auth_header)
        if not hmac.compare_digest(token.encode("utf-8"), key.encode("utf-8")):
            return False, "conduit_auth_failed"
        return True, None

    async def dispatch_http_event(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        # ``/p/<profile>/`` already routed this to that profile's adapter.
        return await asyncio.to_thread(ops.handle, payload, self._home)


# -- registration -------------------------------------------------------------

def check_requirements() -> bool:
    """Passive dependency probe: httpx and cryptography ship with Hermes."""
    try:
        import cryptography  # noqa: F401
        import httpx  # noqa: F401
    except ImportError:
        return False
    return True


def env_enablement() -> Dict[str, Any]:
    """Seeds the ``devices`` home channel so ``deliver: conduit`` resolves."""
    home = str(_scoped_secret(HOME_ENV, "") or "").strip() or HOME_CHAT_ID
    return {"home_channel": {"chat_id": home, "name": HOME_NAME}}


def register(ctx) -> None:
    ctx.register_platform(
        name=PLATFORM,
        label="Conduit",
        adapter_factory=lambda cfg: ConduitAdapter(cfg),
        check_fn=check_requirements,
        install_hint="httpx and cryptography ship with Hermes; reinstall Hermes if they are missing",
        env_enablement_fn=env_enablement,
        cron_deliver_env_var=HOME_ENV,
        standalone_sender_fn=standalone_send,
        emoji="📱",
        allow_update_command=False,
    )
