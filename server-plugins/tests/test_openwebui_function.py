"""Tests for the generated Open WebUI "Conduit Push" Event function.

The function is loaded from the generated file the way Open WebUI loads it,
against in-memory stand-ins for the Open WebUI internals it uses and for
aiohttp. Every captured push is decrypted with the device's private key.
"""

import ast
import asyncio
import copy
import inspect
import json
import logging
import os
import re
import socket
import subprocess
import sys
import time
import types
from pathlib import Path
from types import SimpleNamespace

import pytest
from cryptography.hazmat.primitives.asymmetric import ec

from conduit_webpush import webpush as wp

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "server-plugins" / "openwebui" / "build.py"
BUILT = ROOT / "server-plugins" / "openwebui" / "conduit_push.py"
ASSET = ROOT / "assets" / "server_plugins" / "openwebui_conduit_push.py"
LIBRARY = ROOT / "server-plugins" / "common" / "conduit_webpush"
FID = "conduit_push"
DAY = 86400


# Devices and the fake server


class Device:
    """A phone: its own key pair, auth secret, sid and endpoint."""

    def __init__(self, host="relay.example", did=None, events=None, origin=None, seen=None, test=None, **extra):
        key = ec.generate_private_key(ec.SECP256R1())
        self.private = wp.private_bytes(key)
        self.auth = os.urandom(16)
        self.sid = wp.b64u_encode(os.urandom(16))
        self.endpoint = "https://%s/v1/push/%s" % (host, wp.b64u_encode(os.urandom(24)))
        self.entry = {
            "sid": self.sid,
            "did": did or wp.b64u_encode(os.urandom(8)),
            "endpoint": self.endpoint,
            "p256dh": wp.b64u_encode(wp.public_bytes_of(key)),
            "auth": wp.b64u_encode(self.auth),
            "events": list(events) if events is not None else ["reply", "reply_failed", "channel"],
            "origin": origin or "conduit",
            "label": "Phone",
            "platform": "ios",
            "proto": 1,
            "seen": int(time.time()) if seen is None else seen,
        }
        if test is not None:
            self.entry["test"] = test
        self.entry.update(extra)

    def open(self, post):
        """Decrypts a captured push the way the device does."""
        return json.loads(wp.decrypt(post.body, self.private, self.auth))


class Headers(dict):
    """Case-insensitive like Starlette's request headers."""

    def __init__(self, values):
        super().__init__({key.lower(): value for key, value in values.items()})

    def get(self, key, default=None):
        return super().get(key.lower(), default)


def request(agent):
    return SimpleNamespace(headers=Headers({"User-Agent": agent} if agent else {}))


class World:
    def __init__(self):
        self.valves = {}
        self.encrypted = set()
        self.names = {}
        self.channels = {}
        self.members = {}
        self.messages = {}
        self.access = {}
        self.titles = {}
        self.blocked_hosts = set()
        self.dns = {}  # host -> addresses; any other name resolves to a public address
        self.validated = []
        self.responses = {}
        self.posts = []
        self.sessions = []
        self.writes = []
        self.fail = set()
        self.gate = None
        self.calls = []
        self.after_read = {}  # nth valves read -> what happens right after it

    def subscribe(self, user_id, *devices, status=None, raw=None):
        entries = raw if raw is not None else [device.entry for device in devices]
        self.valves[user_id] = {"subscriptions": json.dumps(entries), "status": json.dumps(status or {})}

    def stored(self, user_id):
        return json.loads(self.valves[user_id]["subscriptions"])

    def status(self, user_id):
        return json.loads(self.valves[user_id]["status"])

    def posts_to(self, device):
        return [post for post in self.posts if post.url == device.endpoint]


class Session:
    def __init__(self, world, safe):
        self.world = world
        self.safe = safe
        self.closed = False
        world.sessions.append(self)

    def post(self, url, data=None, headers=None, timeout=None, allow_redirects=True, ssl=None):
        return _Post(self, url, data, headers, timeout, allow_redirects, ssl)

    async def close(self):
        self.closed = True


class _Post:
    def __init__(self, session, url, data, headers, timeout, allow_redirects, ssl):
        self.session = session
        self.record = SimpleNamespace(
            url=url, body=data, headers=headers, safe=session.safe,
            timeout=timeout.total, allow_redirects=allow_redirects, ssl=ssl,
        )

    async def __aenter__(self):
        world = self.session.world
        world.posts.append(self.record)
        if world.gate is not None:
            await world.gate.wait()
        outcome = world.responses.get(self.record.url, 201)
        if callable(outcome):
            outcome = outcome()
        if isinstance(outcome, BaseException):
            raise outcome
        return SimpleNamespace(status=outcome)

    async def __aexit__(self, *exc):
        return False


def _install(monkeypatch, world, real_aiohttp=False):
    """Puts stand-ins for the Open WebUI modules the function imports into sys.modules.

    Unless `real_aiohttp`, aiohttp and DNS are faked too.
    """

    def module(name, **attrs):
        mod = types.ModuleType(name)
        mod.__dict__.update(attrs)
        monkeypatch.setitem(sys.modules, name, mod)
        return mod

    def check(name):
        world.calls.append(name)
        if name in world.fail:
            raise RuntimeError("database is down: " + name)

    class Functions:
        async def get_user_valves_by_id_and_user_id(self, id, user_id, db=None):
            check("get_user_valves")
            assert id == FID
            found = copy.deepcopy(world.valves.get(user_id, {}))
            # Something else writing right after this read, e.g. the app over REST.
            after = world.after_read.pop(world.calls.count("get_user_valves"), None)
            if after is not None:
                after()
            return found

        async def update_user_valves_by_id_and_user_id(self, id, user_id, valves, db=None):
            check("update_user_valves")
            world.writes.append((user_id, copy.deepcopy(valves)))
            world.valves[user_id] = copy.deepcopy(valves)
            return valves

    class Settings:
        def __init__(self, data):
            self.data = data

        def model_dump(self):
            return copy.deepcopy(self.data)

    class Users:
        async def get_users_by_user_ids(self, user_ids, db=None):
            check("get_users")
            users = []
            for uid in user_ids:
                stored = world.valves.get(uid)
                if uid in world.encrypted and stored is not None:
                    stored = "enc:" + json.dumps(stored)
                settings = Settings({"ui": {}, "functions": {"valves": {FID: stored}}}) if stored else None
                users.append(SimpleNamespace(id=uid, name=world.names.get(uid, uid), settings=settings))
            return users

    class Channels:
        async def get_channel_by_id(self, id, db=None):
            check("get_channel")
            channel = world.channels.get(id)
            return SimpleNamespace(**channel) if channel else None

        async def get_members_by_channel_id(self, channel_id, db=None):
            check("get_members")
            return [SimpleNamespace(**member) for member in world.members.get(channel_id, [])]

    class Messages:
        async def get_message_by_id(self, id, include_thread_replies=True, db=None):
            check("get_message")
            message = world.messages.get(id)
            return SimpleNamespace(**message) if message else None

    class Chats:
        async def get_chat_title_by_id(self, id):
            check("get_chat_title")
            return world.titles.get(id)

    async def get_channel_users_with_access(channel, permission="read", db=None):
        check("access")
        assert permission == "read"
        return [SimpleNamespace(id=uid) for uid in world.access.get(channel.id, ())]

    def validate_url(url):
        world.validated.append(url)
        if url.split("/")[2] in world.blocked_hosts:
            raise ValueError("Oops! The URL you provided is invalid.")
        return True

    def decrypt_valves(value):
        return json.loads(value[4:]) if isinstance(value, str) and value.startswith("enc:") else {}

    class ClientTimeout:
        def __init__(self, total=None):
            self.total = total

    for name in ("open_webui", "open_webui.models", "open_webui.routers", "open_webui.retrieval",
                 "open_webui.retrieval.web", "open_webui.utils"):
        module(name)
    module("open_webui.models.functions", Functions=Functions())
    module("open_webui.models.users", Users=Users())
    module("open_webui.models.channels", Channels=Channels())
    module("open_webui.models.messages", Messages=Messages())
    module("open_webui.models.chats", Chats=Chats())
    module("open_webui.routers.channels", get_channel_users_with_access=get_channel_users_with_access)
    # The function must not rely on Open WebUI's SSRF-safe session, so none is offered.
    module("open_webui.retrieval.web.utils", validate_url=validate_url)
    module("open_webui.utils.valves", decrypt_valves=decrypt_valves)
    module("open_webui.env", AIOHTTP_CLIENT_SESSION_SSL=True)
    if real_aiohttp:
        return

    class TCPConnector:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    module("aiohttp.abc", AbstractResolver=object)
    module(
        "aiohttp",
        # A session is "safe" when it connects through the function's public-only connector.
        ClientSession=lambda trust_env=False, connector=None, **kw: Session(world, safe=connector is not None),
        ClientTimeout=ClientTimeout,
        ClientError=type("ClientError", (Exception,), {}),
        TCPConnector=TCPConnector,
        ThreadedResolver=object,
    )

    def getaddrinfo(host, port, *args, **kwargs):
        if host not in world.dns:
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", port))]
        if not world.dns[host]:
            raise socket.gaierror("no such host")
        return [(socket.AF_INET6 if ":" in a else socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, port))
                for a in world.dns[host]]

    monkeypatch.setattr(socket, "getaddrinfo", getaddrinfo)


def load_function(monkeypatch):
    """Loads the generated file the way open_webui.utils.plugin.load_function_module_by_id does."""
    content = BUILT.read_text(encoding="utf-8")
    module = types.ModuleType("function_" + FID)
    monkeypatch.setitem(sys.modules, module.__name__, module)
    exec(content, module.__dict__)
    return module


@pytest.fixture
def world(monkeypatch):
    world = World()
    _install(monkeypatch, world)
    return world


@pytest.fixture
def plugin(monkeypatch, world):
    return load_function(monkeypatch)


@pytest.fixture
def fn(plugin):
    return plugin.Event()


def dispatch(fn, name, data=None, actor=None, subject=None, req=None, admin=None, fid=FID):
    """Calls the handler the way open_webui.events.dispatch_event_functions does, then waits for sends."""
    resource, _, operation = name.rpartition(".")
    event = {
        "schema": "0.11.4", "id": "evt", "event": name, "resource": resource, "operation": operation,
        "created_at": int(time.time()), "instance_id": None, "version": "0.11.4", "source": "api",
        "actor": actor, "subject": subject, "data": data or {}, "message": None,
    }
    fn.valves = fn.Valves(**(admin or {}))
    extra = {
        "event": event, "__id__": fid, "__event__": SimpleNamespace(**event), "__event_id__": "evt",
        "__event_name__": name, "__app__": SimpleNamespace(), "__request__": req,
    }
    params = inspect.signature(fn.event).parameters
    takes_kwargs = any(p.kind == inspect.Parameter.VAR_KEYWORD for p in params.values())
    args = {key: value for key, value in extra.items() if takes_kwargs or key in params}

    async def run():
        await fn.event(**args)
        await fn._wait_idle()

    asyncio.run(run())


def finished(user="u1", chat="c1", msg="m1", title="Trip ideas", message="Here are **three** routes.", req=None, **kw):
    data = {"user_id": user, "chat_id": chat, "message_id": msg, "model_id": "gpt", "title": title,
            "url": "/c/" + chat, "message": message}
    return dict(name="chat.finished", data=data, actor={"id": user, "name": "U", "type": "user"},
                subject={"type": "chat", "id": chat}, req=req, **kw)


def failed(user="u1", chat="c1", msg="m1", req=None, **kw):
    data = {"user_id": user, "chat_id": chat, "message_id": msg, "model_id": "gpt",
            "url": "/c/" + chat, "message": "Upstream said 500 with secret details"}
    return dict(name="chat.failed", data=data, actor={"id": user, "name": "U", "type": "user"},
                subject={"type": "chat", "id": chat}, req=req, **kw)


def valves_updated(user="u1", fid=FID, scope="user"):
    data = {"scope": scope} if scope else {}
    return dict(name="function.valves_updated", data=data, actor={"id": user, "name": "U", "type": "user"},
                subject={"type": "function", "id": fid})


def assert_push(device, post, kind, dk, ttl):
    assert len(post.body) in (wp.HEADER_LEN + bucket for bucket in wp.BUCKETS)
    assert post.headers["Content-Encoding"] == "aes128gcm"
    assert post.headers["Content-Type"] == "application/octet-stream"
    assert post.headers["TTL"] == str(ttl)
    assert post.headers["Urgency"] == "high"
    assert post.headers["Topic"] == wp.topic(device.auth, dk)
    assert post.allow_redirects is False
    payload = device.open(post)
    assert payload["v"] == 1 and payload["k"] == kind and payload["src"] == "owui"
    assert payload["dk"] == dk
    assert abs(payload["ts"] - time.time()) < 60
    return payload


# The generated file


def owui_frontmatter(content):
    """Copy of open_webui/utils/plugin.py extract_frontmatter (0.11.4)."""
    frontmatter = {}
    lines = content.splitlines()
    if len(lines) < 1 or lines[0].strip() != '"""':
        return {}
    pattern = re.compile(r"^\s*([a-z_]+):\s*(.*)\s*$", re.IGNORECASE)
    for line in lines[1:]:
        if '"""' in line:
            break
        match = pattern.match(line)
        if match:
            key, value = match.groups()
            frontmatter[key.strip()] = value.strip()
    return frontmatter


def test_frontmatter_becomes_the_manifest():
    manifest = owui_frontmatter(BUILT.read_text(encoding="utf-8"))
    assert set(manifest) == {
        "title", "author", "author_url", "version", "required_open_webui_version",
        "license", "description", "conduit_protocol",
    }
    assert manifest["title"] == "Conduit Push"
    assert manifest["version"] == "1.0.0"
    assert manifest["required_open_webui_version"] == "0.10.0"
    assert manifest["conduit_protocol"] == "1"
    assert manifest["license"] == "GPL-3.0"


def test_generated_copies_match_and_inline_the_library_verbatim():
    content = BUILT.read_text(encoding="utf-8")
    assert ASSET.read_text(encoding="utf-8") == content
    sources = None
    for node in ast.parse(content).body:
        if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "_CONDUIT_WEBPUSH_SOURCES":
            sources = ast.literal_eval(node.value)
    assert sources == {
        name: (LIBRARY / (name + ".py")).read_text(encoding="utf-8") for name in ("webpush", "payload")
    }
    # open_webui.utils.plugin.replace_imports rewrites these anywhere in the source.
    for needle in ("from utils", "from apps", "from main", "from config"):
        assert needle not in content


def test_build_check_passes():
    result = subprocess.run([sys.executable, str(BUILD), "--check"], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_loads_as_an_event_function(plugin, fn):
    # open_webui.utils.plugin picks the type by class name, Pipe/Filter/Action first.
    assert not any(hasattr(plugin, name) for name in ("Pipe", "Filter", "Action"))
    assert isinstance(fn, plugin.Event)
    assert fn.valves.model_dump() == {
        "allow_private_endpoints": False, "extra_allowed_hosts": "", "max_subscriptions_per_user": 10,
        "timeout_s": 5, "max_channel_recipients": 500,
    }
    user = fn.UserValves()
    assert user.subscriptions == "[]" and user.status == "{}"
    assert fn.UserValves.model_json_schema()["properties"]["subscriptions"]["description"] == (
        "Managed by Conduit. Do not edit."
    )
    # The library runs from private modules, not from the shared package.
    assert plugin.webpush.__name__ == "function_conduit_push._conduit_webpush.webpush"
    assert plugin.cp.webpush is plugin.webpush


# Replies


def test_reply_from_conduit_reaches_every_subscribed_device(world, fn):
    phone, tablet = Device(), Device(origin="any")
    world.subscribe("u1", phone, tablet)
    dispatch(fn, **finished(req=request("Conduit/2.4.1 (iOS)")))
    assert len(world.posts) == 2
    for device in (phone, tablet):
        (post,) = world.posts_to(device)
        payload = assert_push(device, post, "reply", "chat:c1:m1", 86400)
        assert payload["ids"] == {"chat": "c1", "msg": "m1"}
        assert payload["t"] == "Trip ideas"
        assert payload["b"] == "Here are three routes."
        assert payload["g"] == "chat:c1"
        assert "n" not in payload and "a" not in payload
        assert post.safe is True and post.timeout == 5 and post.ssl is True
    assert all(session.closed for session in world.sessions)


@pytest.mark.parametrize("agent", ["Conduit", " Conduit/2.4.1 "])
def test_reply_from_conduit_before_and_after_it_knows_its_version(world, fn, agent):
    phone = Device()
    world.subscribe("u1", phone)
    dispatch(fn, **finished(req=request(agent)))
    assert [post.url for post in world.posts] == [phone.endpoint]


@pytest.mark.parametrize(
    "req",
    [request("Mozilla/5.0"), request("conduit/2.4.1"), request("Conduitx/1"), request(""), None],
)
def test_reply_from_other_clients_only_reaches_any_origin(world, fn, req):
    phone, tablet = Device(), Device(origin="any")
    world.subscribe("u1", phone, tablet)
    dispatch(fn, **finished(req=req))
    assert [post.url for post in world.posts] == [tablet.endpoint]


def test_events_filter_and_failed_replies(world, fn):
    channels_only = Device(events=["channel"], origin="any")
    replies_only = Device(events=["reply"], origin="any")
    failures_only = Device(events=["reply_failed"], origin="any")
    world.subscribe("u1", channels_only, replies_only, failures_only)
    world.titles["c1"] = "Trip ideas"

    dispatch(fn, **finished())
    assert [post.url for post in world.posts] == [replies_only.endpoint]

    world.posts.clear()
    dispatch(fn, **failed())
    (post,) = world.posts
    assert post.url == failures_only.endpoint
    payload = assert_push(failures_only, post, "reply_failed", "chat:c1:m1", 86400)
    assert payload["t"] == "Trip ideas" and payload["b"] == ""
    assert payload["ids"] == {"chat": "c1", "msg": "m1"} and payload["g"] == "chat:c1"


def test_reply_preview_hides_reasoning_even_when_cut_short(world, fn):
    phone = Device(origin="any")
    world.subscribe("u1", phone)
    dispatch(fn, **finished(message="<think>plan the answer</think>\n\n# Routes\n\nTake the [coast](https://x.y) road."))
    # Open WebUI cuts event strings at 1000 characters and appends "...".
    dispatch(fn, **finished(msg="m2", message=("<think>" + "secret reasoning " * 80)[:1000] + "..."))
    dispatch(fn, **finished(msg="m3", message=("word " * 300)[:1000] + "..."))
    first, second, third = (phone.open(post) for post in world.posts)
    assert first["b"] == "Routes Take the coast road."
    assert second["b"] == ""
    assert len(third["b"]) == 200 and third["b"].endswith("…")


def test_replies_for_users_without_subscriptions_send_nothing(world, fn):
    dispatch(fn, **finished())
    assert world.posts == [] and world.writes == []


# Channels


def channel_world(world, kind="group", name="design", members=("a", "b", "c"), muted=(), access=None):
    world.names.update({"a": "Alice", "b": "Bob", "c": "Carol", "d": "Dan"})
    world.channels["ch1"] = {"id": "ch1", "type": kind, "name": name, "deleted_at": None, "archived_at": None}
    world.members["ch1"] = [{"user_id": uid, "is_channel_muted": uid in muted} for uid in members]
    if access is not None:
        world.access["ch1"] = set(access)
    world.messages["msg1"] = {
        "id": "msg1", "channel_id": "ch1", "user_id": "a", "parent_id": None,
        "content": "Hi <@U:b|Bob>, see **this**", "user": {"id": "a", "name": "Alice"},
    }
    devices = {}
    for uid in ("a", "b", "c", "d"):
        devices[uid] = Device()
        world.subscribe(uid, devices[uid])
    return devices


def posted(world, actor_name="Alice", actor_id="a", actor_type="user", message="msg1"):
    data = {"channel_id": "ch1", "content_preview": "Hi"}
    return dict(name="message.created", data=data, actor={"id": actor_id, "name": actor_name, "type": actor_type},
                subject={"type": "message", "id": message})


def test_group_channel_message_reaches_other_members(world, fn):
    devices = channel_world(world, muted=("c",), members=("a", "b", "c", "d"))
    dispatch(fn, **posted(world))
    assert sorted(post.url for post in world.posts) == sorted([devices["b"].endpoint, devices["d"].endpoint])
    payload = assert_push(devices["b"], world.posts_to(devices["b"])[0], "channel", "channel:ch1:msg1", 86400)
    assert payload["ids"] == {"channel": "ch1", "msg": "msg1"}
    assert payload["t"] == "#design"
    assert payload["a"] == "Alice"
    assert payload["b"] == "Hi @Bob, see this"
    assert payload["g"] == "channel:ch1"


def test_standard_channel_requires_read_access_and_membership(world, fn):
    devices = channel_world(world, kind=None, access=("a", "b", "d"))
    dispatch(fn, **posted(world))
    # c is a member without access; d has access but never joined.
    assert [post.url for post in world.posts] == [devices["b"].endpoint]


def test_dm_title_is_the_sender(world, fn):
    devices = channel_world(world, kind="dm", name="", members=("a", "b"))
    dispatch(fn, **posted(world))
    (post,) = world.posts
    payload = devices["b"].open(post)
    assert payload["t"] == "Alice" and payload["a"] == "Alice"


def test_thread_replies_and_chat_messages_do_not_notify(world, fn):
    channel_world(world)
    world.messages["msg1"]["parent_id"] = "root"
    dispatch(fn, **posted(world))
    assert world.posts == []

    world.calls.clear()
    dispatch(fn, name="message.created", data={"chat_id": "c1", "role": "user", "content_preview": "hi"},
             actor={"id": "a", "type": "user"}, subject={"type": "message", "id": "m1"})
    assert world.posts == [] and world.calls == []


def test_falls_back_to_members_without_the_access_helper(world, fn, monkeypatch):
    devices = channel_world(world, kind=None, access=("a", "b"))
    monkeypatch.setitem(sys.modules, "open_webui.routers.channels", None)
    dispatch(fn, **posted(world))
    assert sorted(post.url for post in world.posts) == sorted([devices["b"].endpoint, devices["c"].endpoint])


def test_access_lookup_failure_sends_nothing(world, fn):
    channel_world(world, kind=None, access=("a", "b"))
    world.fail.add("access")
    dispatch(fn, **posted(world))
    assert world.posts == []


@pytest.mark.parametrize("cap,count", [(1, 1), (0, 0)])
def test_channel_recipients_are_capped(world, fn, cap, count):
    channel_world(world)
    dispatch(fn, admin={"max_channel_recipients": cap}, **posted(world))
    assert len(world.posts) == count


def test_channel_reads_encrypted_valves_and_survives_a_failed_batch_read(world, fn):
    devices = channel_world(world)
    world.encrypted.add("b")
    dispatch(fn, **posted(world))
    assert sorted(post.url for post in world.posts) == sorted([devices["b"].endpoint, devices["c"].endpoint])

    world.posts.clear()
    world.fail.add("get_users")
    dispatch(fn, **posted(world))
    assert sorted(post.url for post in world.posts) == sorted([devices["b"].endpoint, devices["c"].endpoint])


MEGABYTE = 1_000_000
FAST_ENOUGH_S = 0.25  # 50 KB of "[" used to take seconds


def _elapsed(fn, *args):
    start = time.perf_counter()
    fn(*args)
    return time.perf_counter() - start


@pytest.mark.parametrize(
    "text",
    ["[" * MEGABYTE, "![" * (MEGABYTE // 2), "<@U:" * (MEGABYTE // 4), "<@U:x|" * (MEGABYTE // 6),
     "<details>" * (MEGABYTE // 9), "<think " * (MEGABYTE // 7)],
    ids=["brackets", "images", "mentions", "labelled_mentions", "details", "think"],
)
def test_preview_of_a_huge_message_is_fast(plugin, text):
    assert _elapsed(plugin._preview, text) < FAST_ENOUGH_S
    assert _elapsed(plugin._MENTION.sub, "", text) < FAST_ENOUGH_S


def test_preview_reads_only_the_start_of_a_long_message(plugin):
    preview = plugin._preview("Hi <@U:b|Bob>, " + "[" * MEGABYTE)
    assert preview.startswith("Hi @Bob, [[[") and preview.endswith("…")
    assert plugin._preview("Look: <think>" + "secret " * 1000) == "Look:…"


def test_huge_channel_message_notifies_with_a_short_preview(world, fn):
    devices = channel_world(world)
    world.messages["msg1"]["content"] = "Hi <@U:b|Bob>, " + "[" * MEGABYTE
    assert _elapsed(lambda: dispatch(fn, **posted(world))) < 1.0
    payload = devices["b"].open(world.posts_to(devices["b"])[0])
    assert payload["b"].startswith("Hi @Bob, [[[") and len(payload["b"]) == 200


def test_webhook_messages_notify_every_member(world, fn):
    devices = channel_world(world)
    dispatch(fn, **posted(world, actor_name="CI bot", actor_id="hook1", actor_type="webhook"))
    assert len(world.posts) == 3
    payload = devices["a"].open(world.posts_to(devices["a"])[0])
    assert payload["a"] == "CI bot" and payload["t"] == "#design"


# Pruning and status


def test_gone_endpoints_are_pruned(world, fn):
    gone, missing, fine = Device(origin="any"), Device(origin="any"), Device(origin="any")
    world.subscribe("u1", gone, missing, fine)
    world.responses[gone.endpoint] = 410
    world.responses[missing.endpoint] = 404
    dispatch(fn, **finished())
    assert len(world.posts) == 3
    assert [entry["sid"] for entry in world.stored("u1")] == [fine.sid]
    status = world.status("u1")
    assert {sid: (s["code"], s["err"]) for sid, s in status.items()} == {
        gone.sid: (410, "gone"), missing.sid: (404, "gone"), fine.sid: (201, None),
    }
    assert len(world.writes) == 1


def test_pruning_keeps_a_device_that_resubscribed_meanwhile(world, fn):
    phone = Device(origin="any")
    world.subscribe("u1", phone)
    renewed = dict(phone.entry, endpoint="https://relay.example/v1/push/renewed")

    def resubscribe_then_410():
        world.subscribe("u1", raw=[renewed])
        return 410

    world.responses[phone.endpoint] = resubscribe_then_410
    dispatch(fn, **finished())
    assert world.stored("u1") == [renewed]
    assert world.status("u1")[phone.sid]["code"] == 410


def test_commit_applies_its_change_to_a_fresh_read(world, fn, plugin, monkeypatch):
    gone, fine, newcomer = Device(origin="any"), Device(origin="any"), Device(origin="any")
    world.subscribe("u1", gone, fine)
    world.responses[gone.endpoint] = 410
    parsed_by_commit = []
    parse = plugin._parse_subscription
    monkeypatch.setattr(plugin, "_parse_subscription", lambda raw: parsed_by_commit.append(raw["sid"]) or parse(raw))

    def app_subscribes_a_device():
        stored = world.valves["u1"]
        stored["subscriptions"] = json.dumps(world.stored("u1") + [newcomer.entry])

    # Read 1 finds the targets; read 2 is the commit's first look, and the app
    # writes right after it.
    world.after_read[2] = app_subscribes_a_device
    dispatch(fn, **finished())
    assert [entry["sid"] for entry in world.stored("u1")] == [fine.sid, newcomer.sid]
    assert {sid: s["err"] for sid, s in world.status("u1").items()} == {gone.sid: "gone", fine.sid: None}
    assert world.calls.count("get_user_valves") == 3 and len(world.writes) == 1
    # The fresh read only parses what changed since the first look.
    assert parsed_by_commit == [gone.sid, fine.sid, newcomer.sid]

    # Nothing to change: one look, no second read and no write.
    delivered = {"code": 201, "at": int(time.time()), "err": None}
    world.subscribe("u1", fine, newcomer, status={fine.sid: delivered, newcomer.sid: delivered})
    world.calls.clear()
    writes = len(world.writes)
    dispatch(fn, **finished(msg="m2"))
    assert world.calls.count("get_user_valves") == 2 and len(world.writes) == writes


def test_status_is_written_only_when_it_changes(world, fn):
    phone = Device(origin="any")
    world.subscribe("u1", phone)
    dispatch(fn, **finished())
    dispatch(fn, **finished(msg="m2"))
    assert len(world.writes) == 1
    world.responses[phone.endpoint] = 429
    dispatch(fn, **finished(msg="m3"))
    assert world.status("u1")[phone.sid]["err"] == "rate_limited"
    world.responses[phone.endpoint] = 201
    dispatch(fn, **finished(msg="m4"))
    assert world.status("u1")[phone.sid] == {"code": 201, "at": pytest.approx(time.time(), abs=60), "err": None}
    assert len(world.writes) == 3


# Subscribing (valves updates)


def test_valves_update_normalizes_subscriptions(world, fn):
    now = int(time.time())
    newer, older = Device(did="same", seen=now - 10), Device(did="same", seen=now - 100)
    stale = Device(seen=now - 31 * DAY)
    future = Device(proto=2)
    oldest_over_cap = Device(seen=now - 50)
    bad_key = Device()
    bad_key.entry["p256dh"] = wp.b64u_encode(os.urandom(64))
    off_curve = Device()
    off_curve.entry["p256dh"] = wp.b64u_encode(b"\x04" + b"\x01" * 64)
    bad_auth = Device()
    bad_auth.entry["auth"] = wp.b64u_encode(os.urandom(15))
    plain_http = Device()
    plain_http.entry["endpoint"] = plain_http.endpoint.replace("https://", "http://")
    bad_sid = Device(sid="not-a-sid")
    keepers = [newer, Device(seen=now - 20)]
    raw = [e.entry for e in (older, newer, stale, future, oldest_over_cap, bad_key, off_curve, bad_auth,
                             plain_http, bad_sid, keepers[1])] + ["junk", {"sid": 3}]
    world.subscribe("u1", raw=raw)

    dispatch(fn, admin={"max_subscriptions_per_user": 2}, **valves_updated())

    assert world.posts == []
    assert [e["sid"] for e in world.stored("u1")] == [newer.sid, future.sid, keepers[1].sid]
    status = world.status("u1")
    assert {sid for sid, s in status.items() if s["err"] == "invalid"} == {
        bad_key.sid, off_curve.sid, bad_auth.sid, plain_http.sid,
    }
    assert len(world.writes) == 1
    # The next pass drops status for entries that are gone; after that nothing changes.
    dispatch(fn, admin={"max_subscriptions_per_user": 2}, **valves_updated())
    assert world.status("u1") == {} and len(world.writes) == 2
    dispatch(fn, admin={"max_subscriptions_per_user": 2}, **valves_updated())
    assert len(world.writes) == 2


def test_devices_unseen_for_30_days_expire(world, fn):
    now = int(time.time())
    recent, forgotten = Device(origin="any", seen=now - 29 * DAY), Device(origin="any", seen=now - 31 * DAY)
    world.subscribe("u1", recent, forgotten)
    dispatch(fn, **finished())
    assert [post.url for post in world.posts] == [recent.endpoint]
    assert [entry["sid"] for entry in world.stored("u1")] == [recent.sid]


def test_test_push_is_sent_once_per_nonce(world, fn, plugin):
    now = int(time.time())
    phone = Device(test={"nonce": "nonce-0001", "at": now})
    world.subscribe("u1", phone)
    dispatch(fn, **valves_updated())

    (post,) = world.posts
    assert post.headers["TTL"] == "300"
    payload = assert_push(phone, post, "test", "test:nonce-0001", 300)
    assert payload["n"] == "nonce-0001" and "g" not in payload and payload["ids"] == {}
    assert world.status("u1")[phone.sid] == {
        "code": 201, "at": pytest.approx(now, abs=60), "err": None, "nonce": "nonce-0001",
    }

    dispatch(fn, **valves_updated())
    dispatch(plugin.Event(), **valves_updated())  # Another worker sees the stored status.
    world.valves["u1"]["status"] = "{}"  # Conduit rewrote the valves without status.
    dispatch(fn, **valves_updated())
    assert len(world.posts) == 1

    phone.entry["test"] = {"nonce": "nonce-0002", "at": now}
    world.subscribe("u1", phone, status=world.status("u1"))
    dispatch(fn, **valves_updated())
    assert len(world.posts) == 2 and phone.open(world.posts[1])["n"] == "nonce-0002"

    phone.entry["test"] = {"nonce": "nonce-0003", "at": now - 2 * 3600}
    world.subscribe("u1", phone, status=world.status("u1"))
    dispatch(fn, **valves_updated())
    assert len(world.posts) == 2


def test_test_push_ignores_events_and_origin(world, fn):
    quiet = Device(events=[], test={"nonce": "nonce-quiet", "at": int(time.time())})
    world.subscribe("u1", quiet)
    dispatch(fn, **valves_updated())
    assert quiet.open(world.posts[0])["k"] == "test"


@pytest.mark.parametrize("kw", [{"fid": "someone_else"}, {"scope": None}, {"scope": "admin"}])
def test_other_valves_updates_are_ignored(world, fn, kw):
    world.subscribe("u1", Device(test={"nonce": "nonce-0001", "at": int(time.time())}))
    dispatch(fn, **valves_updated(**kw))
    assert world.posts == [] and world.calls == []


# SSRF


def test_private_endpoints_are_blocked_and_reported(world, fn):
    inside, outside = Device(host="10.0.0.5", origin="any"), Device(origin="any")
    world.blocked_hosts.add("10.0.0.5")
    world.subscribe("u1", inside, outside)
    dispatch(fn, **finished())
    dispatch(fn, **finished(msg="m2"))
    assert [post.url for post in world.posts] == [outside.endpoint] * 2
    assert world.status("u1")[inside.sid]["err"] == "blocked"
    assert world.validated.count(inside.endpoint) == 1  # Cached between events.

    world.validated.clear()
    dispatch(fn, **valves_updated())
    assert world.status("u1")[inside.sid]["err"] == "blocked"


def test_admin_can_allow_private_endpoints(world, fn):
    lan, relay = Device(host="ntfy.lan", origin="any"), Device(origin="any")
    world.blocked_hosts.add("ntfy.lan")
    world.subscribe("u1", lan, relay)

    dispatch(fn, admin={"extra_allowed_hosts": "ntfy.lan, other.lan"}, **finished())
    by_url = {post.url: post for post in world.posts}
    assert by_url[lan.endpoint].safe is False and by_url[relay.endpoint].safe is True
    assert lan.endpoint not in world.validated

    world.posts.clear()
    world.validated.clear()
    dispatch(fn, admin={"allow_private_endpoints": True}, **finished(msg="m2"))
    assert len(world.posts) == 2 and not any(post.safe for post in world.posts)
    assert world.validated == []


def test_private_endpoints_stay_blocked_when_open_webui_allows_local_fetch(world, fn, plugin):
    # With ENABLE_LOCAL_WEB_FETCH on, Open WebUI's validate_url passes private hosts.
    world.dns.update({
        "intranet.example": ["10.1.2.3"], "mixed.example": ["93.184.216.34", "192.168.0.7"],
        "mapped.example": ["::ffff:10.0.0.1"], "nat64.example": ["64:ff9b::a00:1"], "nowhere.example": [],
    })
    inside = [Device(host=host, origin="any") for host in (
        "10.0.0.5", "127.1", "[::1]", "intranet.example", "mixed.example", "mapped.example", "nat64.example",
        "nowhere.example")]
    relay, rebound = Device(origin="any"), Device(origin="any")
    world.subscribe("u1", relay, rebound, *inside)
    # The address check at connect time refuses a host that now resolves inside.
    world.responses[rebound.endpoint] = plugin._BlockedAddress("not a public address")
    dispatch(fn, **finished())
    assert sorted(post.url for post in world.posts) == sorted([relay.endpoint, rebound.endpoint])
    assert all(post.safe for post in world.posts)
    status = world.status("u1")
    assert status[relay.sid]["err"] is None
    assert {device.sid for device in inside + [rebound]} == {sid for sid, s in status.items() if s["err"] == "blocked"}

    world.posts.clear()
    dispatch(fn, admin={"extra_allowed_hosts": "intranet.example"}, **finished(msg="m2"))
    by_url = {post.url: post for post in world.posts}
    assert by_url[inside[3].endpoint].safe is False and by_url[relay.endpoint].safe is True


@pytest.mark.parametrize("address,public", [
    ("93.184.216.34", True), ("2606:2800:220:1::", True), ("64:ff9b::5db8:d822", True),
    ("10.0.0.1", False), ("127.0.0.1", False), ("169.254.169.254", False), ("100.64.0.1", False),
    ("0.0.0.0", False), ("::1", False), ("fe80::1%en0", False), ("fc00::1", False),
    ("::ffff:10.0.0.1", False), ("::a00:1", False), ("2002:a00:1::", False), ("64:ff9b::a00:1", False),
    ("64:ff9b:1:a00:0:100::", False), ("2001:0:4136:e378:8000:63bf:f5ff:fffe", False), ("nonsense", False),
])
def test_public_address_rule(plugin, address, public):
    assert plugin._is_public_address(address) is public


@pytest.mark.parametrize("host,address", [
    ("10.0.0.5", "10.0.0.5"), ("127.1", "127.0.0.1"), ("2130706433", "127.0.0.1"), ("0x7f.1", "127.0.0.1"),
    ("[::1]", "::1"), ("relay.example", None), ("", None),
])
def test_literal_addresses(plugin, host, address):
    found = plugin._literal_address(host)
    assert (str(found) if found is not None else None) == address


# The public-only connector, against the real aiohttp (skipped where it isn't installed).


@pytest.fixture
def real_plugin(monkeypatch):
    pytest.importorskip("aiohttp")
    _install(monkeypatch, World(), real_aiohttp=True)
    for name in list(os.environ):
        if name.lower().endswith("_proxy"):
            monkeypatch.delenv(name)
    monkeypatch.setenv("no_proxy", "*")  # and never the system's proxy settings
    return load_function(monkeypatch)


async def _post_through_safe_session(plugin, url):
    sessions = plugin._Sessions()
    try:
        return await plugin._post(sessions.get(False), url, b"x", {}, 5)
    finally:
        await sessions.close()


@pytest.mark.parametrize("host", ["127.0.0.1", "localhost", "127.1", "[::1]", "[::ffff:127.0.0.1]"])
def test_connector_refuses_addresses_that_are_not_public(real_plugin, host):
    async def run():
        connections = []
        server = await asyncio.start_server(lambda reader, writer: connections.append(writer.close()), "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        try:
            with pytest.raises(ValueError):
                await _post_through_safe_session(real_plugin, "https://%s:%d/v1/push/x" % (host, port))
        finally:
            server.close()
        return connections

    assert asyncio.run(run()) == []


@pytest.mark.parametrize("proxy_host", ["127.0.0.1", "localhost"])
def test_connector_lets_the_admins_proxy_through(real_plugin, monkeypatch, proxy_host):
    async def run():
        lines = []

        async def proxy(reader, writer):
            lines.append(await reader.readline())
            writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()

        server = await asyncio.start_server(proxy, "127.0.0.1", 0)
        monkeypatch.delenv("no_proxy")
        monkeypatch.setenv("https_proxy", "http://%s:%d" % (proxy_host, server.sockets[0].getsockname()[1]))
        try:
            with pytest.raises(Exception) as caught:
                await _post_through_safe_session(real_plugin, "https://relay.example/v1/push/x")
        finally:
            server.close()
        return lines, caught.value

    lines, error = asyncio.run(run())
    assert lines == [b"CONNECT relay.example:443 HTTP/1.1\r\n"]
    assert not isinstance(error, ValueError)


def test_resolver_checks_every_answer_it_connects_to(real_plugin, monkeypatch):
    import aiohttp

    answers = {
        "public.example": ["93.184.216.34", "2606:2800:220:1::"],
        "rebound.example": ["93.184.216.34", "10.0.0.1"],
        "nat64.example": ["64:ff9b::a00:1"],
        "proxy.example": ["10.0.0.9"],
        "empty.example": [],
    }

    class Answers:
        async def resolve(self, host, port=0, family=socket.AF_INET):
            return [{"hostname": host, "host": a, "port": port, "family": 0, "proto": 0, "flags": 0}
                    for a in answers[host.rstrip(".").lower()]]

        async def close(self):
            pass

    monkeypatch.setattr(aiohttp, "ThreadedResolver", Answers)
    resolver = real_plugin._public_classes()[1]()

    async def run():
        found = await resolver.resolve("public.example", 443)
        assert [entry["host"] for entry in found] == answers["public.example"]
        for host in ("rebound.example", "nat64.example", "proxy.example", "empty.example"):
            with pytest.raises(ValueError):
                await resolver.resolve(host, 443)
        token = real_plugin._PROXY_HOST.set("proxy.example")
        try:  # The admin's own proxy may well be on a private address.
            assert await resolver.resolve("Proxy.Example.", 3128)
            with pytest.raises(ValueError):
                await resolver.resolve("rebound.example", 443)
        finally:
            real_plugin._PROXY_HOST.reset(token)

    asyncio.run(run())


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://relay.example/v1/push/x",
        "https://user@relay.example/v1/push/x",
        "https://relay.example\\@10.0.0.1/v1/push/x",
        "https://relay.example:99999/v1/push/x",
        "https://relay.example/v1/push/é",
        "ftp://relay.example/x",
    ],
)
def test_malformed_endpoints_never_reach_the_network(world, fn, endpoint):
    phone = Device(origin="any")
    phone.entry["endpoint"] = endpoint
    world.subscribe("u1", phone)
    dispatch(fn, **finished())
    assert world.posts == [] and world.validated == []


# Robustness


def test_failures_never_escape_and_logs_stay_clean(world, fn, caplog):
    caplog.set_level(logging.DEBUG)
    slow, broken, fine = Device(origin="any"), Device(origin="any"), Device(origin="any")
    world.subscribe("u1", slow, broken, fine)
    world.responses[slow.endpoint] = asyncio.TimeoutError()
    world.responses[broken.endpoint] = OSError("connection refused")
    dispatch(fn, **finished())
    status = world.status("u1")
    assert status[slow.sid]["err"] == "timeout" and status[slow.sid]["code"] is None
    assert status[broken.sid]["err"] == "network"
    assert status[fine.sid]["code"] == 201

    for name, data in [
        ("chat.finished", {"user_id": 5, "chat_id": None}),
        ("chat.finished", "not a dict"),
        ("message.created", {"channel_id": "nope"}),
        ("function.valves_updated", {"scope": "user"}),
        ("something.else", {}),
    ]:
        dispatch(fn, name=name, data=data if isinstance(data, dict) else None, subject={"id": FID})

    async def odd_calls():
        await fn.event(None)
        await fn.event("chat.finished", "chat.finished")
        await fn.event({"event": "chat.finished", "data": [1, 2]})
        await fn._wait_idle()

    asyncio.run(odd_calls())

    world.fail.update({"get_user_valves", "get_message"})
    dispatch(fn, **finished())
    dispatch(fn, **valves_updated())
    channel_world(world)
    dispatch(fn, **posted(world))

    logs = caplog.text
    for device in (slow, broken, fine):
        for secret in (device.endpoint, device.entry["p256dh"], device.entry["auth"], device.sid):
            assert secret not in logs
    assert "three" not in logs and "secret details" not in logs and "database is down" not in logs


def test_event_returns_before_sending(world, fn):
    phone = Device(origin="any")
    world.subscribe("u1", phone)

    async def run():
        world.gate = asyncio.Event()
        args = finished()
        await fn.event(
            {"event": "chat.finished", "data": args["data"], "actor": args["actor"], "subject": args["subject"]},
            "chat.finished", None, FID,
        )
        assert fn._tasks and world.writes == []
        world.gate.set()
        await fn._wait_idle()

    asyncio.run(run())
    assert len(world.posts) == 1 and world.status("u1")[phone.sid]["code"] == 201
