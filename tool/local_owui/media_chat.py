"""Stores a chat whose answer links pictures and PDFs from "another site"
(media_site.py) and the server, and has a Mermaid diagram, a chart and a
broken diagram, for the desktop app's `--e2e rendering-media` pass.

Usage: python3 -I media_chat.py --env-file FILE --site URL --out DIR

Uploads a synthetic picture and a synthetic PDF to the server (its own
files, which load without asking), then stores the chat. Writes
DIR/media.json with the ids. Every word, picture and page is invented.
"""

import argparse
import json
import os
import struct
import time
import urllib.error
import urllib.request
import uuid
import zlib

MODEL = 'fake-model'


def request(base, method, path, body=None, token=None, raw=None, content_type=None):
    req = urllib.request.Request(base + path, method=method, data=raw if raw is not None else (
        json.dumps(body).encode() if body is not None else None))
    req.add_header('Content-Type', content_type or 'application/json')
    req.add_header('User-Agent', 'conduit-local-owui-media')
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as err:
        raise SystemExit(f'{method} {path} -> {err.code}: {err.read()[:300]!r}')


def upload(base, token, name, data, content_type):
    boundary = uuid.uuid4().hex
    payload = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
        f'Content-Type: {content_type}\r\n\r\n'
    ).encode() + data + f'\r\n--{boundary}--\r\n'.encode()
    return request(base, 'POST', '/api/v1/files/', token=token, raw=payload,
                   content_type=f'multipart/form-data; boundary={boundary}')


def read_env(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                values[k] = v
    return values


def office_chart():
    """The harbour office's own chart: green bars on white (360 x 180)."""
    rows = []
    for y in range(180):
        row = bytearray([0])
        for x in range(360):
            v = (250, 250, 248)
            for bx, h in [(40, 0.5), (130, 0.8), (220, 0.65)]:
                if bx <= x < bx + 60 and y >= 180 - int(h * 160):
                    v = (90, 160, 110)
            row += bytes(v)
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 360, 180, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


def guide_pdf():
    """A two-page synthetic harbour guide."""
    pages = ['Harbour guide: Port Wren', 'Moorings and the ramp']
    objects = ['<< /Type /Catalog /Pages 2 0 R >>']
    kids = ' '.join(f'{3 + 2 * i} 0 R' for i in range(len(pages)))
    objects.append(f'<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>')
    font = 3 + 2 * len(pages)
    for i, text in enumerate(pages):
        stream = (f'0.2 0.5 0.3 rg 0 742 612 50 re f BT /F1 26 Tf 72 680 Td ({text}) Tj ET '
                  f'0.6 g 72 640 468 4 re f 72 620 380 4 re f')
        objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
                       f'/Resources << /Font << /F1 {font} 0 R >> >> /Contents {4 + 2 * i} 0 R >>')
        objects.append(f'<< /Length {len(stream)} >>\nstream\n{stream}\nendstream')
    objects.append('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    out = '%PDF-1.4\n'
    offsets = []
    for n, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += f'{n} 0 obj\n{body}\nendobj\n'
    xref = len(out)
    out += f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'
    out += ''.join(f'{o:010} 00000 n \n' for o in offsets)
    out += f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'
    return out.encode('latin-1')


MERMAID = (
    '```mermaid\ngraph TD\n  accTitle: Tide cycle\n  A[Low water] --> B[Flood tide]\n'
    '  B --> C[High water]\n  C --> D[Ebb tide]\n  D --> A\n```'
)
CHART = (
    '```chart\n' + json.dumps({
        'type': 'bar',
        'data': {'labels': ['Mon', 'Tue', 'Wed', 'Thu'],
                 'datasets': [{'label': 'High water (m)', 'data': [4.1, 4.3, 4.6, 4.2]}]},
        'options': {'plugins': {'title': {'display': True, 'text': 'Water levels'}}},
    }) + '\n```'
)
BROKEN = '```mermaid\ngraph TD\n  A[Harbour --> B[[ open\n```'


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--site', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    env = read_env(args.env_file)
    base = env['OWUI_URL'].rstrip('/')
    site = args.site.rstrip('/')
    token = request(base, 'POST', '/api/v1/auths/signin',
                    {'email': env['OWUI_EMAIL'], 'password': env['OWUI_PASSWORD']})['token']
    chart = upload(base, token, 'office-chart.png', office_chart(), 'image/png')
    guide = upload(base, token, 'harbour-guide.pdf', guide_pdf(), 'application/pdf')
    page = env.get('FAKE_PAGE_URL', 'http://127.0.0.1:8151/page/raised-beds')

    content = (
        'Here are the harbour pictures [1], the tide cycle and this week\'s water levels.\n\n'
        f'![Tide chart for Port Wren]({site}/tide-chart.png)\n\n'
        f'![]({site}/harbour-map.png)\n\n'
        f'![Ferry timetable]({site}/not-a-picture.png)\n\n'
        'The harbour office\'s own chart:\n\n'
        f'![Harbour office chart](/api/v1/files/{chart["id"]}/content)\n\n'
        f'{MERMAID}\n\n{CHART}\n\n'
        f'This one has a mistake in it:\n\n{BROKEN}\n\n'
        'Read the guides:\n\n'
        f'[📄 Tide tables]({site}/tide-tables.pdf)\n\n'
        f'[harbour-guide.pdf](/api/v1/files/{guide["id"]}/content)\n\n'
        f'The [ferry notes]({site}/ferry-notes.pdf) are short.\n\n'
        'Fair winds.'
    )
    sources = [
        {'source': {'name': 'Raised beds and tides', 'url': page},
         'document': ['Spring tides rise highest a day or two after a full moon.'],
         'metadata': [{'source': page, 'name': 'Raised beds and tides', 'title': 'Spring and neap tides'}]},
    ]
    at = int(time.time())
    u, a = str(uuid.uuid4()), str(uuid.uuid4())
    messages = {
        u: {'id': u, 'parentId': None, 'childrenIds': [a], 'role': 'user',
            'content': 'Show me the harbour pictures and guides.', 'timestamp': at,
            'models': [MODEL]},
        a: {'id': a, 'parentId': u, 'childrenIds': [], 'role': 'assistant',
            'content': content, 'model': MODEL, 'modelName': MODEL, 'done': True,
            'timestamp': at + 1, 'sources': sources},
    }
    created = request(base, 'POST', '/api/v1/chats/new', {'chat': {
        'title': 'Harbour pictures',
        'models': [MODEL],
        'messages': list(messages.values()),
        'history': {'messages': messages, 'currentId': a},
        'timestamp': at * 1000,
    }}, token)
    os.makedirs(args.out, exist_ok=True)
    out = {'chat_id': created['id'], 'site': site, 'chart_id': chart['id'],
           'guide_id': guide['id']}
    with open(os.path.join(args.out, 'media.json'), 'w') as f:
        json.dump(out, f)
    print('media', json.dumps(out))


if __name__ == '__main__':
    main()
