"""A stand-in for "another site" that an answer links pictures and PDFs
from, for the desktop app's `--e2e rendering-media` pass.

Usage: python3 -I media_site.py --port N --log FILE [--host ADDRESS]

Serves, all made here and invented:
  /tide-chart.png      a bar chart (480 x 240)
  /harbour-map.png     a map-like drawing (320 x 200)
  /not-a-picture.png   an HTML page, under a picture's name
  /tide-tables.pdf     a three-page PDF
  /to-this-mac.png     a redirect to /this-mac-only.png on 127.0.0.1, which
                       a fetch that may not reach this Mac never follows
  /this-mac-only.png   a picture, for that redirect

--host is the address it listens on (default 127.0.0.1): the desktop app
fetches another site's pictures only from addresses off this Mac, so the
pass serves it on the Mac's network address too.

Every answer sets a cookie, so a client that kept cookies would send it
back. Each request's method, path and the headers that would identify the
user (Cookie, Referer, Authorization, User-Agent) go to FILE as one JSON
line, for the pass to check what was asked for and with what.
"""

import argparse
import json
import struct
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def png(width, height, pixel):
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row += bytes(pixel(x, y))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


def tide_chart():
    bars = [(50, 0.45, (70, 120, 200)), (150, 0.7, (70, 120, 200)),
            (250, 0.9, (70, 120, 200)), (350, 0.6, (70, 120, 200))]

    def pixel(x, y):
        for bx, h, colour in bars:
            if bx <= x < bx + 70 and y >= 240 - int(h * 210):
                return colour
        if y == 239 or x == 0:
            return (60, 60, 60)
        return (252, 252, 250)

    return png(480, 240, pixel)


def harbour_map():
    def pixel(x, y):
        if (x - 220) ** 2 + (y - 90) ** 2 < 55 ** 2:
            return (210, 190, 140)  # an island
        if y > 150:
            return (120, 160, 110)  # the shore
        return (150, 195, 225)  # water

    return png(320, 200, pixel)


def pdf(pages):
    """A minimal PDF with one line of text per page."""
    objects = ['<< /Type /Catalog /Pages 2 0 R >>']
    kids = ' '.join(f'{3 + 2 * i} 0 R' for i in range(len(pages)))
    objects.append(f'<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>')
    font = 3 + 2 * len(pages)
    for i, text in enumerate(pages):
        stream = (f'0.15 0.35 0.65 rg 0 742 612 50 re f '
                  f'BT /F1 28 Tf 72 680 Td ({text}) Tj ET '
                  f'0.6 g 72 640 468 4 re f 72 620 400 4 re f 72 600 440 4 re f')
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


PAGES = {
    '/tide-chart.png': ('image/png', tide_chart()),
    '/harbour-map.png': ('image/png', harbour_map()),
    '/not-a-picture.png': ('text/html', b'<!doctype html><title>Not a picture</title><p>A page.</p>'),
    '/tide-tables.pdf': ('application/pdf', pdf(['Tide tables: Port Wren', 'Spring tides', 'Neap tides'])),
    '/this-mac-only.png': ('image/png', harbour_map()),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('--host', default='127.0.0.1')
    args = parser.parse_args()
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            entry = {
                'method': 'GET', 'path': self.path,
                'cookie': self.headers.get('Cookie'),
                'referer': self.headers.get('Referer'),
                'authorization': self.headers.get('Authorization'),
                'user_agent': self.headers.get('User-Agent'),
            }
            with lock, open(args.log, 'a') as f:
                f.write(json.dumps(entry) + '\n')
            if self.path.split('?')[0] == '/to-this-mac.png':
                self.send_response(302)
                self.send_header('Location', f'http://127.0.0.1:{args.port}/this-mac-only.png')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            page = PAGES.get(self.path.split('?')[0])
            if page is None:
                self.send_response(404)
                self.end_headers()
                return
            kind, body = page
            self.send_response(200)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Set-Cookie', 'visitor=synthetic-tracker; Path=/')
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f'media site on http://{args.host}:{args.port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
