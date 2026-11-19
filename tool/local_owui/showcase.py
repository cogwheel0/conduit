"""Stores a chat that shows every rich part of an answer, for the desktop
app's `--e2e rendering` pass and its screenshots.

Usage: python3 -I showcase.py --env-file FILE --secret-file FILE --out DIR

The answer has GitHub-style alerts, citations of two sources (a page the
fake model serves, and a file), a tool call that returned HTML, an MCP App
(the fake model's `show_tides`, bound with the server's secret as Open
WebUI binds one), a synthetic chart (PNG) and, when ffmpeg is installed, a
two-second synthetic video. Writes DIR/showcase.json with the ids. Every
word, picture and frame is invented.
"""

import argparse
import hmac
import html
import json
import os
import shutil
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import zlib

MODEL = 'fake-model'


class Server:
    """The few calls the showcase makes (as seed.py's, which `-I` keeps
    from being imported)."""

    def __init__(self, base):
        self.base = base.rstrip('/')

    def ok(self, method, path, body=None, token=None):
        req = urllib.request.Request(self.base + path, method=method)
        req.add_header('Content-Type', 'application/json')
        req.add_header('User-Agent', 'conduit-local-owui-showcase')
        if token:
            req.add_header('Authorization', f'Bearer {token}')
        data = json.dumps(body).encode() if body is not None else None
        try:
            with urllib.request.urlopen(req, data, timeout=60) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as err:
            raise SystemExit(f'{method} {path} -> {err.code}: {err.read()[:300]!r}')

    def upload(self, token, name, data, content_type):
        boundary = uuid.uuid4().hex
        payload = (
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
            f'Content-Type: {content_type}\r\n\r\n'
        ).encode() + data + f'\r\n--{boundary}--\r\n'.encode()
        req = urllib.request.Request(self.base + '/api/v1/files/', data=payload, method='POST')
        req.add_header('Content-Type', f'multipart/form-data; boundary={boundary}')
        req.add_header('Authorization', f'Bearer {token}')
        req.add_header('User-Agent', 'conduit-local-owui-showcase')
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read())


def read_env(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                values[k] = v
    return values


def chart_png(width=480, height=270):
    """A synthetic bar chart: four grey bars on white."""
    rows = []
    bars = [(60, 0.55), (160, 0.8), (260, 0.4), (360, 0.95)]
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            v = 255
            for bx, h in bars:
                if bx <= x < bx + 60 and y >= height - int(h * (height - 30)):
                    v = 110
            if y == height - 1 or x == 0:
                v = 60
            row += bytes((v, v, v))
        rows.append(bytes(row))
    raw = zlib.compress(b''.join(rows), 9)

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', raw) + chunk(b'IEND', b''))


def video_mp4():
    """Two seconds of a synthetic test pattern, or None without ffmpeg."""
    ffmpeg = shutil.which('ffmpeg') or ('/opt/homebrew/bin/ffmpeg' if os.path.exists('/opt/homebrew/bin/ffmpeg') else None)
    if not ffmpeg:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'harbour.mp4')
        subprocess.run([ffmpeg, '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'testsrc=duration=2:size=320x180:rate=15', '-pix_fmt', 'yuv420p',
                        '-c:v', 'libx264', '-movflags', '+faststart', out], check=True)
        with open(out, 'rb') as f:
            return f.read()


def app_binding(secret, server_id, tool_name):
    """Open WebUI's MCP App binding (open_webui/utils/mcp/apps.py)."""
    payload = json.dumps([server_id, tool_name], ensure_ascii=True).encode()
    return hmac.digest(secret.encode(), b'open-webui-mcp-app-v1\n' + payload, 'sha256').hex()


TOOL_HTML = (
    '<!doctype html><html><body style="font:14px -apple-system,sans-serif;margin:12px">'
    '<h2 style="margin:0 0 8px">Harbour board</h2>'
    '<p id="args">No arguments.</p>'
    '<div style="height:120px;background:linear-gradient(90deg,#ddd,#999);border-radius:8px"></div>'
    '<script>document.getElementById("args").textContent = "Port: " + '
    '(JSON.parse(window.args || "{}").port || "none");</script>'
    '</body></html>'
)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--secret-file', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    env = read_env(args.env_file)
    secret = open(args.secret_file).read().strip()
    server = Server(env['OWUI_URL'])
    token = server.ok('POST', '/api/v1/auths/signin',
                      {'email': env['OWUI_EMAIL'], 'password': env['OWUI_PASSWORD']})['token']

    chart = server.upload(token, 'tide-chart.png', chart_png(), 'image/png')
    video_bytes = video_mp4()
    video = server.upload(token, 'harbour-loop.mp4', video_bytes, 'video/mp4') if video_bytes else None
    page = env.get('FAKE_PAGE_URL', 'http://127.0.0.1:8151/page/raised-beds')

    tool_args = json.dumps({'port': 'Wren'})
    embeds_attr = html.escape(json.dumps([TOOL_HTML]), quote=True)
    args_attr = html.escape(tool_args, quote=True)
    result_attr = html.escape(json.dumps('Shown on the board.'), quote=True)
    content = (
        'Here is the harbour report for Port Wren [1], with the tide notes [2].\n\n'
        '<details type="tool_calls" done="true" id="call_board" name="harbour_board" '
        f'arguments="{args_attr}" result="{result_attr}" embeds="{embeds_attr}">\n'
        '<summary>Tool Executed</summary>\n</details>\n\n'
        '> [!NOTE]\n> The tide tables here are synthetic.\n\n'
        '> [!TIP]\n> Leave **an hour** before high water.\n\n'
        '> [!IMPORTANT]\n> Tell someone your route.\n\n'
        '> [!WARNING]\n> The harbour wall is slippery.\n\n'
        '> [!CAUTION]\n> Do not sail after dark.\n\n'
        'Fair winds.'
    )
    app = {
        'type': 'mcp_app', 'server_id': 'harbour', 'tool_name': 'show_tides',
        'binding': app_binding(secret, 'harbour', 'show_tides'),
        'arguments': {'port': 'Wren'},
        'result': {'content': [{'type': 'text', 'text': 'High water 06:12, low water 12:40.'}]},
    }
    sources = [
        {'source': {'name': 'Raised beds and tides', 'url': page},
         'document': ['Spring tides rise highest a day or two after a full moon; neap tides '
                      'follow the quarter moons and change the least.'],
         'metadata': [{'source': page, 'name': 'Raised beds and tides', 'title': 'Spring and neap tides'}]},
        {'source': {'name': 'harbour-notes.txt', 'type': 'file'},
         'document': ['The harbour wall is slippery at low water; the ramp is on the east side.'],
         'metadata': [{'name': 'harbour-notes.txt', 'source': 'harbour-notes.txt'}]},
    ]
    files = [{'type': 'image', 'id': chart['id'], 'name': 'tide-chart.png',
              'content_type': 'image/png'}]
    if video:
        files.append({'type': 'file', 'id': video['id'], 'name': 'harbour-loop.mp4',
                      'content_type': 'video/mp4'})

    at = int(time.time())
    u, a = str(uuid.uuid4()), str(uuid.uuid4())
    messages = {
        u: {'id': u, 'parentId': None, 'childrenIds': [a], 'role': 'user',
            'content': 'Show me the harbour report.', 'timestamp': at, 'models': [MODEL]},
        a: {'id': a, 'parentId': u, 'childrenIds': [], 'role': 'assistant',
            'content': content, 'model': MODEL, 'modelName': MODEL, 'done': True,
            'timestamp': at + 1, 'sources': sources, 'files': files,
            'embeds': [app, page]},
    }
    created = server.ok('POST', '/api/v1/chats/new', {'chat': {
        'title': 'Harbour report',
        'models': [MODEL],
        'messages': list(messages.values()),
        'history': {'messages': messages, 'currentId': a},
        'timestamp': at * 1000,
    }}, token)
    os.makedirs(args.out, exist_ok=True)
    out = {'chat_id': created['id'], 'image_id': chart['id'],
           'video_id': video['id'] if video else None, 'page_url': page}
    with open(os.path.join(args.out, 'showcase.json'), 'w') as f:
        json.dump(out, f)
    print('showcase', json.dumps(out))


if __name__ == '__main__':
    main()
