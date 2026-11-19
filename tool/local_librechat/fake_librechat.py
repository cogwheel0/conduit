#!/usr/bin/env python3
"""A fake LibreChat v0.8.8 server for Conduit's daemon tests and desktop E2E.

Standard library only (Python 3.9+). It serves enough of LibreChat's API, as
`conduit_core`'s LibreChat client calls it, with invented data:

* the public and signed-in startup config (`/api/config`), roles, endpoints,
  endpoint models, agents and model specs;
* sign-in: password, two-step verification (an authenticator code or a
  backup code), refresh, sign-out, and single sign-on through a stand-in
  OpenID provider (`/oauth/openid` ... `/oauth/openid/callback`);
* conversations: list, get, rename, pin, archive, delete, duplicate, fork,
  and their messages;
* generations over protocol v2: start, the SSE stream (with resume), stop,
  status, and paused runs (a tool approval, an agent question) answered
  through `/api/agents/chat/resume`;
* files, prompts, memories, share links, MCP servers, and speech (STT/TTS).

What a reply does depends on the user's words (see `Turn.script`):

* "approve" in the message pauses on a tool approval;
* "ask me" pauses on a question;
* "long" streams slowly for about 15 seconds (to stop it);
* "fail" ends the stream with an error;
* anything else gets a short answer that names the model and quotes it.

Test hooks live under `/__fake/` (state, reset, expire sessions). Every user,
password, chat and memory here is made up.

Run: python3 fake_librechat.py --port 19213 [--host 127.0.0.1] [--log FILE]
"""

import argparse
import base64
import copy
import json
import os
import re
import secrets
import struct
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlparse

ROOT_PARENT = "00000000-0000-0000-0000-000000000000"

# ---------------------------------------------------------------------------
# Seed data (all invented)
# ---------------------------------------------------------------------------

USERS = [
    {
        "id": "u_rowan",
        "email": "rowan@example.test",
        "password": "lantern-harbour-42",
        "name": "Rowan Vale",
        "username": "rowan",
        "role": "USER",
        "totp": "246810",
        "backup": ["fern-quartz-01", "fern-quartz-02"],
        "provider": "local",
    },
    {
        "id": "u_kit",
        "email": "kit@example.test",
        "password": "kite-meadow-77",
        "name": "Kit Marlow",
        "username": "kit",
        "role": "USER",
        "totp": None,
        "backup": [],
        "provider": "local",
    },
    {
        "id": "u_sage",
        "email": "sage@example.test",
        "password": None,
        "name": "Sage Ito",
        "username": "sage",
        "role": "USER",
        "totp": None,
        "backup": [],
        "provider": "openid",
    },
]

ENDPOINT = "Harbour"
MODELS = {ENDPOINT: ["harbour-small", "harbour-large"], "agents": []}

AGENTS = [
    {
        "id": "agent_tidewatch",
        "name": "Tidewatch",
        "description": "Answers questions about tides and harbour times.",
        "model": "harbour-large",
        "provider": ENDPOINT,
        "tools": ["lookup_tide_mcp_harbour_docs"],
    },
    {
        "id": "agent_ledger",
        "name": "Ledger Helper",
        "description": "Keeps small household budgets tidy.",
        "model": "harbour-small",
        "provider": ENDPOINT,
        "tools": [],
    },
]

MODEL_SPECS = [
    {
        "name": "quick-notes",
        "label": "Quick Notes",
        "description": "Short, plain answers.",
        "preset": {"endpoint": ENDPOINT, "model": "harbour-small"},
    },
    {
        "name": "deep-research",
        "label": "Deep Research",
        "description": "Tidewatch with web search.",
        "preset": {"endpoint": "agents", "agent_id": "agent_tidewatch"},
    },
]

PROMPTS = [
    {
        "_id": "pg_pack",
        "name": "Packing list",
        "command": "pack",
        "category": "travel",
        "oneliner": "A list for a trip",
        "prompt": "Make a packing list for {{destination}} for {{days}} days.",
    },
    {
        "_id": "pg_tone",
        "name": "Tone rewrite",
        "command": "tone",
        "category": "writing",
        "oneliner": "Rewrite in another tone",
        "prompt": "Rewrite this in a {{tone:friendly|formal|playful}} tone: {{text}}",
    },
    {
        "_id": "pg_summary",
        "name": "Daily summary",
        "command": "summary",
        "category": "",
        "oneliner": "Three bullet points",
        "prompt": "Summarise today in three bullet points.",
    },
]

MEMORIES = {
    "u_rowan": [
        ("favourite_tea", "Smoky lapsang, no sugar"),
        ("home_harbour", "Port Wren on the north coast"),
    ],
    "u_kit": [("kite_colour", "Orange with a long tail")],
    "u_sage": [],
}

MCP_SERVERS = {
    "harbour_docs": {
        "name": "harbour_docs",
        "title": "Harbour Docs",
        "authenticated": True,
        "requiresOAuth": False,
        "tools": [
            {
                "name": "lookup_tide",
                "pluginKey": "lookup_tide_mcp_harbour_docs",
                "description": "Looks up the next high tide.",
            }
        ],
    },
    "ledger_sync": {
        "name": "ledger_sync",
        "title": "Ledger Sync",
        "authenticated": False,
        "requiresOAuth": True,
        "tools": [
            {
                "name": "sync_ledger",
                "pluginKey": "sync_ledger_mcp_ledger_sync",
                "description": "Copies receipts into the ledger.",
            }
        ],
    },
}

VOICES = ["Marlin", "Heron", "Puffin"]

# (owner, id, title, minutes ago, pinned, archived, [(user, assistant), ...])
CONVERSATIONS = [
    (
        "u_rowan",
        "c_harbour",
        "Harbour lights schedule",
        30,
        True,
        False,
        [
            (
                "When do the harbour lights come on in winter?",
                "In winter the harbour lights come on at **16:30** and stay on until 07:45.",
            )
        ],
    ),
    (
        "u_rowan",
        "c_tides",
        "Tide table questions",
        90,
        False,
        False,
        [
            ("What is a spring tide?", "A spring tide has the largest range, near a new or full moon."),
            ("And a neap tide?", "A neap tide has the smallest range, near the quarter moons."),
        ],
    ),
    (
        "u_rowan",
        "c_shed",
        "Garden shed paint colours",
        240,
        False,
        False,
        [("Suggest three calm colours for a shed.", "Sage green, slate blue and warm sand.")],
    ),
    (
        "u_rowan",
        "c_lantern",
        "Lantern repair notes",
        2000,
        False,
        True,
        [("How do I clean a brass lantern?", "Warm soapy water, a soft cloth, then dry it at once.")],
    ),
    (
        "u_kit",
        "c_kites",
        "Kite festival plan",
        45,
        False,
        False,
        [("List what to bring to a kite festival.", "Spare line, a reel, sunscreen and a flask.")],
    ),
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def now():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)


def ms():
    return int(time.time() * 1000)


def new_id():
    return str(uuid.uuid4())


def b64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def token_count(text):
    return max(1, len(text.split()))


def title_from(text):
    words = re.findall(r"[A-Za-z0-9']+", text)[:4]
    title = " ".join(words).strip()
    return title[:1].upper() + title[1:] if title else "New Chat"


def tone_wav(seconds=0.4, rate=16000, freq=440.0):
    import math

    frames = int(seconds * rate)
    data = b"".join(
        struct.pack("<h", int(6000 * math.sin(2 * math.pi * freq * i / rate))) for i in range(frames)
    )
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    fmt = b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    return header + fmt + b"data" + struct.pack("<I", len(data)) + data


def parse_multipart(body, content_type):
    """Returns ({field: str}, [(field, filename, content_type, bytes)])."""
    match = re.search(r"boundary=(\"?)([^\";]+)\1", content_type or "")
    fields, files = {}, []
    if not match:
        return fields, files
    boundary = ("--" + match.group(2)).encode()
    for part in body.split(boundary):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        head, _, content = part.partition(b"\r\n\r\n")
        headers = head.decode("utf-8", "replace")
        name = re.search(r'name="([^"]*)"', headers)
        filename = re.search(r'filename="([^"]*)"', headers)
        ctype = re.search(r"Content-Type:\s*([^\r\n]+)", headers, re.I)
        if content.endswith(b"\r\n"):
            content = content[:-2]
        if filename:
            files.append(
                (
                    name.group(1) if name else "file",
                    unquote(filename.group(1)),
                    ctype.group(1).strip() if ctype else "application/octet-stream",
                    content,
                )
            )
        elif name:
            fields[name.group(1)] = content.decode("utf-8", "replace")
    return fields, files


# ---------------------------------------------------------------------------
# Server state
# ---------------------------------------------------------------------------


class State:
    def __init__(self, base_url, token_ttl):
        self.lock = threading.RLock()
        self.base_url = base_url
        self.token_ttl = token_ttl
        self.reset()

    def reset(self):
        with self.lock:
            self.users = {u["id"]: dict(u, backup=list(u["backup"])) for u in USERS}
            self.personalization = {u["id"]: {"memories": True} for u in USERS}
            self.access = {}  # token -> (user_id, expires)
            self.refresh = {}  # refresh token -> user_id
            self.temp = {}  # temp token -> user_id
            self.oauth_codes = {}  # code -> user_id
            self.conversations = {}
            self.messages = {}  # conversation id -> [message]
            self.shares = {}  # share id -> {conversationId, snapshotFiles, user}
            self.files = {}
            self.memories = {}
            self.mcp_connected = {name: s["authenticated"] for name, s in MCP_SERVERS.items()}
            self.jobs = {}  # conversation id -> Job
            self.turns = []  # every start body, newest last
            self.counter = 0
            for user_id, entries in MEMORIES.items():
                self.memories[user_id] = [
                    {
                        "_id": "mem_%s_%d" % (user_id, i),
                        "key": key,
                        "value": value,
                        "tokenCount": token_count(value),
                        "updated_at": iso(now() - timedelta(days=i + 1)),
                    }
                    for i, (key, value) in enumerate(entries)
                ]
            for owner, cid, title, minutes, pinned, archived, pairs in CONVERSATIONS:
                updated = now() - timedelta(minutes=minutes)
                self.conversations[cid] = {
                    "conversationId": cid,
                    "user": owner,
                    "title": title,
                    "endpoint": ENDPOINT,
                    "endpointType": "custom",
                    "model": "harbour-small",
                    "pinned": pinned,
                    "isArchived": archived,
                    "createdAt": iso(updated - timedelta(minutes=5)),
                    "updatedAt": iso(updated),
                }
                parent = ROOT_PARENT
                msgs = []
                for i, (question, answer) in enumerate(pairs):
                    at = updated - timedelta(minutes=len(pairs) - i)
                    user_msg = self.message(cid, parent, question, True, at)
                    reply = self.message(cid, user_msg["messageId"], answer, False, at + timedelta(seconds=5))
                    msgs += [user_msg, reply]
                    parent = reply["messageId"]
                self.messages[cid] = msgs

    def message(self, cid, parent, text, by_user, at=None, model="harbour-small", content=None, **extra):
        at = at or now()
        msg = {
            "messageId": new_id(),
            "parentMessageId": parent,
            "conversationId": cid,
            "text": text,
            "isCreatedByUser": by_user,
            "sender": "User" if by_user else "Harbour",
            "endpoint": ENDPOINT,
            "model": model,
            "error": False,
            "unfinished": False,
            "createdAt": iso(at),
            "updatedAt": iso(at),
        }
        if content is not None:
            msg["content"] = content
        msg.update(extra)
        return msg

    # -- sessions -----------------------------------------------------------

    def jwt(self, user_id):
        with self.lock:
            self.counter += 1
            exp = int(time.time() + self.token_ttl)
            payload = {"id": user_id, "n": self.counter, "exp": exp}
            token = "%s.%s.sig%d" % (
                b64url(json.dumps({"alg": "HS256"}).encode()),
                b64url(json.dumps(payload).encode()),
                self.counter,
            )
            self.access[token] = (user_id, exp)
            return token

    def issue_refresh(self, user_id):
        with self.lock:
            token = "rt-%s-%s" % (user_id, secrets.token_hex(8))
            self.refresh[token] = user_id
            return token

    def user_for(self, token):
        with self.lock:
            entry = self.access.get(token or "")
            if not entry or entry[1] <= time.time():
                return None
            return self.users.get(entry[0])

    def public_user(self, user):
        return {
            "_id": user["id"],
            "id": user["id"],
            "email": user["email"],
            "name": user["name"],
            "username": user["username"],
            "role": user["role"],
            "provider": user["provider"],
            "twoFactorEnabled": bool(user["totp"]),
            "personalization": dict(self.personalization.get(user["id"], {})),
            "avatar": None,
        }

    # -- conversations ------------------------------------------------------

    def owned(self, user, cid):
        conversation = self.conversations.get(cid)
        if conversation is None or conversation.get("user") != user["id"]:
            return None
        return conversation


# ---------------------------------------------------------------------------
# Generations
# ---------------------------------------------------------------------------


class Job:
    """One generation: produces events in a thread, kept for resumes."""

    def __init__(self, state, user, body, conversation, user_message, parent_for_reply, is_new):
        self.state = state
        self.user = user
        self.body = body
        self.conversation = conversation
        self.cid = conversation["conversationId"]
        self.user_message = user_message
        self.parent_for_reply = parent_for_reply
        self.is_new = is_new
        self.created_at = ms()
        self.client_request_id = body.get("clientRequestId")
        self.response_id = new_id()
        self.events = []
        self.cond = threading.Condition()
        self.done = False
        self.aborted = False
        self.pending = None
        self.answer = None
        self.parts = []
        self.steps = []
        self.title = None
        self.thread = threading.Thread(target=self.run, daemon=True)

    # -- event plumbing -----------------------------------------------------

    def emit(self, payload, event="message"):
        with self.cond:
            self.events.append((event, payload))
            self.cond.notify_all()

    def step(self, step_id, index, kind, tool_call=None):
        details = (
            {"type": "message_creation", "message_creation": {"message_id": self.response_id}}
            if kind == "message"
            else {"type": "tool_calls", "tool_calls": [tool_call]}
        )
        data = {"id": step_id, "runId": self.response_id, "index": index, "stepDetails": details}
        self.steps.append(data)
        self.emit({"event": "on_run_step", "data": data})
        while len(self.parts) <= index:
            self.parts.append(None)
        if kind == "message":
            self.parts[index] = {"type": "text", "text": ""}
        else:
            self.parts[index] = {
                "type": "tool_call",
                "tool_call": dict(tool_call, type="tool_call"),
            }

    def text(self, step_id, index, words, delay):
        for word in words:
            with self.cond:
                if self.aborted:
                    return False
            self.parts[index]["text"] += word
            self.emit(
                {
                    "event": "on_message_delta",
                    "data": {"id": step_id, "delta": {"content": [{"type": "text", "text": word}]}},
                }
            )
            time.sleep(delay)
        return True

    def think(self, step_id, index, text):
        while len(self.parts) <= index:
            self.parts.append(None)
        self.parts[index] = {"type": "think", "think": text}
        self.emit(
            {
                "event": "on_reasoning_delta",
                "data": {"id": step_id, "delta": {"content": [{"type": "think", "think": text}]}},
            }
        )

    def tool_done(self, step_id, index, call, output):
        call = dict(call, output=output, progress=1, type="tool_call")
        self.parts[index] = {"type": "tool_call", "tool_call": call}
        self.emit(
            {
                "event": "on_run_step_completed",
                "data": {"result": {"id": step_id, "index": index, "tool_call": call}},
            }
        )

    def pause(self, payload):
        action = {
            "actionId": "act_" + secrets.token_hex(4),
            "streamId": self.cid,
            "conversationId": self.cid,
            "runId": self.response_id,
            "responseMessageId": self.response_id,
            "createdAt": ms(),
            "payload": payload,
        }
        with self.cond:
            self.pending = action
            self.answer = None
            self.events.append(("message", {"event": "on_pending_action", "data": action}))
            self.cond.notify_all()
            while self.answer is None and not self.aborted:
                self.cond.wait(timeout=1)
            self.pending = None
            return self.answer

    # -- the script ---------------------------------------------------------

    def label(self):
        spec = self.body.get("spec")
        for s in MODEL_SPECS:
            if s["name"] == spec:
                return s["label"]
        agent_id = self.body.get("agent_id")
        for a in AGENTS:
            if a["id"] == agent_id:
                return a["name"]
        return self.body.get("model") or "harbour-small"

    def run(self):
        try:
            self.script()
        except Exception as error:  # pragma: no cover - logged for the test run
            log("job failed: %r" % (error,))
            self.emit({"error": "The fake server failed: %s" % error}, event="error")
            self.finish_failed()

    def script(self):
        text = (self.user_message.get("text") or "").strip()
        lower = text.lower()
        tools = self.body.get("ephemeralAgent") or {}
        time.sleep(0.15)
        self.emit({"created": True, "message": self.user_message, "streamId": self.cid})
        if "fail" in lower.split():
            time.sleep(0.2)
            self.emit({"error": "The harbour model is resting. Try again later."}, event="error")
            self.finish_failed()
            return
        index = 0
        if tools.get("web_search"):
            call = {"id": "call_search", "name": "web_search", "args": json.dumps({"query": text})}
            self.step("step_search", index, "tool", call)
            time.sleep(0.1)
            self.tool_done("step_search", index, call, "Found 1 result.")
            self.emit(
                {
                    "event": "attachment",
                    "data": {
                        "type": "web_search",
                        "messageId": self.response_id,
                        "toolCallId": "call_search",
                        "conversationId": self.cid,
                        "web_search": {
                            "turn": 0,
                            "organic": [
                                {
                                    "title": "Harbour almanac",
                                    "link": "https://almanac.example.test/harbour",
                                    "snippet": "Tide and light times for small harbours.",
                                }
                            ],
                        },
                    },
                }
            )
            index += 1
        if "approve" in lower:
            call = {
                "id": "call_tide",
                "name": "lookup_tide_mcp_harbour_docs",
                "args": json.dumps({"harbour": "Port Wren"}),
            }
            self.step("step_tool", index, "tool", call)
            answer = self.pause(
                {
                    "type": "tool_approval",
                    "action_requests": [
                        {
                            "name": "lookup_tide_mcp_harbour_docs",
                            "arguments": {"harbour": "Port Wren"},
                            "tool_call_id": "call_tide",
                            "description": "Look up the next high tide at Port Wren.",
                        }
                    ],
                    "review_configs": [
                        {
                            "action_name": "lookup_tide_mcp_harbour_docs",
                            "tool_call_id": "call_tide",
                            "allowed_decisions": ["approve", "reject"],
                        }
                    ],
                }
            )
            if self.aborted:
                return self.finish(aborted=True)
            decision = "reject"
            for d in (answer or {}).get("decisions") or []:
                if d.get("tool_call_id") == "call_tide":
                    decision = d.get("decision") or "reject"
            approved = decision in ("approve", "edit")
            self.tool_done(
                "step_tool", index, call, "High tide at 06:40." if approved else "The user declined this tool call."
            )
            index += 1
            reply = (
                "The next high tide at Port Wren is at 06:40."
                if approved
                else "Understood, I did not look up the tide."
            )
        elif "ask me" in lower:
            call = {
                "id": "call_ask",
                "name": "ask_user_question",
                "args": json.dumps({"question": "Which harbour do you mean?"}),
            }
            self.step("step_ask", index, "tool", call)
            answer = self.pause(
                {
                    "type": "ask_user_question",
                    "tool_call_id": "call_ask",
                    "question": {
                        "question": "Which harbour do you mean?",
                        "description": "Pick one, or write another.",
                        "options": [
                            {"label": "Port Wren", "description": "North coast"},
                            {"label": "Gull Haven", "description": "South coast"},
                        ],
                    },
                }
            )
            if self.aborted:
                return self.finish(aborted=True)
            chosen = (answer or {}).get("answer")
            if chosen is None:
                answers = (answer or {}).get("answers") or {}
                chosen = next(iter(answers.values()), "")
            self.tool_done("step_ask", index, call, chosen or "")
            index += 1
            reply = "You chose %s. Its harbour lights come on at 16:30." % (chosen or "nothing")
        elif "long" in lower.split() or "story" in lower:
            reply = " ".join(["The tide rolled in over the shingle and the lantern swung."] * 40)
            self.think("step_think", index, "Planning a long story.")
            index += 1
            self.step("step_text", index, "message")
            if not self.text("step_text", index, [w + " " for w in reply.split()], 0.04):
                return self.finish(aborted=True)
            return self.finish()
        else:
            reply = 'Noted: "%s". %s answers from the fake harbour server.' % (text[:120], self.label())
            if tools.get("web_search"):
                reply += " The almanac agrees."
        self.step("step_text", index, "message")
        if not self.text("step_text", index, [w + " " for w in reply.split()], 0.03):
            return self.finish(aborted=True)
        self.finish()

    def response_text(self):
        return "".join(p.get("text", "") for p in self.parts if p and p.get("type") == "text").strip()

    def finish(self, aborted=False):
        state = self.state
        content = [p for p in self.parts if p is not None]
        with state.lock:
            response = state.message(
                self.cid,
                self.parent_for_reply,
                self.response_text(),
                False,
                model=self.body.get("model") or "harbour-small",
                content=content,
                messageId=self.response_id,
                unfinished=aborted,
            )
            response["sender"] = self.label()
            if self.body.get("endpoint"):
                response["endpoint"] = self.body.get("endpoint")
            msgs = state.messages.setdefault(self.cid, [])
            msgs.append(response)
            self.conversation["updatedAt"] = iso(now())
            title = None
            if self.is_new and self.conversation.get("title") in (None, "", "New Chat"):
                title = title_from(self.user_message.get("text") or "")
                self.conversation["title"] = title
                self.title = title
        if title:
            self.emit({"event": "title", "data": {"conversationId": self.cid, "title": title}})
        frame = {
            "final": True,
            "conversation": public_conversation(self.conversation),
            "title": self.conversation.get("title"),
            "requestMessage": self.user_message,
            "responseMessage": response,
            "generationProtocolVersion": 2,
        }
        if aborted:
            frame["aborted"] = True
            frame["earlyAbort"] = False
        self.emit(frame)
        with self.cond:
            self.done = True
            self.cond.notify_all()

    def finish_failed(self):
        with self.cond:
            self.done = True
            self.cond.notify_all()

    def snapshot(self):
        return {
            "runSteps": list(self.steps),
            "aggregatedContent": [p for p in self.parts if p is not None],
            "userMessage": self.user_message,
            "responseMessageId": self.response_id,
            "pendingAction": self.pending,
        }


def public_conversation(conversation):
    return {k: v for k, v in conversation.items() if k != "user"}


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

STATE = None
LOG = None
BROWSER_GUARDED = re.compile(r"^/api/(agents|files|assistants|permissions)(/|$)")


def log(line):
    stamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    text = "%s %s\n" % (stamp, line)
    if LOG:
        with open(LOG, "a") as f:
            f.write(text)
    else:
        sys.stderr.write(text)


def looks_like_browser(ua):
    return bool(ua) and ua.startswith("Mozilla/5.0 (") and (" Safari/" in ua or " Chrome/" in ua)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeLibreChat/0.8.8"

    def log_message(self, fmt, *args):
        log("%s %s" % (self.command, self.path))

    # -- plumbing -----------------------------------------------------------

    def _body(self):
        return self._raw

    def _json_body(self):
        raw = self._body()
        if not raw:
            return {}
        try:
            return json.loads(raw.decode())
        except ValueError:
            return {}

    def send(self, status, body=b"", content_type="application/json", headers=None, cookies=()):
        if isinstance(body, (dict, list, bool)) or body is None:
            body = json.dumps(body).encode()
            content_type = "application/json"
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for cookie in cookies:
            self.send_header("Set-Cookie", cookie)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def text(self, status, text, content_type="text/html; charset=utf-8", **kw):
        self.send(status, text.encode(), content_type, **kw)

    def redirect(self, location, cookies=()):
        self.send(302, b"", "text/plain", headers={"Location": location}, cookies=cookies)

    def cookies(self):
        jar = {}
        for part in (self.headers.get("Cookie") or "").split(";"):
            if "=" in part:
                name, value = part.split("=", 1)
                jar[name.strip()] = value.strip()
        return jar

    def bearer(self):
        value = self.headers.get("Authorization") or ""
        return value[7:] if value.startswith("Bearer ") else None

    def user(self):
        return STATE.user_for(self.bearer())

    def unauthorized(self):
        self.text(401, "Unauthorized", "text/plain")

    def cross_site(self):
        origin = self.headers.get("Origin")
        if origin is None and self.headers.get("Sec-Fetch-Site") is None:
            return False
        server = urlparse(STATE.base_url)
        if origin == "%s://%s" % (server.scheme, server.netloc):
            return False
        self.send(403, {"message": "Cross-site request rejected"})
        return True

    def session_cookies(self, user_id, provider="librechat"):
        refresh = STATE.issue_refresh(user_id)
        expires = formatdate(time.time() + 7 * 86400, usegmt=True)
        return [
            "refreshToken=%s; Path=/; Expires=%s; HttpOnly; SameSite=Strict" % (refresh, expires),
            "token_provider=%s; Path=/; Expires=%s; HttpOnly; SameSite=Strict" % (provider, expires),
        ]

    def signed_in(self, user):
        token = STATE.jwt(user["id"])
        self.send(
            200,
            {"token": token, "user": STATE.public_user(user)},
            cookies=self.session_cookies(user["id"], "openid" if user["provider"] == "openid" else "librechat"),
        )

    # -- dispatch -----------------------------------------------------------

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_DELETE(self):
        self.route("DELETE")

    def do_PUT(self):
        self.route("PUT")

    def route(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        self._raw = self.rfile.read(length) if length else b""
        url = urlparse(self.path)
        self.query = {k: v[-1] for k, v in parse_qs(url.query).items()}
        path = url.path
        if BROWSER_GUARDED.match(path) and not path.startswith("/api/agents/v1/"):
            if not looks_like_browser(self.headers.get("User-Agent")):
                log("refused a non-browser User-Agent: %r" % self.headers.get("User-Agent"))
                return self.text(200, 'event: error\ndata: {"message": "Illegal request"}\n\n', "text/plain")
        for verb, pattern, handler in ROUTES:
            if verb != method:
                continue
            match = re.fullmatch(pattern, path)
            if match:
                try:
                    return handler(self, *match.groups())
                except BrokenPipeError:
                    return None
                except Exception as error:
                    log("handler failed: %r" % (error,))
                    return self.send(500, {"message": "Fake server error: %s" % error})
        self.text(404, "Not Found", "text/plain")


ROUTES = []


def route(method, pattern):
    def wrap(fn):
        ROUTES.append((method, pattern, fn))
        return fn

    return wrap


def authed(fn):
    def wrapper(h, *args):
        user = h.user()
        if user is None:
            return h.unauthorized()
        return fn(h, user, *args)

    return wrapper


# -- config, roles, endpoints ------------------------------------------------


def startup_config(signed_in):
    config = {
        "appTitle": "Harbour LibreChat",
        "serverDomain": STATE.base_url,
        "emailLoginEnabled": True,
        "registrationEnabled": False,
        "passwordResetEnabled": False,
        "socialLoginEnabled": True,
        "socialLogins": ["openid"],
        "openidLoginEnabled": True,
        "openidLabel": "Harbour ID",
        "githubLoginEnabled": False,
        "googleLoginEnabled": False,
        "ldap": {"enabled": False},
        "minPasswordLength": 8,
    }
    if signed_in:
        config.update(
            {
                "sharedLinksEnabled": True,
                "publicSharedLinksEnabled": True,
                "interface": {
                    "modelSelect": True,
                    "prompts": {"use": True, "create": True},
                    "memories": True,
                    "webSearch": True,
                    "runCode": True,
                    "fileSearch": True,
                    "mcpServers": {"use": True},
                    "agents": {"use": True},
                    "temporaryChat": True,
                },
                "modelSpecs": {"enforce": False, "prioritize": True, "list": MODEL_SPECS},
            }
        )
    return config


@route("GET", r"/api/config")
def get_config(h):
    h.send(200, startup_config(h.user() is not None))


@route("GET", r"/health")
def health(h):
    h.text(200, "OK", "text/plain")


@route("GET", r"/api/roles/([^/]+)")
@authed
def get_role(h, user, role):
    h.send(
        200,
        {
            "name": unquote(role),
            "permissions": {
                "PROMPTS": {"USE": True, "CREATE": True, "SHARED_GLOBAL": False},
                "MEMORIES": {"USE": True, "CREATE": True, "UPDATE": True, "READ": True, "OPT_OUT": True},
                "AGENTS": {"USE": True, "CREATE": False},
                "MULTI_CONVO": {"USE": True},
                "TEMPORARY_CHAT": {"USE": True},
                "RUN_CODE": {"USE": True},
                "WEB_SEARCH": {"USE": True},
                "FILE_SEARCH": {"USE": True},
                "MCP_SERVERS": {"USE": True},
                "SHARED_LINKS": {"CREATE": True, "SHARE_PUBLIC": True},
            },
        },
    )


@route("GET", r"/api/search/enable")
@authed
def search_enable(h, user):
    h.send(200, False)


@route("GET", r"/api/endpoints")
@authed
def endpoints(h, user):
    body = {
        "agents": {
            "order": 0,
            "type": "agents",
            "capabilities": ["web_search", "execute_code", "file_search", "tools", "actions"],
        },
        ENDPOINT: {"order": 1, "type": "custom", "modelDisplayLabel": "Harbour", "userProvide": False},
    }
    # LibreChat sends this as text.
    h.text(200, json.dumps(body))


@route("GET", r"/api/models")
@authed
def models(h, user):
    h.send(200, MODELS)


@route("GET", r"/api/agents")
@authed
def agents(h, user):
    h.send(200, {"object": "list", "data": AGENTS, "has_more": False, "first_id": AGENTS[0]["id"], "last_id": AGENTS[-1]["id"]})


# -- auth --------------------------------------------------------------------


@route("POST", r"/api/auth/login")
def login(h):
    if h.cross_site():
        return
    body = h._json_body()
    email = (body.get("email") or "").strip().lower()
    user = next((u for u in STATE.users.values() if u["email"] == email and u["password"]), None)
    if user is None:
        return h.send(404, {"message": "Email does not exist."})
    if user["password"] != body.get("password"):
        return h.send(404, {"message": "Incorrect password."})
    if user["totp"]:
        temp = "temp-" + secrets.token_hex(8)
        STATE.temp[temp] = user["id"]
        return h.send(200, {"twoFAPending": True, "tempToken": temp})
    h.signed_in(user)


@route("POST", r"/api/auth/2fa/verify-temp")
def verify_temp(h):
    if h.cross_site():
        return
    body = h._json_body()
    user_id = STATE.temp.get(body.get("tempToken"))
    user = STATE.users.get(user_id) if user_id else None
    if user is None:
        return h.send(401, {"message": "Invalid or expired temporary token"})
    code, backup = body.get("token"), body.get("backupCode")
    ok = (code is not None and code == user["totp"]) or (backup is not None and backup in user["backup"])
    if not ok:
        return h.send(401, {"message": "Invalid 2FA code or backup code"})
    if backup is not None and backup in user["backup"]:
        user["backup"].remove(backup)
    STATE.temp.pop(body.get("tempToken"), None)
    h.signed_in(user)


@route("POST", r"/api/auth/refresh")
def refresh(h):
    token = h.cookies().get("refreshToken")
    if not token:
        return h.text(200, "Refresh token not provided", "text/plain")
    with STATE.lock:
        user_id = STATE.refresh.pop(token, None)
    user = STATE.users.get(user_id) if user_id else None
    if user is None:
        return h.text(401, "Refresh token expired or not found for this user", "text/plain")
    h.signed_in(user)


@route("POST", r"/api/auth/logout")
def logout(h):
    with STATE.lock:
        STATE.refresh.pop(h.cookies().get("refreshToken"), None)
        STATE.access.pop(h.bearer(), None)
    cleared = "Thu, 01 Jan 1970 00:00:00 GMT"
    h.send(
        200,
        {"message": "Logout successful"},
        cookies=["refreshToken=; Path=/; Expires=%s" % cleared, "token_provider=; Path=/; Expires=%s" % cleared],
    )


@route("GET", r"/api/user")
@authed
def current_user(h, user):
    h.send(200, STATE.public_user(user))


# -- single sign-on (a stand-in OpenID provider) -----------------------------

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>%s</title>
<meta name="viewport" content="width=device-width">
<style>body{font:15px -apple-system,system-ui,sans-serif;margin:48px auto;max-width:360px;color:#222}
button{font:inherit;padding:8px 18px;border-radius:8px;border:1px solid #888;background:#fff}</style>
</head><body>%s</body></html>"""


@route("GET", r"/oauth/openid")
def oauth_start(h):
    state = secrets.token_hex(6)
    h.redirect("/fake-idp/authorize?state=%s&client_id=harbour" % state)


@route("GET", r"/fake-idp/authorize")
def idp_page(h):
    state = h.query.get("state", "")
    body = (
        "<h1>Harbour ID</h1><p>Sign in to Harbour LibreChat as <b>Sage Ito</b>?</p>"
        '<form id="approve" method="post" action="/fake-idp/approve">'
        '<input type="hidden" name="state" value="%s">'
        '<button id="continue" type="submit">Continue</button></form>' % state
    )
    h.text(200, PAGE % ("Harbour ID", body))


@route("POST", r"/fake-idp/approve")
def idp_approve(h):
    h._body()
    code = secrets.token_hex(8)
    STATE.oauth_codes[code] = "u_sage"
    h.redirect("/oauth/openid/callback?code=%s&state=ok" % code)


@route("GET", r"/oauth/openid/callback")
def oauth_callback(h):
    user_id = STATE.oauth_codes.pop(h.query.get("code", ""), None)
    if user_id is None:
        return h.redirect("/login?error=auth_failed")
    h.redirect("/c/new", cookies=h.session_cookies(user_id, "openid"))


@route("GET", r"/(c/[^/]+|login|)")
def web_app(h, *_):
    h.text(200, PAGE % ("Harbour LibreChat", "<p>Harbour LibreChat web app (fake).</p>"))


# -- conversations -----------------------------------------------------------


@route("GET", r"/api/convos")
@authed
def list_convos(h, user):
    archived = h.query.get("isArchived") == "true"
    pinned_only = h.query.get("pinned") == "true"
    search = (h.query.get("search") or "").lower()
    limit = int(h.query.get("limit") or 25)
    with STATE.lock:
        items = [
            c
            for c in STATE.conversations.values()
            if c.get("user") == user["id"]
            and bool(c.get("isArchived")) == archived
            and (not pinned_only or c.get("pinned"))
            and (not search or search in (c.get("title") or "").lower())
        ]
        items.sort(key=lambda c: c["updatedAt"], reverse=True)
        cursor = h.query.get("cursor")
        start = int(base64.b64decode(cursor).decode()) if cursor else 0
        page = [public_conversation(c) for c in items[start : start + limit]]
        nxt = base64.b64encode(str(start + limit).encode()).decode() if start + limit < len(items) else None
    h.send(200, {"conversations": page, "nextCursor": nxt})


@route("GET", r"/api/convos/([^/]+)")
@authed
def get_convo(h, user, cid):
    with STATE.lock:
        conversation = STATE.owned(user, unquote(cid))
        body = public_conversation(conversation) if conversation else None
    if body is None:
        return h.send(404, {"message": "Conversation not found"})
    h.send(200, body)


@route("GET", r"/api/messages/([^/]+)")
@authed
def get_messages(h, user, cid):
    with STATE.lock:
        conversation = STATE.owned(user, unquote(cid))
        body = copy.deepcopy(STATE.messages.get(conversation["conversationId"], [])) if conversation else []
    h.send(200, body)


def envelope(h, user, apply):
    body = h._json_body()
    arg = body.get("arg") if isinstance(body.get("arg"), dict) else {}
    with STATE.lock:
        conversation = STATE.owned(user, arg.get("conversationId"))
        if conversation is None:
            return h.send(404, {"message": "Conversation not found"})
        apply(conversation, arg)
        result = public_conversation(conversation)
    h.send(200, result)


@route("POST", r"/api/convos/update")
@authed
def rename(h, user):
    def apply(c, arg):
        c["title"] = arg.get("title") or c["title"]
        c["updatedAt"] = iso(now())

    envelope(h, user, apply)


@route("POST", r"/api/convos/pin")
@authed
def pin(h, user):
    envelope(h, user, lambda c, arg: c.__setitem__("pinned", bool(arg.get("pinned"))))


@route("POST", r"/api/convos/archive")
@authed
def archive(h, user):
    envelope(h, user, lambda c, arg: c.__setitem__("isArchived", bool(arg.get("isArchived"))))


@route("DELETE", r"/api/convos")
@authed
def delete_convo(h, user):
    body = h._json_body()
    arg = body.get("arg") if isinstance(body.get("arg"), dict) else {}
    with STATE.lock:
        conversation = STATE.owned(user, arg.get("conversationId"))
        if conversation:
            STATE.conversations.pop(conversation["conversationId"], None)
            STATE.messages.pop(conversation["conversationId"], None)
    h.send(200, {"acknowledged": True, "deletedCount": 1 if conversation else 0})


def copy_conversation(user, source, messages, title):
    cid = new_id()
    stamp = now()
    conversation = dict(
        source,
        conversationId=cid,
        title=title,
        pinned=False,
        isArchived=False,
        createdAt=iso(stamp),
        updatedAt=iso(stamp),
        user=user["id"],
    )
    ids = {}
    copied = []
    for msg in messages:
        new = dict(copy.deepcopy(msg), conversationId=cid, messageId=new_id())
        ids[msg["messageId"]] = new["messageId"]
        copied.append(new)
    for msg in copied:
        msg["parentMessageId"] = ids.get(msg["parentMessageId"], ROOT_PARENT)
    STATE.conversations[cid] = conversation
    STATE.messages[cid] = copied
    return {"conversation": public_conversation(conversation), "messages": copied}


@route("POST", r"/api/convos/duplicate")
@authed
def duplicate(h, user):
    body = h._json_body()
    with STATE.lock:
        source = STATE.owned(user, body.get("conversationId"))
        if source is None:
            return h.send(404, {"message": "Conversation not found"})
        result = copy_conversation(
            user, source, STATE.messages.get(source["conversationId"], []), body.get("title") or source["title"]
        )
    h.send(201, result)


@route("POST", r"/api/convos/fork")
@authed
def fork(h, user):
    body = h._json_body()
    with STATE.lock:
        source = STATE.owned(user, body.get("conversationId"))
        if source is None:
            return h.send(404, {"message": "Conversation not found"})
        by_id = {m["messageId"]: m for m in STATE.messages.get(source["conversationId"], [])}
        path, cursor = [], by_id.get(body.get("messageId"))
        while cursor is not None:
            path.insert(0, cursor)
            cursor = by_id.get(cursor["parentMessageId"])
        result = copy_conversation(user, source, path, source["title"])
    h.send(200, result)


# -- generations -------------------------------------------------------------


@route("POST", r"/api/agents/chat/abort")
@authed
def abort(h, user):
    body = h._json_body()
    job = STATE.jobs.get(body.get("conversationId") or body.get("streamId"))
    if job is None or job.done:
        return h.send(404, {"message": "No active generation"})
    with job.cond:
        job.aborted = True
        job.cond.notify_all()
    deadline = time.time() + 3
    while not job.done and time.time() < deadline:
        time.sleep(0.02)
    if not job.done:
        job.finish(aborted=True)
    h.send(200, {"success": True, "aborted": job.cid})


@route("POST", r"/api/agents/chat/resume")
@authed
def resume(h, user):
    body = h._json_body()
    job = STATE.jobs.get(body.get("conversationId"))
    if job is None or job.pending is None:
        return h.send(404, {"message": "Nothing is waiting for an answer."})
    if body.get("actionId") != job.pending.get("actionId"):
        return h.send(409, {"message": "That question was already answered."})
    with STATE.lock:
        STATE.turns.append({"resume": body})
    with job.cond:
        job.answer = body
        job.cond.notify_all()
    h.send(200, {"success": True})


@route("GET", r"/api/agents/chat/active")
@authed
def active(h, user):
    ids = [cid for cid, job in STATE.jobs.items() if not job.done and job.user["id"] == user["id"]]
    h.send(200, {"activeJobIds": ids})


@route("GET", r"/api/agents/chat/status/([^/]+)")
@authed
def status(h, user, cid):
    job = STATE.jobs.get(unquote(cid))
    if job is None or job.done:
        return h.send(200, {"active": False})
    h.send(
        200,
        {
            "active": True,
            "streamId": job.cid,
            "createdAt": job.created_at,
            "status": "running",
            "resumeState": job.snapshot(),
            "pendingAction": job.pending,
        },
    )


@route("GET", r"/api/agents/chat/stream/([^/]+)")
@authed
def stream(h, user, cid):
    job = STATE.jobs.get(unquote(cid))
    if job is None:
        return h.send(404, {"message": "Stream not found"})
    wanted = h.query.get("generationCreatedAt")
    if wanted and wanted != str(job.created_at):
        return h.send(409, {"message": "Replaced by a newer generation"})
    h.send_response(200)
    h.send_header("Content-Type", "text/event-stream")
    h.send_header("Cache-Control", "no-cache")
    h.send_header("Connection", "close")
    h.end_headers()
    h.close_connection = True

    def write(event, payload):
        h.wfile.write(("event: %s\ndata: %s\n\n" % (event, json.dumps(payload))).encode())
        h.wfile.flush()

    with job.cond:
        if h.query.get("resume") == "true":
            sent = len(job.events)
            snapshot = job.snapshot()
            resumed = True
        else:
            sent = 0
            snapshot = None
            resumed = False
    if resumed:
        write("message", {"sync": True, "resumeState": snapshot, "pendingEvents": []})
    last_beat = time.time()
    while True:
        with job.cond:
            while sent >= len(job.events) and not job.done:
                job.cond.wait(timeout=1)
                if time.time() - last_beat > 10:
                    break
            batch = job.events[sent:]
            sent += len(batch)
            finished = job.done and sent >= len(job.events)
        try:
            for event, payload in batch:
                write(event, payload)
                if event == "error" or payload.get("final"):
                    return
            if not batch and time.time() - last_beat > 10:
                h.wfile.write(b":\n\n")
                h.wfile.flush()
                last_beat = time.time()
        except (BrokenPipeError, ConnectionResetError):
            return
        if finished:
            return


@route("POST", r"/api/agents/chat/([^/]+)")
@authed
def start(h, user, endpoint):
    body = h._json_body()
    endpoint = unquote(endpoint)
    with STATE.lock:
        STATE.turns.append({"start": body, "endpoint": endpoint, "user": user["id"]})
        rid = body.get("clientRequestId")
        for job in STATE.jobs.values():
            if rid and job.client_request_id == rid:
                return h.send(
                    200,
                    {
                        "streamId": job.cid,
                        "conversationId": job.cid,
                        "status": "settled" if job.done else "resumed",
                        "generationCreatedAt": job.created_at,
                    },
                )
        cid = body.get("conversationId")
        is_new = not cid or cid == "new"
        if is_new:
            cid = new_id()
            stamp = iso(now())
            conversation = {
                "conversationId": cid,
                "user": user["id"],
                "title": "New Chat",
                "endpoint": endpoint,
                "model": body.get("model"),
                "pinned": False,
                "isArchived": False,
                "createdAt": stamp,
                "updatedAt": stamp,
            }
            for key in ("endpointType", "agent_id", "spec"):
                if body.get(key):
                    conversation[key] = body[key]
            STATE.conversations[cid] = conversation
            STATE.messages[cid] = []
        else:
            conversation = STATE.owned(user, cid)
            if conversation is None:
                return h.send(404, {"message": "Conversation not found"})
            running = STATE.jobs.get(cid)
            if running is not None and not running.done:
                return h.send(409, {"message": "A reply is already running in this chat."})
        msgs = STATE.messages.setdefault(cid, [])
        if body.get("isRegenerate"):
            parent_id = body.get("overrideParentMessageId") or body.get("parentMessageId")
            user_message = next((m for m in msgs if m["messageId"] == parent_id), None)
            if user_message is None:
                return h.send(400, {"message": "The message to regenerate was not found."})
            parent_for_reply = user_message["messageId"]
        else:
            user_message = STATE.message(
                cid,
                body.get("parentMessageId") or ROOT_PARENT,
                body.get("text") or "",
                True,
                files=body.get("files") or None,
            )
            if not user_message.get("files"):
                user_message.pop("files", None)
            msgs.append(user_message)
            parent_for_reply = user_message["messageId"]
        job = Job(STATE, user, dict(body, endpoint=endpoint), conversation, user_message, parent_for_reply, is_new)
        STATE.jobs[cid] = job
    job.thread.start()
    h.send(
        200,
        {"streamId": cid, "conversationId": cid, "status": "started", "generationCreatedAt": job.created_at},
    )


# -- files -------------------------------------------------------------------


@route("GET", r"/api/files/config")
@authed
def files_config(h, user):
    h.send(
        200,
        {
            "endpoints": {
                "default": {"fileLimit": 10, "fileSizeLimit": 20, "supportedMimeTypes": [".*"]},
            },
            "serverFileSizeLimit": 20,
            "avatarSizeLimit": 2,
        },
    )


@route("POST", r"/api/files(/images)?")
@authed
def upload(h, user, images):
    fields, files = parse_multipart(h._body(), h.headers.get("Content-Type"))
    if not files:
        return h.send(400, {"message": "No file was sent."})
    _, filename, ctype, data = files[0]
    file_id = fields.get("file_id") or new_id()
    record = {
        "file_id": file_id,
        "filepath": "/images/%s/%s" % (user["id"], quote(filename)),
        "filename": filename,
        "type": ctype,
        "bytes": len(data),
        "user": user["id"],
        "message": "File uploaded and processed successfully",
    }
    if images:
        record["width"] = int(fields.get("width") or 1)
        record["height"] = int(fields.get("height") or 1)
    STATE.files[file_id] = dict(record, data=data)
    h.send(200, record)


# -- MCP ---------------------------------------------------------------------


@route("GET", r"/api/mcp/tools")
@authed
def mcp_tools(h, user):
    servers = {}
    for name, server in MCP_SERVERS.items():
        servers[name] = {
            "name": name,
            "icon": None,
            "authenticated": STATE.mcp_connected[name],
            "authConfig": [] if not server["requiresOAuth"] else [{"authField": "oauth", "label": "Sign in"}],
            "tools": server["tools"],
        }
    h.send(200, {"servers": servers})


@route("GET", r"/api/mcp/servers")
@authed
def mcp_servers(h, user):
    h.send(
        200,
        {
            name: {"title": s["title"], "chatMenu": True, "consumeOnly": False, "requiresOAuth": s["requiresOAuth"]}
            for name, s in MCP_SERVERS.items()
        },
    )


@route("GET", r"/api/mcp/connection/status")
@authed
def mcp_status(h, user):
    h.send(
        200,
        {
            "success": True,
            "connectionStatus": {
                name: {
                    "connectionState": "connected" if STATE.mcp_connected[name] else "disconnected",
                    "requiresOAuth": s["requiresOAuth"],
                }
                for name, s in MCP_SERVERS.items()
            },
        },
    )


# -- prompts -------------------------------------------------------------------


@route("GET", r"/api/prompts/all")
@authed
def prompts(h, user):
    h.send(
        200,
        [
            {
                "_id": p["_id"],
                "name": p["name"],
                "command": p["command"],
                "category": p["category"],
                "oneliner": p["oneliner"],
                "productionId": p["_id"] + "_v1",
                "productionPrompt": {"_id": p["_id"] + "_v1", "prompt": p["prompt"], "type": "text"},
            }
            for p in PROMPTS
        ],
    )


# -- memories ------------------------------------------------------------------


def memory_list(user):
    entries = STATE.memories.setdefault(user["id"], [])
    total = sum(m["tokenCount"] for m in entries)
    return {
        "memories": entries,
        "totalTokens": total,
        "tokenLimit": 2000,
        "usagePercentage": round(total * 100.0 / 2000),
    }


@route("GET", r"/api/memories")
@authed
def get_memories(h, user):
    with STATE.lock:
        h.send(200, memory_list(user))


@route("POST", r"/api/memories")
@authed
def create_memory(h, user):
    body = h._json_body()
    key, value = (body.get("key") or "").strip(), (body.get("value") or "").strip()
    if not re.fullmatch(r"[a-z_]+", key or "-"):
        return h.send(400, {"error": "Key must only contain lowercase letters and underscores"})
    with STATE.lock:
        entries = STATE.memories.setdefault(user["id"], [])
        if any(m["key"] == key for m in entries):
            return h.send(409, {"error": "Memory with this key already exists"})
        memory = {
            "_id": "mem_" + secrets.token_hex(4),
            "key": key,
            "value": value,
            "tokenCount": token_count(value),
            "updated_at": iso(now()),
        }
        entries.append(memory)
    h.send(201, {"created": True, "memory": memory})


@route("PATCH", r"/api/memories/preferences")
@authed
def memory_preferences(h, user):
    body = h._json_body()
    with STATE.lock:
        STATE.personalization.setdefault(user["id"], {})["memories"] = bool(body.get("memories"))
    h.send(200, {"updated": True, "preferences": {"memories": bool(body.get("memories"))}})


@route("PATCH", r"/api/memories/(id/)?([^/]+)")
@authed
def update_memory(h, user, by_id, key):
    body = h._json_body()
    key = unquote(key)
    with STATE.lock:
        entries = STATE.memories.setdefault(user["id"], [])
        memory = next((m for m in entries if (m["_id"] if by_id else m["key"]) == key), None)
        if memory is None:
            return h.send(404, {"error": "Memory not found"})
        new_key = (body.get("key") or memory["key"]).strip()
        if new_key != memory["key"] and any(m["key"] == new_key for m in entries):
            return h.send(409, {"error": "Memory with this key already exists"})
        memory.update(
            key=new_key,
            value=body.get("value", memory["value"]),
            tokenCount=token_count(body.get("value", memory["value"])),
            updated_at=iso(now()),
        )
    h.send(200, {"updated": True, "memory": memory})


@route("DELETE", r"/api/memories/([^/]+)")
@authed
def delete_memory(h, user, key):
    key = unquote(key)
    with STATE.lock:
        entries = STATE.memories.setdefault(user["id"], [])
        kept = [m for m in entries if m["key"] != key]
        if len(kept) == len(entries):
            return h.send(404, {"error": "Memory not found"})
        STATE.memories[user["id"]] = kept
    h.send(200, {"deleted": True})


# -- share links -----------------------------------------------------------------


@route("GET", r"/api/share/link/([^/]+)")
@authed
def share_link(h, user, cid):
    cid = unquote(cid)
    with STATE.lock:
        found = next(
            ((sid, s) for sid, s in STATE.shares.items() if s["conversationId"] == cid and s["user"] == user["id"]),
            None,
        )
    if found is None:
        return h.send(200, {"success": False, "shareId": None, "conversationId": cid})
    sid, share = found
    h.send(200, {"success": True, "shareId": sid, "conversationId": cid, "snapshotFiles": share["snapshotFiles"]})


@route("POST", r"/api/share/([^/]+)")
@authed
def create_share(h, user, cid):
    cid = unquote(cid)
    body = h._json_body()
    with STATE.lock:
        if STATE.owned(user, cid) is None:
            return h.send(404, {"message": "Conversation not found"})
        if any(s["conversationId"] == cid for s in STATE.shares.values()):
            return h.send(409, {"message": "Share already exists"})
        sid = "share_" + secrets.token_hex(6)
        STATE.shares[sid] = {
            "conversationId": cid,
            "user": user["id"],
            "snapshotFiles": True,
            "targetMessageId": body.get("targetMessageId"),
            "updatedAt": iso(now()),
        }
    h.send(200, {"shareId": sid, "conversationId": cid})


@route("PATCH", r"/api/share/([^/]+)")
@authed
def refresh_share(h, user, sid):
    sid = unquote(sid)
    body = h._json_body()
    with STATE.lock:
        share = STATE.shares.pop(sid, None)
        if share is None or share["user"] != user["id"]:
            return h.send(404, {"message": "Share not found"})
        new_sid = "share_" + secrets.token_hex(6)
        if body.get("snapshotFiles") is not None:
            share["snapshotFiles"] = bool(body["snapshotFiles"])
        share["updatedAt"] = iso(now())
        STATE.shares[new_sid] = share
    h.send(200, {"shareId": new_sid, "conversationId": share["conversationId"]})


@route("DELETE", r"/api/share/([^/]+)")
@authed
def delete_share(h, user, sid):
    with STATE.lock:
        share = STATE.shares.get(unquote(sid))
        if share is None or share["user"] != user["id"]:
            return h.send(404, {"message": "Share not found"})
        STATE.shares.pop(unquote(sid))
    h.send(200, {"success": True, "shareId": unquote(sid)})


@route("GET", r"/share/([^/]+)")
def shared_page(h, sid):
    share = STATE.shares.get(unquote(sid))
    if share is None:
        return h.text(404, PAGE % ("Not found", "<p>This link no longer works.</p>"))
    conversation = STATE.conversations.get(share["conversationId"]) or {}
    h.text(200, PAGE % ("Shared chat", "<h1>%s</h1><p>A shared chat (fake).</p>" % conversation.get("title", "")))


# -- speech ----------------------------------------------------------------------


@route("GET", r"/api/files/speech/config/get")
@authed
def speech_config(h, user):
    h.send(
        200,
        {
            "sttExternal": True,
            "ttsExternal": True,
            "speechToText": True,
            "textToSpeech": True,
            "engineSTT": "external",
            "engineTTS": "external",
            "voice": VOICES[0],
            "languageSTT": "en",
            "playbackRate": 1,
        },
    )


@route("GET", r"/api/files/speech/tts/voices")
@authed
def voices(h, user):
    h.send(200, VOICES)


@route("POST", r"/api/files/speech/stt")
@authed
def stt(h, user):
    h._body()
    h.send(200, {"text": "Harbour lights at dusk"})


@route("POST", r"/api/files/speech/tts/(manual|)")
@authed
def tts(h, user, _):
    h._body()
    h.send(200, tone_wav(), "audio/wav")


# -- test hooks --------------------------------------------------------------------


@route("GET", r"/__fake/state")
def fake_state(h):
    with STATE.lock:
        body = {
            "conversations": [public_conversation(c) for c in STATE.conversations.values()],
            "owners": {cid: c.get("user") for cid, c in STATE.conversations.items()},
            "messages": {cid: len(m) for cid, m in STATE.messages.items()},
            "memories": STATE.memories,
            "personalization": STATE.personalization,
            "shares": STATE.shares,
            "turns": STATE.turns[-20:],
            "sessions": len(STATE.refresh),
            "files": [dict((k, v) for k, v in f.items() if k != "data") for f in STATE.files.values()],
        }
    h.send(200, body)


@route("POST", r"/__fake/reset")
def fake_reset(h):
    h._body()
    STATE.reset()
    h.send(200, {"reset": True})


@route("POST", r"/__fake/end-sessions")
def fake_end_sessions(h):
    h._body()
    with STATE.lock:
        STATE.refresh.clear()
        STATE.access.clear()
    h.send(200, {"ended": True})


@route("POST", r"/__fake/expire-access")
def fake_expire_access(h):
    h._body()
    with STATE.lock:
        STATE.access.clear()
    h.send(200, {"expired": True})


@route("POST", r"/__fake/mcp-connect/([^/]+)")
def fake_mcp_connect(h, name):
    h._body()
    STATE.mcp_connected[unquote(name)] = True
    h.send(200, {"connected": True})


def main():
    global STATE, LOG
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.environ.get("CONDUIT_LIBRECHAT_PORT", "19213")))
    parser.add_argument("--log", default=None)
    parser.add_argument("--token-ttl", type=int, default=900, help="access token lifetime in seconds")
    args = parser.parse_args()
    LOG = args.log
    base = "http://%s:%d" % (args.host, args.port)
    STATE = State(base, args.token_ttl)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    log("fake LibreChat on %s" % base)
    print("ready %s" % base, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
