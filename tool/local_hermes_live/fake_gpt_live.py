"""A fake GPT-Live vendor for a local Hermes Desktop Gateway, for the desktop
app's `--e2e voice-call-hermes` pass. Standard library only.

A real `hermes serve` opens GPT-Live calls by exchanging the app's WebRTC
offer for an answer at `{voice.gpt_live.base_url}/live/sessions`, with the
key it keeps. Pointed here instead (see README.md), the offer is handed to a
peer page (`peer.html`, run in WebKit by `peer_host.swift`) that answers it
as the voice would: it plays a tone back, measures what it hears, and
speaks the voice's events on the data channel (invented lines: a request
the voice hands to the chat, the chat's answer said back).

    python3 -I fake_gpt_live.py PORT [--turn TURN_PORT]

With --turn, a TURN relay on 127.0.0.1 (turn_relay.py) runs beside it, and
each offer tells the peer page to use only that relay: the call's packets
stay on loopback, so macOS never asks for Local Network access. The app's
side gets the same relay from the E2E pass (GPT_LIVE_TURN_*).

Routes:
  POST /v1/live/sessions   the gateway's session request (Bearer key)
  GET  /peer               the peer page
  GET  /peer/next          the next offer for the page (long poll; 204)
  POST /peer/answer        the page's answer {id, sdp}
  POST /peer/report        what the page heard and did
  GET  /stats              everything above, for the E2E pass
"""

import json
import os
import queue
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from turn_relay import TurnRelay  # noqa: E402

TURN_USER = "conduit"
TURN_PASSWORD = "local-demo"
_turn = {"relay": None, "port": None}

_jobs = queue.Queue()
_answers = {}
_lock = threading.Lock()
_state = {"sessions": [], "peer": {}, "events": [], "polls": 0}


def _log(*parts):
    sys.stderr.write(time.strftime("%H:%M:%S ") + " ".join(str(p) for p in parts) + "\n")
    sys.stderr.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return None

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/peer":
            with open(os.path.join(HERE, "peer.html"), "rb") as page:
                self._send(200, page.read(), "text/html; charset=utf-8")
        elif path == "/peer/next":
            with _lock:
                _state["polls"] += 1
                _state["lastPoll"] = time.time()
            try:
                job = _jobs.get(timeout=20)
            except queue.Empty:
                self._send(204, b"", "text/plain")
                return
            self._send(200, job)
        elif path == "/stats":
            with _lock:
                body = json.loads(json.dumps(_state))
            body["peerAlive"] = time.time() - body.get("lastPoll", 0) < 30
            relay = _turn["relay"]
            if relay is not None:
                body["turn"] = dict(relay.stats, port=_turn["port"])
            self._send(200, body)
        else:
            self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self._body()
        if body is None:
            self._send(400, {"error": {"message": "bad json"}})
            return
        if path == "/v1/live/sessions":
            self._session(body)
        elif path == "/peer/answer":
            waiting = _answers.get(body.get("id"))
            if waiting is None:
                self._send(404, {"error": {"message": "no such offer"}})
                return
            waiting["sdp"] = body.get("sdp") or ""
            waiting["done"].set()
            self._send(200, {"ok": True})
        elif path == "/peer/report":
            with _lock:
                for event in body.pop("events", []):
                    _state["events"].append(event)
                    _log("peer:", json.dumps(event)[:200])
                _state["peer"].update(body)
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": {"message": "not found"}})

    def _session(self, body):
        if not (self.headers.get("Authorization") or "").startswith("Bearer "):
            self._send(401, {"error": {"message": "no key"}})
            return
        session = body.get("session") or {}
        transport = body.get("transport") or {}
        offer = transport.get("sdp") or ""
        if transport.get("type") != "webrtc" or not offer.strip():
            self._send(400, {"error": {"message": "an SDP offer is required"}})
            return
        session_id = "sess_" + uuid.uuid4().hex[:12]
        record = {
            "id": session_id,
            "model": session.get("model"),
            "voice": (session.get("audio") or {}).get("output", {}).get("voice"),
            "delegation": (session.get("delegation") or {}).get("type"),
            "history": len(session.get("input") or []),
            "offerEndsWithCrlf": offer.endswith("\r\n"),
            "offerHasAudio": "m=audio" in offer,
            "offerHasData": "m=application" in offer,
            # What the offer's candidates are: only relay ones in the E2E
            # pass (nothing on the local network).
            "candidates": {
                kind: sum(1 for line in offer.splitlines()
                          if line.startswith("a=candidate") and f" typ {kind}" in line)
                for kind in ("host", "srflx", "prflx", "relay")
            },
            "mdnsCandidates": sum(1 for line in offer.splitlines()
                                  if line.startswith("a=candidate") and ".local " in line),
        }
        with _lock:
            _state["sessions"].append(record)
        _log("session", json.dumps(record))
        job_id = uuid.uuid4().hex
        waiting = {"done": threading.Event(), "sdp": ""}
        _answers[job_id] = waiting
        job = {"id": job_id, "session": session_id, "offer": offer}
        if _turn["port"]:
            job["turn"] = {
                "urls": f"turn:127.0.0.1:{_turn['port']}?transport=udp",
                "username": TURN_USER,
                "credential": TURN_PASSWORD,
            }
        _jobs.put(job)
        if not waiting["done"].wait(timeout=25) or not waiting["sdp"].strip():
            _answers.pop(job_id, None)
            _log("no answer from the peer page")
            self._send(502, {"error": {"message": "the peer page did not answer"}})
            return
        _answers.pop(job_id, None)
        self._send(200, {
            "session": {"id": session_id, "object": "live.session"},
            "transport": {"type": "webrtc", "sdp": waiting["sdp"]},
        })


def main():
    args = sys.argv[1:]
    port = int(args[0]) if args and not args[0].startswith("-") else 19335
    if "--turn" in args:
        turn_port = int(args[args.index("--turn") + 1])
        relay = TurnRelay(turn_port, TURN_USER, TURN_PASSWORD, log=lambda m: _log(m))
        relay.start()
        _turn.update(relay=relay, port=turn_port)
    _log("fake GPT-Live on", port)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
