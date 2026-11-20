"""A stand-in sign-in proxy (as oauth2-proxy, Authelia or Pangolin would sit)
in front of the local Open WebUI, for the desktop app's proxy sign-in and
proxy-renewal passes. Standard library only.

Usage (owui.sh proxy start runs it):
  python3 -I fake_proxy.py --port N --sign-in-port M --upstream URL [--log FILE]

- http://127.0.0.1:N forwards everything to the server, websockets
  included, while it is open (as it starts: a server can be added through
  it) or the request carries a live `conduit_proxy` session cookie.
  Guarded, a request without one is sent (302) to the sign-in page.
- The sign-in page, at http://localhost:M (another origin, as an identity
  provider is), shows Continue; or, while it "remembers" the user, as an
  identity provider with a live session does, sends them straight back.
  Back at /__proxy/callback the proxy sets a new session cookie and
  returns to where the user was going.
- Controls, on the proxy's own port, never forwarded:
    GET  /__proxy/state     {"guarded", "remember", "sessions", "sign_ins"}
    POST /__proxy/guard     guard from now on
    POST /__proxy/open      forward everything again
    POST /__proxy/expire    every session ends (the cookies stop working)
    POST /__proxy/remember  the sign-in page sends users straight back
    POST /__proxy/forget    the sign-in page asks for Continue again

Every session value is random; nothing is written but the request log
(method, path, status, whether a session cookie came along).
"""

import argparse
import html
import json
import secrets
import socket
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COOKIE = 'conduit_proxy'


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.guarded = False
        self.remember = False
        self.sessions = set()
        self.codes = set()
        self.sign_ins = 0


STATE = State()
LOG = None
LOG_LOCK = threading.Lock()


def log(entry):
    if LOG is None:
        return
    entry['at'] = time.time()
    with LOG_LOCK, open(LOG, 'a') as f:
        f.write(json.dumps(entry) + '\n')


def read_head(conn):
    """Reads a request head; returns (head bytes, rest already read)."""
    data = b''
    while b'\r\n\r\n' not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return None, b''
        data += chunk
        if len(data) > 1 << 20:
            return None, b''
    head, rest = data.split(b'\r\n\r\n', 1)
    return head, rest


def parse_head(head):
    lines = head.decode('latin-1').split('\r\n')
    method, target, version = lines[0].split(' ', 2)
    headers = []
    for line in lines[1:]:
        if ':' in line:
            k, v = line.split(':', 1)
            headers.append((k.strip(), v.strip()))
    return method, target, version, headers


def header(headers, name):
    name = name.lower()
    for k, v in headers:
        if k.lower() == name:
            return v
    return None


def session_of(headers):
    for k, v in headers:
        if k.lower() != 'cookie':
            continue
        for part in v.split(';'):
            if '=' in part:
                n, val = part.split('=', 1)
                if n.strip() == COOKIE:
                    return val.strip()
    return None


def respond(conn, status, reason, headers=(), body=b''):
    lines = [f'HTTP/1.1 {status} {reason}']
    lines += [f'{k}: {v}' for k, v in headers]
    lines += [f'Content-Length: {len(body)}', 'Connection: close', '', '']
    conn.sendall('\r\n'.join(lines).encode('latin-1') + body)


def pipe(src, dst):
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle_proxy(conn, args):
    try:
        head, rest = read_head(conn)
        if head is None:
            return
        method, target, version, headers = parse_head(head)
        path = urllib.parse.urlsplit(target).path

        if path.startswith('/__proxy/') and path != '/__proxy/callback':
            control(conn, method, path)
            return

        if path == '/__proxy/callback':
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(target).query)
            code = (query.get('code') or [''])[0]
            back = (query.get('rd') or ['/'])[0]
            if not back.startswith('/'):
                back = '/'
            with STATE.lock:
                valid = code in STATE.codes
                STATE.codes.discard(code)
                sid = secrets.token_urlsafe(24) if valid else None
                if sid:
                    STATE.sessions.add(sid)
                    STATE.sign_ins += 1
            if not sid:
                respond(conn, 403, 'Forbidden', body=b'unknown sign-in code')
                log({'method': method, 'path': path, 'status': 403})
                return
            respond(conn, 302, 'Found', [
                ('Location', back),
                ('Set-Cookie', f'{COOKIE}={sid}; Path=/; HttpOnly; SameSite=Lax'),
            ])
            log({'method': method, 'path': path, 'status': 302, 'signed_in': True})
            return

        sid = session_of(headers)
        with STATE.lock:
            allowed = not STATE.guarded or (sid is not None and sid in STATE.sessions)
        if not allowed:
            back = urllib.parse.quote(target, safe='')
            location = (f'http://localhost:{args.sign_in_port}/sign-in?rd={back}'
                        f'&port={args.port}')
            respond(conn, 302, 'Found', [('Location', location)])
            log({'method': method, 'path': path, 'status': 302, 'cookie': sid is not None})
            return

        upstream = urllib.parse.urlsplit(args.upstream)
        up = socket.create_connection((upstream.hostname, upstream.port or 80), timeout=30)
        up.settimeout(None)
        conn.settimeout(None)
        upgrade = (header(headers, 'upgrade') or '').lower() == 'websocket'
        out = [f'{method} {target} {version}']
        for k, v in headers:
            if k.lower() == 'host':
                v = upstream.netloc
            elif k.lower() == 'connection' and not upgrade:
                continue
            out.append(f'{k}: {v}')
        if not upgrade:
            # One request per connection, so every request is checked.
            out.append('Connection: close')
        up.sendall(('\r\n'.join(out) + '\r\n\r\n').encode('latin-1') + rest)
        log({'method': method, 'path': path, 'status': 'forwarded', 'cookie': sid is not None,
             'websocket': upgrade})
        t = threading.Thread(target=pipe, args=(up, conn), daemon=True)
        t.start()
        pipe(conn, up)
        t.join(timeout=600)
    except Exception as error:  # a test stand-in: say why, keep serving
        log({'error': repr(error)[:200]})
    finally:
        try:
            conn.close()
        except OSError:
            pass


def control(conn, method, path):
    with STATE.lock:
        if method == 'POST' and path == '/__proxy/guard':
            STATE.guarded = True
        elif method == 'POST' and path == '/__proxy/open':
            STATE.guarded = False
        elif method == 'POST' and path == '/__proxy/expire':
            STATE.sessions.clear()
        elif method == 'POST' and path == '/__proxy/remember':
            STATE.remember = True
        elif method == 'POST' and path == '/__proxy/forget':
            STATE.remember = False
        elif not (method == 'GET' and path == '/__proxy/state'):
            respond(conn, 404, 'Not Found')
            return
        body = json.dumps({
            'guarded': STATE.guarded,
            'remember': STATE.remember,
            'sessions': len(STATE.sessions),
            'sign_ins': STATE.sign_ins,
        }).encode()
    respond(conn, 200, 'OK', [('Content-Type', 'application/json')], body)
    log({'method': method, 'path': path, 'status': 200})


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<title>Sign in to Harbour Gate</title>
<style>
body{{font:15px -apple-system,system-ui,sans-serif;margin:0;display:grid;place-items:center;
min-height:100vh;background:#f4f4f2;color:#1d1d1f}}
@media (prefers-color-scheme:dark){{body{{background:#1c1c1e;color:#f5f5f7}}
.card{{background:#2c2c2e}}}}
.card{{background:#fff;padding:28px 32px;border-radius:14px;max-width:320px;
box-shadow:0 1px 3px rgba(0,0,0,.12)}}
h1{{font-size:19px;margin:0 0 8px}}p{{margin:0 0 20px;color:#6e6e73}}
a{{display:inline-block;background:#1d1d1f;color:#fff;padding:8px 18px;border-radius:8px;
text-decoration:none}}
</style></head><body><div class="card"><h1>Harbour Gate</h1>
<p>A stand-in sign-in proxy for local testing.</p>
<a id="continue" href="{href}">Continue</a></div></body></html>"""


class SignInPage(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        parts = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parts.query)
        back = (query.get('rd') or ['/'])[0]
        port = (query.get('port') or [''])[0]
        if parts.path not in ('/sign-in', '/approve') or not port.isdigit():
            self.send_response(404)
            self.end_headers()
            return
        with STATE.lock:
            remember = STATE.remember
        if parts.path == '/approve' or remember:
            code = secrets.token_urlsafe(16)
            with STATE.lock:
                STATE.codes.add(code)
            location = (f'http://127.0.0.1:{port}/__proxy/callback?code={code}'
                        f'&rd={urllib.parse.quote(back, safe="")}')
            self.send_response(302)
            self.send_header('Location', location)
            self.send_header('Content-Length', '0')
            self.end_headers()
            log({'page': parts.path, 'status': 302})
            return
        href = '/approve?' + urllib.parse.urlencode({'rd': back, 'port': port})
        body = PAGE.format(href=html.escape(href)).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        log({'page': parts.path, 'status': 200})


def main():
    global LOG
    parser = argparse.ArgumentParser(description='A stand-in sign-in proxy.')
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--sign-in-port', type=int, required=True)
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--log')
    args = parser.parse_args()
    LOG = args.log

    pages = ThreadingHTTPServer(('127.0.0.1', args.sign_in_port), SignInPage)
    threading.Thread(target=pages.serve_forever, daemon=True).start()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', args.port))
    listener.listen(128)
    print(f'proxy on {args.port}, sign-in page on {args.sign_in_port}', flush=True)
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=handle_proxy, args=(conn, args), daemon=True).start()


if __name__ == '__main__':
    main()
