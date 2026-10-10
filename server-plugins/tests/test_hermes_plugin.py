"""Tests for the Hermes `conduit` push plugin (server-plugins/hermes/conduit).

The Hermes modules the plugin imports are replaced by small stubs, the plugin
is loaded the way Hermes loads a directory plugin, and every push is captured
with an httpx mock transport and decrypted with the device's test keys.
"""

import asyncio
import importlib
import importlib.util
import json
import logging
import os
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import types
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Optional

import httpx
import pytest
import yaml
from cryptography.hazmat.primitives.asymmetric import ec

from conduit_webpush import webpush as wp

HERMES_DIR = Path(__file__).resolve().parents[1] / "hermes"
PLUGIN_DIR = HERMES_DIR / "conduit"
PACKAGE = "hermes_plugins_under_test.conduit"
GOOD_KEY = "k" * 32


# -- Hermes stubs -------------------------------------------------------------

class Platform:
    def __init__(self, value: str) -> None:
        self.value = value

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Platform) and other.value == self.value

    def __hash__(self) -> int:
        return hash(self.value)


Platform.API_SERVER = Platform("api_server")


@dataclass
class PlatformConfig:
    enabled: bool = False
    extra: Dict[str, Any] = field(default_factory=dict)
    home_channel: Any = None
    gateway_restart_notification: bool = True


@dataclass
class SendResult:
    success: bool
    message_id: Optional[str] = None
    error: Optional[str] = None


class BasePlatformAdapter:
    gateway_runner = None

    def __init__(self, config: PlatformConfig, platform: Platform) -> None:
        self.config = config
        self.platform = platform
        self._running = False

    def _mark_connected(self) -> None:
        self._running = True

    def _mark_disconnected(self) -> None:
        self._running = False


class _Router:
    def __init__(self) -> None:
        self.routes: Dict[tuple, Any] = {}

    def _route(self, method: str, path: str):
        def decorate(fn):
            self.routes[(method, path)] = fn
            return fn
        return decorate

    def get(self, path: str):
        return self._route("GET", path)

    def post(self, path: str):
        return self._route("POST", path)


class _JSONResponse:
    def __init__(self, content: Any, status_code: int = 200) -> None:
        self.content = content
        self.status_code = status_code


class Hermes:
    """State behind the stubbed Hermes modules."""

    def __init__(self, home: Path) -> None:
        self.home = home
        self.secrets: Dict[str, str] = {}
        self.jobs: Dict[str, Dict[str, Any]] = {}
        self.profiles: Dict[str, Path] = {}

    def modules(self, *, gateway: bool = True) -> Dict[str, types.ModuleType]:
        def module(name: str, **attrs: Any) -> types.ModuleType:
            mod = types.ModuleType(name)
            mod.__dict__.update(attrs)
            return mod

        def validate_profile_name(name: str) -> None:
            if not name.replace("-", "").replace("_", "").isalnum():
                raise ValueError(name)

        mods = {
            "hermes_constants": module("hermes_constants", get_hermes_home=lambda: self.home),
            "cron": module("cron", __path__=[]),
            "cron.jobs": module("cron.jobs", get_job=lambda job_id: self.jobs.get(job_id)),
            "hermes_cli": module("hermes_cli", __path__=[]),
            "hermes_cli.profiles": module(
                "hermes_cli.profiles",
                validate_profile_name=validate_profile_name,
                profile_exists=lambda name: name in self.profiles,
                get_profile_dir=lambda name: self.profiles[name],
            ),
            "fastapi": module("fastapi", APIRouter=_Router, Request=object),
            "fastapi.responses": module("fastapi.responses", JSONResponse=_JSONResponse),
        }
        if gateway:
            mods.update({
                "gateway": module("gateway", __path__=[]),
                "gateway.config": module("gateway.config", Platform=Platform, PlatformConfig=PlatformConfig),
                "gateway.platforms": module("gateway.platforms", __path__=[]),
                "gateway.platforms.base": module(
                    "gateway.platforms.base", BasePlatformAdapter=BasePlatformAdapter, SendResult=SendResult),
                "gateway.platforms._shared": module(
                    "gateway.platforms._shared",
                    get_scoped_secret=lambda name, default=None: self.secrets.get(name, default)),
            })
        return mods


def _evict(prefix: str) -> None:
    for name in list(sys.modules):
        if name == prefix or name.startswith(prefix + "."):
            del sys.modules[name]


def load_package(name: str = PACKAGE) -> types.ModuleType:
    """Imports the plugin like ``hermes_cli.plugins_loader._load_directory_module``."""
    _evict(name)
    parent = name.rpartition(".")[0]
    if parent and parent not in sys.modules:
        namespace = types.ModuleType(parent)
        namespace.__path__ = []
        sys.modules[parent] = namespace
    spec = importlib.util.spec_from_file_location(
        name, PLUGIN_DIR / "__init__.py", submodule_search_locations=[str(PLUGIN_DIR)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class Relay:
    """Captures pushes; answers ``status`` (per endpoint, or the default)."""

    def __init__(self) -> None:
        self.requests = []
        self.status = 201
        self.by_endpoint: Dict[str, int] = {}
        self.fail = False
        self.meanwhile: Dict[str, Any] = {}  # endpoint -> what happens while it answers

    def handler(self, request: httpx.Request) -> httpx.Response:
        if self.fail:
            raise httpx.ConnectError("unreachable", request=request)
        self.requests.append(request)
        meanwhile = self.meanwhile.pop(str(request.url), None)
        if meanwhile is not None:
            meanwhile()
        return httpx.Response(self.by_endpoint.get(str(request.url), self.status))


class Device:
    def __init__(self, name: str, events: Optional[list] = None) -> None:
        key = ec.generate_private_key(ec.SECP256R1())
        self.private = wp.private_bytes(key)
        self.public = wp.public_bytes_of(key)
        self.auth = os.urandom(16)
        self.sid = wp.b64u_encode(os.urandom(16))
        self.did = f"did-{name}"
        self.endpoint = f"https://relay.example/v1/push/{name}"
        self.events = events

    def sub(self, **overrides: Any) -> Dict[str, Any]:
        sub = {
            "sid": self.sid, "did": self.did, "endpoint": self.endpoint,
            "p256dh": wp.b64u_encode(self.public), "auth": wp.b64u_encode(self.auth),
            "label": "Test phone", "platform": "ios", "proto": 1,
        }
        if self.events is not None:
            sub["events"] = self.events
        sub.update(overrides)
        return sub

    def open(self, request: httpx.Request) -> Dict[str, Any]:
        return json.loads(wp.decrypt(request.content, self.private, self.auth))


@dataclass
class Env:
    hermes: Hermes
    home: Path
    relay: Relay
    plugin: types.ModuleType
    ops: types.ModuleType
    store: types.ModuleType
    sender: types.ModuleType
    hooks: types.ModuleType
    adapter: types.ModuleType

    def op(self, request: Dict[str, Any], now: Optional[float] = None) -> Dict[str, Any]:
        return self.ops.handle(request, self.home, now=now)

    def subscribe(self, device: Device, now: Optional[float] = None) -> None:
        assert self.op({"op": "subscribe", "sub": device.sub()}, now=now) == {"ok": True}

    def pushes_for(self, device: Device):
        return [r for r in self.relay.requests if str(r.url) == device.endpoint]


@pytest.fixture
def env(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    hermes = Hermes(home)
    for name, module in hermes.modules().items():
        monkeypatch.setitem(sys.modules, name, module)
    plugin = load_package()
    mods = {name: importlib.import_module(f"{PACKAGE}.{name}")
            for name in ("ops", "store", "sender", "hooks", "adapter")}
    relay = Relay()
    monkeypatch.setattr(mods["sender"], "HTTP_TRANSPORT", httpx.MockTransport(relay.handler))
    yield Env(hermes=hermes, home=home, relay=relay, plugin=plugin, **mods)
    _evict(PACKAGE)


def run(coro):
    return asyncio.run(coro)


# -- ops -----------------------------------------------------------------------

def test_hello(env):
    assert env.op({"op": "hello"}) == {"ok": True, "plugin": "conduit", "version": "1.0.0", "proto": 1}


def test_unknown_and_malformed_requests(env):
    assert env.op({"op": "nope"}) == {"ok": False, "error": "unknown_op"}
    assert env.ops.handle(["op"], env.home) == {"ok": False, "error": "invalid_request"}
    assert env.op({}) == {"ok": False, "error": "unknown_op"}


def _bad_point() -> str:
    return wp.b64u_encode(b"\x04" + b"\x00" * 64)


@pytest.mark.parametrize("overrides,error", [
    ({"p256dh": wp.b64u_encode(b"\x04" + os.urandom(63))}, "invalid_p256dh"),
    ({"p256dh": "not base64!"}, "invalid_p256dh"),
    ({"p256dh": _bad_point()}, "invalid_p256dh"),
    ({"auth": wp.b64u_encode(os.urandom(15))}, "invalid_auth"),
    ({"auth": wp.b64u_encode(os.urandom(17))}, "invalid_auth"),
    ({"endpoint": "http://relay.example/v1/push/x"}, "invalid_endpoint"),
    ({"endpoint": "https://user:pw@relay.example/v1/push/x"}, "invalid_endpoint"),
    ({"endpoint": "https:///nohost"}, "invalid_endpoint"),
    ({"endpoint": "https://relay.example/" + "a" * 2100}, "invalid_endpoint"),
    ({"sid": wp.b64u_encode(os.urandom(15))}, "invalid_sid"),
    ({"sid": "A" * 21 + "!"}, "invalid_sid"),
    ({"sid": None}, "invalid_sid"),
    ({"did": ""}, "invalid_did"),
    ({"did": "has space"}, "invalid_did"),
    ({"proto": 2}, "unsupported_proto"),
    ({"events": "reply"}, "invalid_events"),
])
def test_subscribe_validation(env, overrides, error):
    response = env.op({"op": "subscribe", "sub": Device("a").sub(**overrides)})
    assert response == {"ok": False, "error": error}
    assert env.op({"op": "list"}) == {"ok": True, "sids": []}


def test_subscribe_stores_a_clean_record(env):
    device = Device("a")
    sub = device.sub(events=["reply", "cron", "channel", "reply"], label="L" * 100, extra="dropped")
    assert env.op({"op": "subscribe", "sub": sub}, now=1000) == {"ok": True}
    [stored] = env.store.Store(env.home).subscriptions(now=1000)
    assert stored["events"] == ["reply", "cron"]
    assert len(stored["label"]) == 64
    assert stored["seen"] == 1000
    assert "extra" not in stored
    assert set(stored) == {"sid", "did", "endpoint", "p256dh", "auth", "events", "label", "platform", "proto", "seen"}


def test_subscribe_replaces_same_sid_and_same_did(env):
    first = Device("a")
    env.subscribe(first, now=100)
    env.op({"op": "subscribe", "sub": first.sub(label="renamed")}, now=200)
    subs = env.store.Store(env.home).subscriptions(now=200)
    assert [(s["sid"], s["label"], s["seen"]) for s in subs] == [(first.sid, "renamed", 200)]

    reinstalled = Device("a")  # same did, new keys and sid
    env.subscribe(reinstalled, now=300)
    assert env.op({"op": "list"}, now=300)["sids"] == [reinstalled.sid]


def test_list_never_returns_secrets(env):
    device = Device("a")
    env.subscribe(device)
    response = env.op({"op": "list"})
    assert response == {"ok": True, "sids": [device.sid]}
    text = json.dumps(response)
    for secret in (device.endpoint, device.sub()["p256dh"], device.sub()["auth"]):
        assert secret not in text


def test_unsubscribe(env):
    device = Device("a")
    env.subscribe(device)
    assert env.op({"op": "unsubscribe", "sid": device.sid}) == {"ok": True, "removed": True}
    assert env.op({"op": "unsubscribe", "sid": device.sid}) == {"ok": True, "removed": False}
    assert env.op({"op": "unsubscribe", "sid": "short"}) == {"ok": False, "error": "invalid_sid"}
    assert env.op({"op": "list"})["sids"] == []


def test_watch_ttl_is_capped_and_validated(env):
    assert env.op({"op": "watch", "session_id": "s1", "ttl": 10 ** 9}, now=1000) == {
        "ok": True, "expires": 1000 + 21600}
    assert env.op({"op": "watch", "session_id": "s2"}, now=1000)["expires"] == 1000 + 3600
    for ttl in (0, -5, "60", True, 1.5):
        assert env.op({"op": "watch", "session_id": "s1", "ttl": ttl}) == {"ok": False, "error": "invalid_ttl"}
    for session_id in ("", None, "a b", "x" * 257):
        assert env.op({"op": "watch", "session_id": session_id}) == {"ok": False, "error": "invalid_session_id"}
    store = env.store.Store(env.home)
    assert store.is_watched("s1", now=1000 + 21599)
    assert not store.is_watched("s1", now=1000 + 21601)
    assert not store.is_watched("never", now=1000)


def test_watch_reports_the_expiry_it_kept(env):
    assert env.op({"op": "watch", "session_id": "s", "ttl": 3600}, now=1000)["expires"] == 4600
    # A shorter refresh never brings a watch forward, and says so.
    assert env.op({"op": "watch", "session_id": "s", "ttl": 10}, now=1000)["expires"] == 4600
    assert env.store.Store(env.home).is_watched("s", now=4599)


def test_watch_at_the_limit_keeps_the_session_it_was_asked_for(env):
    limit = env.store.MAX_WATCHES
    directory = env.home / "conduit_push"
    directory.mkdir()
    later = {f"w{index}": 1000 + 21600 for index in range(limit)}
    (directory / "watches.json").write_text(json.dumps({"v": 1, "watches": later}))
    store = env.store.Store(env.home)
    assert store.watch("new", 60, now=1000) == 1060
    assert store.is_watched("new", now=1000)
    assert len(store._watches(1000)) == limit


def test_test_push_is_sent_synchronously_and_decrypts(env):
    device = Device("a")
    other = Device("b")
    env.subscribe(device)
    env.subscribe(other)
    response = env.op({"op": "test", "sid": device.sid, "nonce": "n0nce-1"})
    assert response == {"ok": True, "push_status": 201}
    [request] = env.relay.requests
    assert str(request.url) == device.endpoint
    payload = device.open(request)
    assert payload["k"] == "test"
    assert payload["src"] == "hermes"
    assert payload["dk"] == "test:n0nce-1"
    assert payload["n"] == "n0nce-1"
    assert payload["v"] == 1
    assert "g" not in payload
    assert len(request.content) in (598, 1110, 2134)
    assert request.headers["Content-Encoding"] == "aes128gcm"
    assert request.headers["Content-Type"] == "application/octet-stream"
    assert request.headers["TTL"] == "300"
    assert request.headers["Urgency"] == "high"
    assert request.headers["Topic"] == wp.topic(device.auth, "test:n0nce-1")


def test_test_push_errors(env):
    device = Device("a")
    assert env.op({"op": "test", "sid": device.sid, "nonce": "n"}) == {"ok": False, "error": "unknown_sid"}
    env.subscribe(device)
    for nonce in ("", None, "bad nonce", "x" * 65):
        assert env.op({"op": "test", "sid": device.sid, "nonce": nonce}) == {"ok": False, "error": "invalid_nonce"}
    env.relay.fail = True
    assert env.op({"op": "test", "sid": device.sid, "nonce": "n"}) == {"ok": True, "push_status": 0}


@pytest.mark.parametrize("status", [404, 410])
def test_dead_endpoint_is_pruned(env, status):
    device = Device("a")
    env.subscribe(device)
    env.relay.status = status
    assert env.op({"op": "test", "sid": device.sid, "nonce": "n"}) == {"ok": True, "push_status": status}
    assert env.op({"op": "list"})["sids"] == []


def test_dead_endpoint_does_not_prune_a_refreshed_subscription(env):
    device, other = Device("a"), Device("b")
    env.subscribe(device)
    env.subscribe(other)
    old_endpoint = device.endpoint
    env.relay.by_endpoint[old_endpoint] = 410
    env.relay.by_endpoint[other.endpoint] = 404
    # The push token changed: the app re-registers with the same sid and a new
    # endpoint while the old endpoint is still answering 410.
    device.endpoint = "https://relay.example/v1/push/a-renewed"
    env.relay.meanwhile[old_endpoint] = lambda: env.subscribe(device)
    _turn(env)
    [stored] = env.store.Store(env.home).subscriptions()
    assert (stored["sid"], stored["endpoint"]) == (device.sid, device.endpoint)


def test_other_failures_keep_the_subscription(env):
    device = Device("a")
    env.subscribe(device)
    for status in (413, 429, 500, 503):
        env.relay.status = status
        assert env.op({"op": "test", "sid": device.sid, "nonce": "n"})["push_status"] == status
    assert env.op({"op": "list"})["sids"] == [device.sid]


def test_ops_never_raise(env, monkeypatch):
    def boom(*_args, **_kwargs):
        raise RuntimeError("disk on fire")

    monkeypatch.setattr(env.store.Store, "sids", boom)
    assert env.op({"op": "list"}) == {"ok": False, "error": "internal"}


# -- store ---------------------------------------------------------------------

def test_store_files_are_private(env):
    env.subscribe(Device("a"))
    env.op({"op": "watch", "session_id": "s1", "ttl": 60})
    directory = env.home / "conduit_push"
    assert stat.S_IMODE(directory.stat().st_mode) == 0o700
    for name in ("subscriptions.json", "watches.json"):
        assert stat.S_IMODE((directory / name).stat().st_mode) == 0o600


def test_store_write_is_atomic(env, monkeypatch):
    device = Device("a")
    env.subscribe(device)
    path = env.home / "conduit_push" / "subscriptions.json"
    before = path.read_bytes()
    real_dump = json.dump

    def torn_dump(obj, handle, **kwargs):
        handle.write("{\"v\": 1, \"subs\": [")
        raise OSError("disk full")

    monkeypatch.setattr(json, "dump", torn_dump)
    with pytest.raises(OSError):
        env.store.Store(env.home).subscribe(Device("b").sub())
    monkeypatch.setattr(json, "dump", real_dump)
    assert path.read_bytes() == before
    assert sorted(p.name for p in path.parent.iterdir()) == [".lock", "subscriptions.json"]


def test_store_concurrent_writers_lose_nothing(env):
    devices = [Device(str(i)) for i in range(8)]
    errors = []

    def subscribe(device):
        try:
            env.subscribe(device)
        except Exception as error:  # pragma: no cover - reported below
            errors.append(error)

    threads = [threading.Thread(target=subscribe, args=(d,)) for d in devices]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert not errors
    assert sorted(env.op({"op": "list"})["sids"]) == sorted(d.sid for d in devices)


def test_store_caps_at_ten_evicting_the_oldest(env):
    devices = [Device(str(i)) for i in range(12)]
    for index, device in enumerate(devices):
        env.subscribe(device, now=1000 + index)
    sids = env.op({"op": "list"}, now=2000)["sids"]
    assert len(sids) == 10
    assert set(sids) == {d.sid for d in devices[2:]}


def test_store_keeps_the_subscription_it_just_accepted_on_a_tie(env):
    devices = [Device(str(i)) for i in range(11)]
    for device in devices:
        env.subscribe(device, now=1000)  # all in the same second
    sids = env.op({"op": "list"}, now=1000)["sids"]
    assert len(sids) == 10
    assert devices[-1].sid in sids


def test_store_expires_after_thirty_days(env):
    old, fresh = Device("old"), Device("fresh")
    day = 86400
    env.subscribe(old, now=0)
    env.subscribe(fresh, now=29 * day)
    assert set(env.op({"op": "list"}, now=30 * day)["sids"]) == {old.sid, fresh.sid}
    assert env.op({"op": "list"}, now=30 * day + 1)["sids"] == [fresh.sid]
    env.op({"op": "watch", "session_id": "s", "ttl": 60}, now=30 * day + 1)
    env.subscribe(Device("third"), now=30 * day + 2)
    raw = json.loads((env.home / "conduit_push" / "subscriptions.json").read_text())
    assert old.sid not in {s["sid"] for s in raw["subs"]}


def test_store_survives_a_corrupt_file(env):
    directory = env.home / "conduit_push"
    directory.mkdir()
    (directory / "subscriptions.json").write_text("{not json")
    assert env.op({"op": "list"}) == {"ok": True, "sids": []}
    env.subscribe(Device("a"))
    assert len(env.op({"op": "list"})["sids"]) == 1


# -- reply hooks -----------------------------------------------------------------

def _turn(env, *, platform="mobile", session="sess-1", turn="sess-1:task:abcd", text="**Done.** Here it is.",
          failed=False, interrupted=False, post=True):
    if post:
        env.hooks.on_post_llm_call(
            session_id=session, task_id="task", turn_id=turn, user_message="hi",
            assistant_response=text, conversation_history=[], model="m", platform=platform,
            telemetry_schema_version=1)
    env.hooks.on_session_end(
        session_id=session, task_id="task", turn_id=turn, completed=not failed, failed=failed,
        interrupted=interrupted, turn_exit_reason="done", model="m", platform=platform)
    env.hooks.dispatcher.join()


def _make_state_db(home: Path, session: str, title: str) -> None:
    conn = sqlite3.connect(home / "state.db")
    conn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT)")
    conn.execute("INSERT INTO sessions VALUES (?, ?)", (session, title))
    conn.commit()
    conn.close()


def test_mobile_reply_pushes_to_every_device(env):
    phone, tablet = Device("phone"), Device("tablet")
    env.subscribe(phone)
    env.subscribe(tablet)
    _make_state_db(env.home, "sess-1", "Trip ideas")
    _turn(env)
    assert len(env.relay.requests) == 2
    for device in (phone, tablet):
        [request] = env.pushes_for(device)
        payload = device.open(request)
        assert payload["k"] == "reply"
        assert payload["src"] == "hermes"
        assert payload["ids"] == {"session": "sess-1", "turn": "sess-1:task:abcd"}
        assert payload["t"] == "Trip ideas"
        assert payload["b"] == "Done. Here it is."
        assert payload["dk"] == "hermes:sess-1:sess-1:task:abcd"
        assert payload["g"] == "hermes:sess-1"
        assert request.headers["TTL"] == "86400"
        assert request.headers["Urgency"] == "high"
        assert request.headers["Topic"] == wp.topic(device.auth, payload["dk"])


def test_reply_without_a_title_has_an_empty_title(env):
    device = Device("a")
    env.subscribe(device)
    _turn(env)
    assert device.open(env.relay.requests[0])["t"] == ""


def test_failed_turn_pushes_reply_failed(env):
    device = Device("a")
    env.subscribe(device)
    _turn(env, failed=True, text="The provider returned an error.")
    payload = device.open(env.relay.requests[0])
    assert payload["k"] == "reply_failed"
    assert payload["b"] == "The provider returned an error."
    assert payload["dk"] == "hermes:sess-1:sess-1:task:abcd"
    env.relay.requests.clear()
    _turn(env, failed=True, post=False, turn="t2")
    payload = device.open(env.relay.requests[0])
    assert (payload["k"], payload["b"], payload["dk"]) == ("reply_failed", "", "hermes:sess-1:t2")


@pytest.mark.parametrize("text,body", [
    ("<think>private reasoning", ""),
    ("**Done.** <think>the plan", "Done."),
    ("<think>plan</think>**Done.** Here it is.", "Done. Here it is."),
    ("<details><summary>Tool</summary><details>inner</details>secret</details>Visible", "Visible"),
], ids=["open", "open_after_the_answer", "closed", "nested"])
@pytest.mark.parametrize("failed", [False, True], ids=["reply", "reply_failed"])
def test_reply_preview_drops_reasoning_left_open_or_nested(env, text, body, failed):
    device = Device("a")
    env.subscribe(device)
    _turn(env, text=text, failed=failed)
    assert device.open(env.relay.requests[0])["b"] == body
    assert env.sender.cron_payload("j1", "1", "Brief", text)["b"] == body


def test_reply_preview_reads_only_the_start_of_a_huge_reply(env):
    start = time.perf_counter()
    payload = env.sender.reply_payload("reply", "s", "t", "", "<think " * (1_000_000 // 7))
    assert time.perf_counter() - start < 0.25
    assert len(payload["b"]) <= 200
    cut_open = "Answer first. <think>" + "secret reasoning " * 400 + "</think> More."
    assert env.sender.reply_payload("reply", "s", "t", "", cut_open)["b"] == "Answer first.…"


def test_interrupted_turn_does_not_push(env):
    env.subscribe(Device("a"))
    _turn(env, interrupted=True)
    _turn(env, interrupted=True, failed=True)
    assert env.relay.requests == []


def test_session_boundary_is_not_a_turn_end(env):
    env.subscribe(Device("a"))
    env.hooks.on_post_llm_call(session_id="s", turn_id="t", assistant_response="hi", platform="mobile")
    env.hooks.on_session_end(session_id="s", platform="mobile")  # /new or close: no turn kwargs
    env.hooks.dispatcher.join()
    assert env.relay.requests == []
    env.hooks.on_session_end(session_id="s", turn_id="t", failed=False, interrupted=False, platform="mobile")
    env.hooks.dispatcher.join()
    assert len(env.relay.requests) == 1


def test_api_server_reply_pushes_only_while_watched(env):
    device = Device("a")
    env.subscribe(device)
    _turn(env, platform="api_server", session="api-1")
    assert env.relay.requests == []
    assert env.op({"op": "watch", "session_id": "api-1", "ttl": 600})["ok"]
    _turn(env, platform="api_server", session="api-1")
    [request] = env.relay.requests
    assert device.open(request)["ids"]["session"] == "api-1"
    env.relay.requests.clear()
    _turn(env, platform="api_server", session="someone-else")
    assert env.relay.requests == []


@pytest.mark.parametrize("platform", ["cron", "telegram", "cli", "tui", "desktop", "", None])
def test_other_platforms_never_push_replies(env, platform):
    env.subscribe(Device("a"))
    env.op({"op": "watch", "session_id": "sess-1", "ttl": 600})
    _turn(env, platform=platform)
    _turn(env, platform=platform, failed=True)
    assert env.relay.requests == []


def test_reply_respects_subscription_events(env):
    cron_only = Device("cron-only", events=["cron"])
    replies = Device("replies", events=["reply"])
    env.subscribe(cron_only)
    env.subscribe(replies)
    _turn(env)
    _turn(env, failed=True, turn="t2")
    assert env.pushes_for(cron_only) == []
    assert [replies.open(r)["k"] for r in env.pushes_for(replies)] == ["reply"]


def test_hooks_capture_the_profile_home_on_the_agent_thread(env, tmp_path):
    profile_home = tmp_path / "profile"
    profile_home.mkdir()
    device = Device("a")
    env.ops.handle({"op": "subscribe", "sub": device.sub()}, profile_home)
    env.hermes.home = profile_home
    env.hooks.on_post_llm_call(session_id="s", turn_id="t", assistant_response="hi", platform="mobile")
    env.hermes.home = env.home  # the worker thread must not re-resolve it
    env.hooks.on_session_end(session_id="s", turn_id="t", failed=False, interrupted=False, platform="mobile")
    env.hooks.dispatcher.join()
    assert len(env.pushes_for(device)) == 1


def test_hooks_never_raise(env, monkeypatch):
    def broken_home():
        raise RuntimeError("no home")

    monkeypatch.setattr(sys.modules["hermes_constants"], "get_hermes_home", broken_home)
    assert env.hooks.on_post_llm_call(session_id="s", turn_id="t", assistant_response="x", platform="mobile") is None
    assert env.hooks.on_session_end(session_id="s", turn_id="u", failed=True, interrupted=False,
                                    platform="mobile") is None
    assert env.hooks.on_post_llm_call(object(), platform=["weird"]) is None
    assert env.hooks.on_session_end(failed=True) is None


def test_full_queue_drops_instead_of_blocking(env):
    gate = threading.Event()
    dispatcher = env.hooks.Dispatcher(workers=1, maxsize=1)
    assert dispatcher.submit(gate.wait)
    time.sleep(0.05)  # the worker picks up the first job and blocks
    assert dispatcher.submit(lambda: None)
    assert not dispatcher.submit(lambda: None)
    gate.set()
    dispatcher.join()


def test_logs_carry_no_content(env, caplog):
    device = Device("a")
    env.subscribe(device)
    _make_state_db(env.home, "secret-session", "Secret title")
    caplog.set_level(logging.DEBUG)
    env.relay.fail = True
    _turn(env, session="secret-session", turn="secret-turn", text="secret reply text")
    env.relay.fail = False
    env.relay.status = 410
    _turn(env, session="secret-session", turn="secret-turn-2", text="secret reply text")
    text = caplog.text
    assert "conduit push" in text
    for secret in ("secret", "relay.example", device.sid, device.sub()["auth"]):
        assert secret not in text
    logging.getLogger("httpx").info("someone else's request")  # other httpx users still log
    assert "someone else's request" in caplog.text


# -- cron ------------------------------------------------------------------------

WRAPPED = (
    "Cronjob Response: Morning brief\n"
    "(job_id: job42)\n"
    "-------------\n\n"
    "## Weather\nSunny, **22°C**.\n\n"
    "To stop or manage this job, send me a new message (e.g. \"stop reminder Morning brief\")."
)


def test_cron_standalone_lane(env):
    device = Device("a")
    env.subscribe(device)
    result = run(env.adapter.standalone_send(PlatformConfig(), "devices", WRAPPED))
    assert result["success"] is True
    assert result["platform"] == "conduit"
    assert result["chat_id"] == "devices"
    [request] = env.relay.requests
    payload = device.open(request)
    assert payload["k"] == "cron"
    assert payload["t"] == "Morning brief"
    assert payload["b"] == "Weather Sunny, 22°C."
    assert payload["ids"]["job"] == "job42"
    run_id = payload["ids"]["run"]
    assert run_id.isdigit()
    assert payload["dk"] == f"cron:job42:{run_id}" == result["message_id"]
    assert payload["g"] == "cron:job42"
    assert request.headers["TTL"] == "259200"
    assert request.headers["Urgency"] == "normal"
    assert request.headers["Topic"] == wp.topic(device.auth, payload["dk"])


def test_cron_standalone_lane_reports_failures(env):
    assert run(env.adapter.standalone_send(PlatformConfig(), "devices", WRAPPED)) == {
        "error": "conduit: no subscribed devices"}
    env.subscribe(Device("a"))
    env.relay.status = 503
    assert run(env.adapter.standalone_send(PlatformConfig(), "devices", WRAPPED)) == {
        "error": "conduit: push rejected (503)"}
    env.relay.fail = True
    assert run(env.adapter.standalone_send(PlatformConfig(), "devices", WRAPPED)) == {
        "error": "conduit: push rejected (no answer)"}


def test_cron_live_lane_uses_job_metadata(env):
    device = Device("a")
    env.subscribe(device)
    env.hermes.jobs["j9"] = {"id": "j9", "name": "Nightly backup"}
    adapter = env.adapter.ConduitAdapter(PlatformConfig(enabled=True))
    assert run(adapter.connect()) is True
    result = run(adapter.send("devices", "Backup finished: 3 files.", metadata={"job_id": "j9", "notify": True}))
    assert result.success is True
    payload = device.open(env.relay.requests[0])
    assert (payload["k"], payload["t"], payload["b"]) == ("cron", "Nightly backup", "Backup finished: 3 files.")
    assert payload["ids"]["job"] == "j9"
    assert result.message_id == payload["dk"]


def test_cron_live_lane_failure_and_pruning(env):
    device = Device("a")
    env.subscribe(device)
    adapter = env.adapter.ConduitAdapter(PlatformConfig(enabled=True))
    env.relay.status = 410
    result = run(adapter.send("devices", WRAPPED, metadata={"job_id": "job42"}))
    assert result.success is False
    assert result.error == "conduit: push rejected (410)"
    assert env.op({"op": "list"})["sids"] == []


def test_cron_respects_subscription_events(env):
    replies_only = Device("r", events=["reply", "reply_failed"])
    env.subscribe(replies_only)
    assert "error" in run(env.adapter.standalone_send(PlatformConfig(), "devices", WRAPPED))
    assert env.relay.requests == []


CRON_HEADER = "Cronjob Response: Brief\n(job_id: j1)\n-------------\n\n"
CRON_FOOTER = '\n\nTo stop or manage this job, send me a new message (e.g. "stop reminder Brief").'


@pytest.mark.parametrize("output,body", [
    ("Sunny.", "Sunny."),
    ("Sunny." + CRON_FOOTER, "Sunny."),
    ("Sunny.  \n" + CRON_FOOTER + "\n\n  ", "Sunny."),
    ("Sunny." + CRON_FOOTER + "\nMore output.", "Sunny." + CRON_FOOTER + "\nMore output."),
    ("A" + CRON_FOOTER + "\nB" + CRON_FOOTER, "A" + CRON_FOOTER + "\nB"),
])
def test_cron_wrapper_parsing(env, output, body):
    assert env.adapter.parse_cron_content(CRON_HEADER + output) == ("j1", "Brief", body)
    assert env.adapter.parse_cron_content(CRON_HEADER + output, "meta") == ("meta", "Brief", body)


@pytest.mark.parametrize("filler", [" ", "\n", " \n", "-", "\n\nTo stop"], ids=repr)
def test_cron_wrapper_parsing_is_linear(env, filler):
    content = CRON_HEADER + "x" + filler * (1_000_000 // len(filler)) + "y" + CRON_FOOTER
    start = time.perf_counter()
    job, name, body = env.adapter.parse_cron_content(content)
    payload = env.sender.cron_payload(job, "1", name, body)
    assert time.perf_counter() - start < 0.25  # a 40 KB whitespace run used to take 4 s
    assert (job, name) == ("j1", "Brief") and body.endswith("y") and len(payload["b"]) <= 200


def test_cron_wrapper_header_is_read_from_a_bounded_prefix(env):
    long_name = "Cronjob Response: " + "n" * 10_000 + "\n(job_id: j1)\n---\n\nBody"
    assert env.adapter.parse_cron_content(long_name) == ("", "", long_name)


def test_cron_unwrapped_output_without_a_job(env):
    device = Device("a")
    env.subscribe(device)
    assert run(env.adapter.standalone_send(PlatformConfig(), "devices", "Plain output"))["success"]
    payload = device.open(env.relay.requests[0])
    # No job: most likely the agent's send_message tool, so it isn't shown as a job's output.
    assert (payload["k"], payload["t"], payload["b"], payload["g"]) == ("cron", "Hermes", "Plain output", "cron:")


def test_send_message_through_the_live_adapter_is_titled_hermes(env):
    device = Device("a")
    env.subscribe(device)
    env.hermes.jobs["j9"] = {"id": "j9", "name": "Nightly backup"}
    adapter = env.adapter.ConduitAdapter(PlatformConfig(enabled=True))
    # send_message passes no job id; cron's live lane always does.
    assert run(adapter.send("devices", "Hi from the agent", metadata=None)).success
    assert run(adapter.send("devices", "Done.", metadata={"job_id": "j9"})).success
    assert run(adapter.send("devices", "Done.", metadata={"job_id": "gone"})).success
    titles = [(p["t"], p["ids"]["job"]) for p in map(device.open, env.relay.requests)]
    assert titles == [("Hermes", ""), ("Nightly backup", "j9"), ("", "gone")]


# -- adapter and API-server auth -------------------------------------------------

class _ApiServer:
    def __init__(self, key: str) -> None:
        self.key = key

    def _expected_api_key(self) -> str:
        return self.key


def _adapter(env, *, api_key: Optional[str] = None, runner: bool = True):
    adapter = env.adapter.ConduitAdapter(PlatformConfig(enabled=True))
    if runner:
        adapters = {Platform("api_server"): _ApiServer(api_key)} if api_key is not None else {}
        adapter.gateway_runner = types.SimpleNamespace(adapters=adapters)
    return adapter


def test_auth_accepts_the_api_server_key(env):
    adapter = _adapter(env, api_key=GOOD_KEY)
    assert run(adapter.verify_http_event_request(f"Bearer {GOOD_KEY}")) == (True, None)
    assert run(adapter.verify_http_event_request(f"bearer {GOOD_KEY}")) == (True, None)


@pytest.mark.parametrize("header", [
    "", None, "Bearer", f"Basic {GOOD_KEY}", f"Bearer {GOOD_KEY}x", f"Bearer {GOOD_KEY[:-1]}", "Bearer é" * 3,
])
def test_auth_rejects_bad_tokens(env, header):
    adapter = _adapter(env, api_key=GOOD_KEY)
    assert run(adapter.verify_http_event_request(header)) == (False, "conduit_auth_failed")


def test_auth_refuses_short_or_empty_keys(env):
    env.hermes.secrets["API_SERVER_KEY"] = GOOD_KEY
    for key in ("", "short", "x" * 15, " " * 20):
        adapter = _adapter(env, api_key=key)  # the API server's answer wins over the env fallback
        assert run(adapter.verify_http_event_request(f"Bearer {key}")) == (False, "conduit_api_key_unusable")
    assert run(_adapter(env, api_key="x" * 16).verify_http_event_request("Bearer " + "x" * 16)) == (True, None)


def test_auth_falls_back_to_the_scoped_key(env):
    env.hermes.secrets["API_SERVER_KEY"] = GOOD_KEY
    for adapter in (_adapter(env, runner=False), _adapter(env)):
        assert run(adapter.verify_http_event_request(f"Bearer {GOOD_KEY}")) == (True, None)
        assert run(adapter.verify_http_event_request("Bearer nope")) == (False, "conduit_auth_failed")
    env.hermes.secrets.clear()
    assert run(_adapter(env, runner=False).verify_http_event_request("Bearer ")) == (
        False, "conduit_api_key_unusable")


def test_auth_compares_in_constant_time(env, monkeypatch):
    calls = []
    real = env.adapter.hmac.compare_digest

    def spy(a, b):
        calls.append((type(a), type(b)))
        return real(a, b)

    monkeypatch.setattr(env.adapter.hmac, "compare_digest", spy)
    adapter = _adapter(env, api_key=GOOD_KEY)
    run(adapter.verify_http_event_request("Bearer wrong"))
    run(adapter.verify_http_event_request(f"Bearer {GOOD_KEY}"))
    assert calls == [(bytes, bytes), (bytes, bytes)]


def test_auth_fails_closed_when_the_key_lookup_breaks(env):
    adapter = _adapter(env)

    class Broken:
        def _expected_api_key(self):
            raise RuntimeError("boom")

    adapter.gateway_runner.adapters[Platform("api_server")] = Broken()
    assert run(adapter.verify_http_event_request(f"Bearer {GOOD_KEY}")) == (False, "conduit_auth_unavailable")


def test_dispatch_uses_the_adapter_profile_home(env, tmp_path):
    profile_home = tmp_path / "profile"
    profile_home.mkdir()
    env.hermes.home = profile_home
    adapter = _adapter(env, api_key=GOOD_KEY)  # built inside the profile's scope
    env.hermes.home = env.home
    assert run(adapter.dispatch_http_event({"op": "hello"}))["plugin"] == "conduit"
    device = Device("a")
    assert run(adapter.dispatch_http_event({"op": "subscribe", "sub": device.sub()})) == {"ok": True}
    assert (profile_home / "conduit_push" / "subscriptions.json").exists()
    assert not (env.home / "conduit_push").exists()


def test_adapter_basics(env):
    config = PlatformConfig(enabled=True)
    adapter = env.adapter.ConduitAdapter(config)
    assert config.gateway_restart_notification is False
    assert adapter.platform == Platform("conduit")
    assert adapter.splits_long_messages is True
    assert run(adapter.connect()) is True and adapter._running
    assert run(adapter.get_chat_info("devices"))["type"] == "dm"
    run(adapter.disconnect())
    assert not adapter._running


# -- registration ----------------------------------------------------------------

class _Ctx:
    def __init__(self) -> None:
        self.platforms = []
        self.hooks = []

    def register_platform(self, **kwargs: Any) -> None:
        self.platforms.append(kwargs)

    def register_hook(self, name: str, callback: Any) -> None:
        self.hooks.append((name, callback))


def test_register(env):
    ctx = _Ctx()
    env.plugin.register(ctx)
    [platform] = ctx.platforms
    assert platform["name"] == "conduit"
    assert platform["cron_deliver_env_var"] == "CONDUIT_HOME_CHANNEL"
    assert platform["standalone_sender_fn"] is env.adapter.standalone_send
    assert platform["check_fn"]() is True
    assert "is_connected" not in platform  # auto-enabled once its dependencies import
    assert isinstance(platform["adapter_factory"](PlatformConfig()), env.adapter.ConduitAdapter)
    assert platform["env_enablement_fn"]() == {"home_channel": {"chat_id": "devices", "name": "Conduit devices"}}
    env.hermes.secrets["CONDUIT_HOME_CHANNEL"] = "phones"
    assert platform["env_enablement_fn"]()["home_channel"]["chat_id"] == "phones"
    assert ctx.hooks == [("post_llm_call", env.hooks.on_post_llm_call),
                         ("on_session_end", env.hooks.on_session_end)]


def test_manifests_agree():
    manifest = yaml.safe_load((PLUGIN_DIR / "plugin.yaml").read_text())
    dashboard = json.loads((PLUGIN_DIR / "dashboard" / "manifest.json").read_text())
    init = (PLUGIN_DIR / "__init__.py").read_text()
    assert manifest["name"] == dashboard["name"] == "conduit"
    assert manifest["kind"] == "platform"
    assert f'VERSION = "{manifest["version"]}"' in init
    assert dashboard["version"] == manifest["version"]
    assert dashboard["tab"]["hidden"] is True
    assert dashboard["api"] == "plugin_api.py"
    assert (PLUGIN_DIR / "dashboard" / dashboard["entry"]).is_file()
    assert set(manifest["provides_hooks"]) == {"post_llm_call", "on_session_end"}


# -- dashboard routes --------------------------------------------------------------

@pytest.fixture
def dashboard(tmp_path, monkeypatch):
    """``plugin_api.py`` loaded the way the dashboard mounts it, with no gateway modules."""
    home = tmp_path / "home"
    home.mkdir()
    hermes = Hermes(home)
    for name, module in hermes.modules(gateway=False).items():
        monkeypatch.setitem(sys.modules, name, module)
    for name in [n for n in sys.modules if n == "gateway" or n.startswith("gateway.")]:
        monkeypatch.delitem(sys.modules, name)
    _evict("hermes_conduit_push_core")
    name = "hermes_dashboard_plugin_conduit"
    spec = importlib.util.spec_from_file_location(name, PLUGIN_DIR / "dashboard" / "plugin_api.py")
    module = importlib.util.module_from_spec(spec)
    monkeypatch.setitem(sys.modules, name, module)
    spec.loader.exec_module(module)
    yield types.SimpleNamespace(api=module, hermes=hermes, home=home)
    _evict("hermes_conduit_push_core")


def test_dashboard_routes(dashboard):
    api = dashboard.api
    assert set(api.router.routes) == {("GET", "/v1/hello"), ("POST", "/v1/events")}
    assert run(api.router.routes[("GET", "/v1/hello")]())["plugin"] == "conduit"
    status, body = api.handle_events(b'{"op": "hello"}', None)
    assert (status, body["version"]) == (200, "1.0.0")
    device = Device("a")
    status, body = api.handle_events(json.dumps({"op": "subscribe", "sub": device.sub()}).encode(), "current")
    assert (status, body) == (200, {"ok": True})
    assert (dashboard.home / "conduit_push" / "subscriptions.json").exists()
    assert not any(n == "gateway" or n.startswith("gateway.") for n in sys.modules)


def test_dashboard_profiles(dashboard, tmp_path):
    work = tmp_path / "profiles" / "work"
    work.mkdir(parents=True)
    dashboard.hermes.profiles["work"] = work
    device = Device("a")
    body = json.dumps({"op": "subscribe", "sub": device.sub()}).encode()
    assert dashboard.api.handle_events(body, "Work") == (200, {"ok": True})
    assert (work / "conduit_push" / "subscriptions.json").exists()
    assert not (dashboard.home / "conduit_push").exists()
    assert dashboard.api.handle_events(body, "nope") == (404, {"ok": False, "error": "unknown_profile"})
    assert dashboard.api.handle_events(body, "bad name!") == (400, {"ok": False, "error": "invalid_profile"})


class _StreamedRequest:
    """Starlette's Request as the events route uses it, counting chunks read."""

    def __init__(self, chunks, content_length=None) -> None:
        self.headers = {} if content_length is None else {"content-length": str(content_length)}
        self.chunks = list(chunks)
        self.read = 0

    async def stream(self):
        for chunk in self.chunks:
            self.read += 1
            yield chunk


def test_dashboard_refuses_large_bodies_while_reading(dashboard):
    route = dashboard.api.router.routes[("POST", "/v1/events")]
    declared = _StreamedRequest([b"{}"], content_length=10 ** 9)
    response = run(route(declared, profile=None))
    assert (response.status_code, response.content) == (413, {"ok": False, "error": "too_large"})
    assert declared.read == 0

    chunked = _StreamedRequest([b"x" * 4096] * 1000)  # 4 MB without a Content-Length
    response = run(route(chunked, profile=None))
    assert response.status_code == 413 and chunked.read == 5

    lying = _StreamedRequest([b"x" * 4096] * 1000, content_length=2)
    assert run(route(lying, profile=None)).status_code == 413 and lying.read == 5

    hello = _StreamedRequest([b'{"op": ', b'"hello"}'], content_length=15)
    response = run(route(hello, profile=None))
    assert (response.status_code, response.content["plugin"]) == (200, "conduit")

    at_limit = _StreamedRequest([b" " * (16384 - 15), b'{"op": "hello"}'], content_length="junk")
    assert run(route(at_limit, profile=None)).status_code == 200


def test_dashboard_body_cap_with_starlette(dashboard):
    requests = pytest.importorskip("starlette.requests")

    def request(chunks, headers=()):
        messages = [{"type": "http.request", "body": c, "more_body": i < len(chunks) - 1} for i, c in enumerate(chunks)]
        received = []

        async def receive():
            received.append(1)
            return messages[len(received) - 1]

        scope = {"type": "http", "method": "POST", "path": "/", "headers": list(headers), "query_string": b""}
        return requests.Request(scope, receive), received

    big, received = request([b"x" * 4096] * 1000)
    assert run(dashboard.api.read_capped(big)) is None and len(received) == 5
    declared, received = request([b"{}"], [(b"content-length", b"999999")])
    assert run(dashboard.api.read_capped(declared)) is None and received == []
    small, _ = request([b'{"op":', b'"hello"}'])
    assert run(dashboard.api.read_capped(small)) == b'{"op":"hello"}'


def test_dashboard_rejects_bad_bodies(dashboard):
    api = dashboard.api
    assert api.handle_events(b"x" * 20000, None) == (413, {"ok": False, "error": "too_large"})
    assert api.handle_events(b"{nope", None) == (400, {"ok": False, "error": "invalid_json"})
    assert api.handle_events(b"\xff", None) == (400, {"ok": False, "error": "invalid_json"})
    assert api.handle_events(b"[1]", None) == (400, {"ok": False, "error": "invalid_request"})


# -- shared library copy ---------------------------------------------------------

def _load_sync():
    spec = importlib.util.spec_from_file_location("hermes_sync_under_test", HERMES_DIR / "sync.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_sync_copy_is_current():
    assert _load_sync().stale() == []
    result = subprocess.run(
        [sys.executable, str(HERMES_DIR / "sync.py"), "--check"], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_sync_detects_and_fixes_drift(tmp_path):
    sync = _load_sync()
    source, target = tmp_path / "src", tmp_path / "dst"
    source.mkdir()
    (source / "a.py").write_text("A = 1\n")
    (source / "b.py").write_text("B = 1\n")
    assert sync.stale(source, target) == ["a.py", "b.py"]
    assert sync.sync(source, target) == ["a.py", "b.py"]
    assert sync.stale(source, target) == []
    (target / "a.py").write_text("A = 2\n")
    (target / "extra.py").write_text("")
    assert sync.stale(source, target) == ["a.py", "extra.py"]
    sync.sync(source, target)
    assert sorted(p.name for p in target.iterdir()) == ["a.py", "b.py"]
    assert (target / "a.py").read_text() == "A = 1\n"
