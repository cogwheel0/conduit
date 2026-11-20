"""An OpenAI-compatible chat completions server for local Open WebUI tests.

Usage: python3 -I fake_model.py --port 8151 [--log requests.jsonl]

Open WebUI reaches it as an OpenAI connection; the desktop app's direct
mode can use it straight (http://127.0.0.1:<port>/v1, any API key). It
offers three models:

- "fake-model" answers from the last *user* message (Open WebUI puts
  hidden tool results after it), case-insensitive, first match wins:
  - "... the word: X", "... just: X": the word X;
  - "what is my favourite colour": the colour an earlier message named;
  - "fail": HTTP 500; "refuse": HTTP 400 with a reason;
  - "time": a call to `get_current_timestamp` (with `__labels__`, and
    `__approval__` required when the message also says "approve"; every
    other call states `__approval__` not required, as the server's auto
    tool permissions ask for any call that does not say);
  - "tool" (direct mode): a call to `web_fetch` for a URL not in the
    message, which the app must refuse;
  - "display" with a terminal selected: a call to the terminal's
    `display_file` for `/home/demo/notes.txt` (which Open WebUI turns into
    a `terminal:display_file` event), then a short answer; "tide table"
    asks for `/home/demo/tides.pdf` at page 2 instead;
  - "ask me": a call to Open WebUI's `ask_user` with two questions, then,
    answered, "You chose X and Y.";
  - "plan the tasks": a call to `create_tasks` with three tasks, then a
    short answer;
  - "buoy", offered the personal tool server's `read_buoy`: a call to it,
    then an answer that quotes the reading it came back with;
  - "alerts": one of each GitHub-style alert;
  - "reason": reasoning (`reasoning_content`) first, then the answer below;
  - "code": python, html and mermaid code blocks;
  - "math": inline and display math;
  - "long": about 32,000 characters, streamed in small chunks;
  - "slow": one word every 200 ms for a minute (to stop it);
  - "effort", sent with a `reasoning_effort`: HTTP 400 naming the
    parameter, as a provider that does not take it answers;
  - Open WebUI's Merge Responses prompt ("synthesize these responses"):
    one merged sentence;
  - anything else: a short greeting.
  A streamed answer ends with a usage chunk (tokens and timings).
- "fake-model-b" answers as "fake-model" does, each answer starting "B: ",
  so Compare Models and Regenerate With have a second model.
- "fake-refused" refuses every request with HTTP 400, as a provider does
  for a model the account may not use.

Open WebUI's background tasks (title, tags, follow-ups) get JSON answers,
and a note sent as `<notes>...</notes>` comes back as a markdown list.
`/realtime` (a WebSocket, OpenAI's Realtime API shape) is a scripted
realtime voice, for Open WebUI's call bridge and the Direct voice provider:
it hears speech by loudness in the 24 kHz PCM it is sent, transcribes the
first utterance of a session as "What is the weather like by the harbour"
(answered by the voice itself) and later ones as "Ask the chat for a short
greeting" (handed to the chat's model as a `generate_chat_completion` call,
whose result it then says), and speaks as a quiet synthetic tone with a
word-by-word caption. The log gets each event type it receives and sends.
`/audio/transcriptions` answers with a fixed sentence (or, when a test wrote
`<log>.transcripts`, its next line; the log gets the
upload's size, its WAV's length and its language; six seconds or more of
audio take 4 s to answer) and `/audio/speech` with silence (WAV) about as
long as the text would take to say, for the server's speech features;
"read aloud" in a prompt gets four long sentences to read. `/mcp` is a
small MCP server (streamable HTTP, JSON answers)
with one MCP App, `show_tides`, whose page shows the tool's result, for
Open WebUI's MCP Apps. `/personal` is a personal tool server
(OpenAPI): `/personal/openapi.json` describes one operation, `read_buoy`
(`POST /personal/buoy`), which answers with an invented reading; the log
gets each call. `/webhook/...` takes a webhook delivery (any POST) and logs
its body, for Open WebUI's webhook destinations. `fake_direct.py` adds what the desktop's Direct
pass needs: a local Ollama API under `/ollama`, the Responses API, and an
OAuth-protected MCP server (`/oauth-mcp`) with its authorization server; a
"ferry" prompt offered that server's tool calls it. Every answer is invented. The log gets each request's roles, tool names,
whether it streamed, its system text, its last user text and its generation
params (temperature, seed, reasoning effort, ...): what a test needs to check
that a chat's or a folder's settings reached the model. The text is the seed's
or a test's own, all synthetic.
"""

import argparse
import base64
import hashlib
import io
import json
import math
import os
import re
import struct
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Run with -I, which leaves this directory off the path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fake_direct  # noqa: E402

MODEL = 'fake-model'
# Request keys the log keeps: what a chat's settings may send.
LOGGED_PARAMS = ('temperature', 'top_p', 'top_k', 'min_p', 'max_tokens', 'seed', 'stop',
                 'frequency_penalty', 'presence_penalty', 'reasoning_effort', 'format')
SECOND_MODEL = 'fake-model-b'
MERGE_PROMPT = re.compile(r'synthesize these responses', re.IGNORECASE)
MERGED = 'A merged answer from the fake model: both responses agree, in fewer words.'
EFFORT_REFUSAL = 'Unsupported parameter: reasoning_effort is not supported with this model.'
REFUSED_MODEL = 'fake-refused'
REFUSAL = 'fake-refused is not available on this plan (a synthetic refusal).'

LONG_PARA = (
    'Synthetic paragraph {n}: a steady stream of plain words about orbits, tides and '
    'clockwork, written only to make a long answer for a rendering test. It has a '
    '**bold phrase**, an `inline code` span and a [link](https://example.org/{n}). '
)

WORD = re.compile(r'(?:the word|just)\s*:\s*([\w-]+)', re.IGNORECASE)
COLOUR_QUESTION = re.compile(r'what is my favou?rite colou?r', re.IGNORECASE)
COLOUR_FACT = re.compile(r'my favou?rite colou?r is (\w+)', re.IGNORECASE)
NOTES = re.compile(r'<notes>(.*?)</notes>', re.DOTALL)


TRANSCRIPT = 'A synthetic transcript from the fake model.'


def upload_summary(raw, content_type):
    """A multipart transcription upload's file size, its audio's length in
    seconds (WAV), and the language field, for the request log."""
    boundary = re.search(r'boundary="?([^";]+)', content_type or '')
    summary = {'bytes': len(raw), 'seconds': None, 'language': None}
    if not boundary:
        return summary
    for part in raw.split(b'--' + boundary.group(1).encode()):
        head, _, body = part.partition(b'\r\n\r\n')
        body = body[:-2] if body.endswith(b'\r\n') else body
        if b'name="language"' in head:
            summary['language'] = body.decode('utf-8', 'replace').strip()
        elif b'name="file"' in head:
            summary['bytes'] = len(body)
            try:
                with wave.open(io.BytesIO(body)) as w:
                    summary['seconds'] = round(w.getnframes() / float(w.getframerate()), 2)
            except (wave.Error, EOFError):
                # Open WebUI sends 16-bit PCM on as MP3.
                summary['seconds'] = mp3_seconds(body)
    return summary


def mp3_seconds(data):
    """An MP3's length in seconds, by counting its MPEG audio Layer III
    frames (None when it holds none)."""
    i = 0
    if data[:3] == b'ID3' and len(data) >= 10:
        i = 10 + ((data[6] & 0x7f) << 21 | (data[7] & 0x7f) << 14
                  | (data[8] & 0x7f) << 7 | (data[9] & 0x7f))
    v1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    v2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
    rates = {3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]}
    samples, rate = 0, None
    while i + 4 <= len(data):
        b1, b2 = data[i + 1], data[i + 2]
        version, layer = (b1 >> 3) & 3, (b1 >> 1) & 3
        bitrate, index, pad = b2 >> 4, (b2 >> 2) & 3, (b2 >> 1) & 1
        if (data[i] != 0xFF or (b1 & 0xE0) != 0xE0 or version == 1 or layer != 1
                or bitrate in (0, 15) or index == 3):
            i += 1
            continue
        rate = rates[version][index]
        per_frame = 1152 if version == 3 else 576
        kbps = (v1 if version == 3 else v2)[bitrate]
        samples += per_frame
        i += per_frame // 8 * kbps * 1000 // rate + pad
    return round(samples / rate, 2) if rate else None

ASK_USER = {
    'questions': [
        {'id': 'when', 'header': 'Departure', 'question': 'When should the boat leave?',
         'options': [{'label': 'Morning', 'description': 'Before the tide turns'},
                     {'label': 'Evening', 'description': 'After the wind drops'}]},
        {'id': 'crew', 'header': 'Crew', 'question': 'How many sail?',
         'options': [{'label': 'Two', 'description': 'A small crew'},
                     {'label': 'Four', 'description': 'A full crew'}],
         'allow_other': False},
    ],
}

TASKS = [
    {'id': '1', 'content': 'Read the tide table', 'status': 'completed'},
    {'id': '2', 'content': 'Check the harbour wind', 'status': 'in_progress'},
    {'id': '3', 'content': 'Pack the life jackets', 'status': 'pending'},
]

ALERTS = (
    'Before you sail, read these.\n\n'
    '> [!NOTE]\n> The tide tables here are synthetic.\n\n'
    '> [!TIP]\n> Leave **an hour** before high water.\n\n'
    '> [!IMPORTANT]\n> Tell someone your route.\n\n'
    '> [!WARNING]\n> The harbour wall is slippery.\n\n'
    '> [!CAUTION]\n> Do not sail after dark.\n\n'
    'Fair winds.'
)

# The MCP App: one tool with a `ui://` resource, its page, and the policy
# it declares (nothing to reach).
MCP_TOOL = {
    'name': 'show_tides',
    'description': 'Shows the synthetic tide board.',
    'inputSchema': {'type': 'object', 'properties': {'port': {'type': 'string'}}},
    '_meta': {'ui': {'resourceUri': 'ui://harbour/tides'}},
}
MCP_APP_HTML = '''<!doctype html><html><head><title>Tide board</title>
<style>body{font:14px -apple-system,sans-serif;margin:12px}h1{font-size:16px}</style></head>
<body><h1>Tide board</h1><p id="result">Waiting for the tide.</p>
<script>
const send = (m) => window.parent.postMessage(m, '*');
window.addEventListener('message', (e) => {
  const m = e.data || {};
  if (m.id === 1 && m.result) {
    send({jsonrpc: '2.0', method: 'ui/notifications/initialized', params: {}});
    send({jsonrpc: '2.0', method: 'ui/notifications/size-changed', params: {height: 180}});
  }
  if (m.method === 'ui/notifications/tool-result') {
    const text = ((m.params || {}).content || []).map((c) => c.text || '').join(' ');
    document.getElementById('result').textContent = text || 'No tide.';
  }
});
send({jsonrpc: '2.0', id: 1, method: 'ui/initialize',
      params: {protocolVersion: '2026-01-26', appInfo: {name: 'Tide board', version: '1'},
               appCapabilities: {}}});
</script></body></html>'''


def mcp_answer(request):
    """The MCP server's answer to one JSON-RPC request, or None for a
    notification."""
    method = request.get('method')
    rid = request.get('id')
    if rid is None:
        return None
    if method == 'initialize':
        result = {
            'protocolVersion': (request.get('params') or {}).get('protocolVersion', '2025-06-18'),
            'capabilities': {'tools': {}, 'resources': {}},
            'serverInfo': {'name': 'harbour', 'version': '1.0'},
        }
    elif method == 'tools/list':
        result = {'tools': [MCP_TOOL]}
    elif method == 'tools/call':
        result = {'content': [{'type': 'text', 'text': 'High water 06:12, low water 12:40.'}]}
    elif method == 'resources/list':
        result = {'resources': [{'uri': 'ui://harbour/tides', 'name': 'Tide board',
                                 'mimeType': 'text/html;profile=mcp-app'}]}
    elif method == 'resources/read':
        result = {'contents': [{
            'uri': 'ui://harbour/tides',
            'mimeType': 'text/html;profile=mcp-app',
            'text': MCP_APP_HTML,
            '_meta': {'ui': {'csp': {'connectDomains': [], 'resourceDomains': []}}},
        }]}
    elif method == 'ping':
        result = {}
    else:
        return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': -32601, 'message': 'Method not found'}}
    return {'jsonrpc': '2.0', 'id': rid, 'result': result}


def tool_result(messages, name):
    """The text a tool call named `name` came back with, if it did."""
    ids = {
        c.get('id')
        for m in messages for c in (m.get('tool_calls') or [])
        if (c.get('function') or {}).get('name') == name
    }
    for m in messages:
        if m.get('role') == 'tool' and m.get('tool_call_id') in ids:
            return text_of(m)
    return None


def fake_embedding(text, size=16):
    """A unit vector of [size] numbers from [text]'s bytes: deterministic, so
    the same memory always embeds the same."""
    values = [0.0] * size
    for i, byte in enumerate(text.encode('utf-8')):
        values[i % size] += (byte % 31) + 1
    norm = sum(v * v for v in values) ** 0.5 or 1.0
    return [v / norm for v in values]


# The personal tool server (OpenAPI) under /personal.
PERSONAL_OPENAPI = {
    'openapi': '3.1.0',
    'info': {
        'title': 'Buoy Readings',
        'version': '1.0.0',
        'description': 'Invented readings from the harbour buoys.',
    },
    'paths': {
        '/buoy': {
            'post': {
                'operationId': 'read_buoy',
                'summary': 'Read a harbour buoy',
                'description': 'The latest wave height and water temperature at a buoy.',
                'requestBody': {
                    'required': True,
                    'content': {'application/json': {'schema': {
                        'type': 'object',
                        'properties': {'station': {
                            'type': 'string', 'description': 'The buoy station, for example North Mole',
                        }},
                        'required': ['station'],
                    }}},
                },
                'responses': {'200': {'description': 'The reading'}},
            },
        },
    },
}
BUOY_READING = {'station': 'North Mole', 'wave_height_m': 0.8, 'water_temp_c': 14.5}


PAGE = (
    '<!doctype html><html><head><title>Raised Bed Basics</title></head><body>'
    '<article><h1>Raised Bed Basics</h1>'
    '<p>A raised bed drains faster than the ground around it, so it warms '
    'earlier in spring.</p>'
    '<p>Fill it with two parts compost to one part grit, and keep paths wide '
    'enough for a wheelbarrow.</p></article></body></html>'
)


def silence_wav(seconds=0.1):
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b'\0\0' * int(16000 * seconds))
    return out.getvalue()


def speech_seconds(raw):
    """How long the synthetic speech for a `/audio/speech` body lasts: about
    as long as a voice would take (60 ms a character), between a tenth of a
    second and six seconds, so a reading's sentences take time to play."""
    try:
        text = json.loads(raw or b'{}').get('input') or ''
    except ValueError:
        text = ''
    return min(6.0, max(0.1, len(text) * 0.06))


def text_of(message):
    content = message.get('content')
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return ' '.join(part.get('text', '') for part in content if isinstance(part, dict))
    return ''


def answer_for(text):
    """The reasoning (or None) and the answer for a plain prompt."""
    t = text.lower()
    reasoning = None
    if 'reason' in t:
        reasoning = (
            'The user wants a short reasoned answer. First, recall that a day on '
            'the synthetic planet lasts 30 hours. Then divide by three. '
        ) * 3
    if 'code' in t:
        body = (
            'Here is a function and two previews.\n\n'
            '```python\ndef orbit(period_hours: float) -> float:\n'
            '    """Degrees per hour."""\n    return 360 / period_hours\n```\n\n'
            '```html\n<!doctype html>\n<h1 style="font-family:sans-serif">Preview works</h1>\n'
            '<p>Rendered in a sandbox.</p>\n```\n\n'
            '```mermaid\ngraph TD\n  A[Question] --> B{Fake model}\n  B -->|code| C[Blocks]\n'
            '  B -->|math| D[Formulas]\n```\n'
        )
    elif 'diagram' in t:
        # Streamed slowly (see `do_POST`): the fence stays open for a
        # while, so a client can be seen to keep it as code until it ends.
        body = (
            'Here is the tide cycle as a diagram.\n\n'
            '```mermaid\ngraph LR\n  A[Low water] --> B[Flood tide]\n'
            '  B --> C[High water]\n  C --> D[Ebb tide]\n  D --> A\n```\n\n'
            'Each full cycle takes about twelve and a half hours.'
        )
    elif 'math' in t:
        body = (
            'The orbital speed is $v = \\sqrt{GM/r}$ for a circular orbit, and the '
            'period follows from\n\n$$T = 2\\pi\\sqrt{\\frac{r^3}{GM}}$$\n\n'
            'so doubling $r$ multiplies $T$ by $2\\sqrt{2}$.'
        )
    elif 'long' in t:
        parts = []
        n = 0
        while sum(len(p) for p in parts) < 32000:
            n += 1
            if n % 12 == 0:
                parts.append(f'\n\n## Section {n // 12}\n\n')
            parts.append(LONG_PARA.format(n=n))
            if n % 4 == 0:
                parts.append('\n\n')
        body = ''.join(parts)
    elif 'slow' in t:
        body = ' '.join(f'word{i}' for i in range(300))
    elif 'read aloud' in t:
        # Four sentences of 50+ characters, so Open WebUI's split keeps
        # each its own (read aloud's tests count them), one in bold.
        body = (
            'The harbour lights come on one by one as the evening settles in. '
            'A small wooden boat drifts slowly past the **green buoy** near the pier.'
            '\n\n'
            'Gulls settle on the old stone wall and wait quietly for the tide. '
            'By morning the fishing crews are loading their nets before sunrise.'
        )
    else:
        body = 'Hello from the fake model. Ask for code, math, reasoning or a long answer.'
    return reasoning, body


def direct_answer(text):
    """The reasoning (or None) and answer for a direct request's user text,
    as the chat completions route answers a plain prompt."""
    word = WORD.search(text)
    if word:
        return None, word.group(1)
    return answer_for(text)


def task_answer(text):
    """JSON for Open WebUI's background tasks, or None."""
    t = text.lower()
    if 'follow_ups' in t or 'follow-up' in t:
        return json.dumps(
            {'follow_ups': ['How long is a day there?', 'Show it as code', 'Explain the math']}
        )
    if '"title"' in t or ('title' in t and 'json' in t):
        return json.dumps({'title': 'Synthetic test chat'})
    if '"tags"' in t or ('tags' in t and 'json' in t):
        return json.dumps({'tags': ['Testing']})
    return None


def chunk(model, delta, finish=None):
    return {
        'id': 'chatcmpl-fake',
        'object': 'chat.completion.chunk',
        'created': int(time.time()),
        'model': model,
        'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}],
    }


def tool_call(name, args):
    return {
        'index': 0,
        'id': f'call_{int(time.time() * 1000)}',
        'type': 'function',
        'function': {'name': name, 'arguments': json.dumps(args)},
    }


def server_fields(tools, name, args, *, labels=None, approval=False):
    """[args] with the fields Open WebUI adds to `name`'s schema: the
    display labels, and whether the call needs approval (auto tool
    permissions ask for any call that does not say)."""
    spec = next((t for t in tools if (t.get('function') or {}).get('name') == name), {})
    props = ((spec.get('function') or {}).get('parameters') or {}).get('properties') or {}
    args = dict(args)
    if labels and '__labels__' in props:
        args['__labels__'] = labels
    if '__approval__' in props:
        args['__approval__'] = {'required': approval}
    return args


def called(messages, name):
    return any(
        (c.get('function') or {}).get('name') == name
        for m in messages for c in (m.get('tool_calls') or [])
    )


# ── The realtime voice ─────────────────────────────────────────────────

WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
REALTIME_HEARD = (
    'What is the weather like by the harbour',
    'Ask the chat for a short greeting',
)
REALTIME_SAYS = 'Calm water and a light breeze by the harbour this morning.'
REALTIME_RELAYS = 'Here is what the chat said: {answer}'
REALTIME_STATUS = 'One moment, the chat is working on it.'
# Loudness (RMS of 16-bit samples) above which the input is speech, and the
# quiet that ends an utterance.
SPEECH_RMS = 500
SPEECH_END_MS = 500


class WebSocket:
    """The server side of RFC 6455 on a handler's socket: text and binary
    frames, ping, close. Enough for the realtime voice."""

    def __init__(self, rfile, wfile):
        self.rfile = rfile
        self.wfile = wfile
        self.lock = threading.Lock()
        self.closed = False

    def _read(self, n):
        data = b''
        while len(data) < n:
            part = self.rfile.read(n - len(data))
            if not part:
                raise ConnectionError('closed')
            data += part
        return data

    def recv(self):
        """The next message as (is_text, payload), or None once closed."""
        message = b''
        opcode = None
        while True:
            head = self._read(2)
            fin = head[0] & 0x80
            op = head[0] & 0x0F
            masked = head[1] & 0x80
            length = head[1] & 0x7F
            if length == 126:
                length = struct.unpack('>H', self._read(2))[0]
            elif length == 127:
                length = struct.unpack('>Q', self._read(8))[0]
            mask = self._read(4) if masked else b'\0\0\0\0'
            payload = bytearray(self._read(length))
            for i in range(length):
                payload[i] ^= mask[i % 4]
            if op == 0x8:
                self.close()
                return None
            if op == 0x9:
                self._send(0xA, bytes(payload))
                continue
            if op == 0xA:
                continue
            if op != 0x0:
                opcode = op
            message += payload
            if fin:
                return (opcode == 0x1, bytes(message))

    def _send(self, op, data):
        head = bytes([0x80 | op])
        n = len(data)
        if n < 126:
            head += bytes([n])
        elif n < 65536:
            head += bytes([126]) + struct.pack('>H', n)
        else:
            head += bytes([127]) + struct.pack('>Q', n)
        with self.lock:
            if self.closed:
                return
            self.wfile.write(head + data)
            self.wfile.flush()

    def send_json(self, obj):
        self._send(0x1, json.dumps(obj).encode())

    def close(self):
        try:
            self._send(0x8, b'')
        except OSError:
            pass
        self.closed = True


def tone_pcm(seconds, frequency=440.0, amplitude=1200, rate=24000):
    """Quiet synthetic speech: a tone, as 16-bit mono PCM."""
    count = int(seconds * rate)
    return b''.join(
        struct.pack('<h', int(amplitude * math.sin(2 * math.pi * frequency * i / rate)))
        for i in range(count)
    )


def rms(pcm):
    count = len(pcm) // 2
    if count == 0:
        return 0
    samples = struct.unpack('<%dh' % count, pcm[:count * 2])
    return math.sqrt(sum(s * s for s in samples) / count)


class RealtimeSession:
    """One call's voice: hears utterances by loudness, answers or hands a
    request to the chat, and speaks as a tone with a caption."""

    def __init__(self, ws, log):
        self.ws = ws
        self.log = log
        self.speaking = None
        self.quiet_ms = 0
        self.heard_ms = 0
        self.utterances = 0
        self.items = 0
        self.transcripts = {}
        self.results = {}
        self.cancelled = set()

    def send(self, event):
        self.log({'realtime_sent': event.get('type')})
        self.ws.send_json(event)

    def next_id(self, prefix):
        self.items += 1
        return '%s_%d' % (prefix, self.items)

    def hear(self, pcm):
        ms = len(pcm) / 2 / 24000 * 1000
        loud = rms(pcm) > SPEECH_RMS
        if loud:
            self.quiet_ms = 0
            if self.speaking is None:
                self.speaking = self.next_id('item_in')
                self.heard_ms = 0
                self.send({'type': 'input_audio_buffer.speech_started',
                           'item_id': self.speaking, 'audio_start_ms': 0})
            self.heard_ms += ms
            return
        if self.speaking is None:
            return
        self.quiet_ms += ms
        if self.quiet_ms < SPEECH_END_MS:
            return
        item = self.speaking
        self.speaking = None
        self.send({'type': 'input_audio_buffer.speech_stopped', 'item_id': item,
                   'audio_end_ms': int(self.heard_ms)})
        text = REALTIME_HEARD[min(self.utterances, len(REALTIME_HEARD) - 1)]
        self.utterances += 1
        self.transcripts[item] = text
        self.send({'type': 'conversation.item.input_audio_transcription.completed',
                   'item_id': item, 'content_index': 0, 'transcript': text})

    def respond(self, response):
        metadata = response.get('metadata') or {}
        response_id = self.next_id('resp')
        self.send({'type': 'response.created',
                   'response': {'id': response_id, 'status': 'in_progress',
                                'metadata': metadata}})
        threading.Thread(target=self._respond, daemon=True,
                         args=(response_id, response, metadata)).start()

    def _respond(self, response_id, response, metadata):
        try:
            heard = self.transcripts.get(metadata.get('input_item_id'), '')
            if response.get('conversation') == 'none':
                self.speak(response_id, metadata, REALTIME_STATUS)
            elif 'call_id' in metadata:
                answer = self.results.get(metadata['call_id'], 'nothing')
                self.speak(response_id, metadata,
                           REALTIME_RELAYS.format(answer=answer.strip()[:200]))
            elif 'ask the chat' in heard.lower():
                item = self.next_id('item_call')
                call_id = self.next_id('call')
                arguments = json.dumps({'request': heard})
                self.send({'type': 'response.output_item.added', 'response_id': response_id,
                           'output_index': 0,
                           'item': {'id': item, 'type': 'function_call', 'status': 'in_progress',
                                    'name': 'generate_chat_completion', 'call_id': call_id}})
                self.send({'type': 'response.output_item.done', 'response_id': response_id,
                           'output_index': 0,
                           'item': {'id': item, 'type': 'function_call', 'status': 'completed',
                                    'name': 'generate_chat_completion', 'call_id': call_id,
                                    'arguments': arguments}})
                self.send({'type': 'response.done',
                           'response': {'id': response_id, 'status': 'completed',
                                        'metadata': metadata}})
            else:
                self.speak(response_id, metadata, REALTIME_SAYS)
        except (OSError, ConnectionError):
            pass

    def speak(self, response_id, metadata, text):
        item = self.next_id('item_out')
        self.send({'type': 'response.output_item.added', 'response_id': response_id,
                   'output_index': 0,
                   'item': {'id': item, 'type': 'message', 'status': 'in_progress',
                            'role': 'assistant'}})
        words = text.split(' ')
        audio = tone_pcm(0.08 * len(words) + 0.4)
        step = len(audio) // len(words) // 2 * 2
        caption = ''
        status = 'completed'
        for index, word in enumerate(words):
            if response_id in self.cancelled:
                status = 'cancelled'
                break
            chunk = audio[index * step:(index + 1) * step]
            self.send({'type': 'response.output_audio.delta', 'response_id': response_id,
                       'item_id': item, 'output_index': 0, 'content_index': 0,
                       'delta': base64.b64encode(chunk).decode()})
            delta = word if index == 0 else ' ' + word
            caption += delta
            self.send({'type': 'response.output_audio_transcript.delta',
                       'response_id': response_id, 'item_id': item, 'output_index': 0,
                       'content_index': 0, 'delta': delta})
            time.sleep(0.04)
        if status == 'completed':
            self.send({'type': 'response.output_audio_transcript.done',
                       'response_id': response_id, 'item_id': item, 'output_index': 0,
                       'content_index': 0, 'transcript': caption})
        self.send({'type': 'response.output_item.done', 'response_id': response_id,
                   'output_index': 0,
                   'item': {'id': item, 'type': 'message', 'status': status,
                            'role': 'assistant'}})
        self.send({'type': 'response.done',
                   'response': {'id': response_id, 'status': status, 'metadata': metadata}})

    def run(self):
        self.send({'type': 'session.created', 'session': {'id': 'sess_fake'}})
        while True:
            message = self.ws.recv()
            if message is None:
                return
            is_text, payload = message
            if not is_text:
                continue
            event = json.loads(payload)
            kind = event.get('type')
            if kind != 'input_audio_buffer.append':
                self.log({'realtime': kind})
            if kind == 'session.update':
                # A real voice takes a moment to set up (the call shows
                # Connecting… meanwhile, long enough to be shot).
                time.sleep(4)
                self.send({'type': 'session.updated', 'session': event.get('session') or {}})
            elif kind == 'input_audio_buffer.append':
                self.hear(base64.b64decode(event.get('audio') or ''))
            elif kind == 'response.create':
                self.respond(event.get('response') or {})
            elif kind == 'response.cancel':
                self.cancelled.add(event.get('response_id'))
            elif kind == 'conversation.item.create':
                item = event.get('item') or {}
                if item.get('type') == 'function_call_output':
                    try:
                        output = json.loads(item.get('output') or '{}')
                    except ValueError:
                        output = {}
                    self.results[item.get('call_id')] = output.get('answer', '')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    log_path = None

    def log_message(self, *args):
        pass

    def _json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _error(self, status, message):
        self._json(status, {'error': {'message': message, 'type': 'invalid_request_error'}})

    def do_DELETE(self):
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_HEAD(self):
        # As a real server answers HEAD on a POST-only route: the route is
        # there (the app's connection test with manual model ids asks).
        self.send_response(405)
        self.send_header('Allow', 'POST')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        if (self.path.split('?')[0].rstrip('/').endswith('/realtime')
                and self.headers.get('Upgrade', '').lower() == 'websocket'):
            self._realtime()
            return
        if fake_direct.handle_get(self):
            return
        if self.path.split('?')[0].rstrip('/').endswith('/mcp'):
            # No server-to-client stream.
            self.send_response(405)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.split('?')[0].rstrip('/').endswith('/personal/openapi.json'):
            self._json(200, PERSONAL_OPENAPI)
            return
        if self.path.rstrip('/').endswith('/page/raised-beds'):
            # A page for Open WebUI to read as a Web Page attachment.
            body = PAGE.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.rstrip('/').endswith('/models'):
            self._json(200, {'object': 'list', 'data': [
                {'id': MODEL, 'object': 'model', 'owned_by': 'fake'},
                {'id': SECOND_MODEL, 'object': 'model', 'owned_by': 'fake'},
                {'id': REFUSED_MODEL, 'object': 'model', 'owned_by': 'fake'},
            ]})
        else:
            self._json(404, {'error': 'not found'})

    def _scripted_transcript(self):
        """The next line of `<log>.transcripts`, which a test writes to say
        what the next transcriptions hear (a voice call's turns); None when
        there is none."""
        if not self.log_path:
            return None
        path = self.log_path + '.transcripts'
        try:
            with open(path) as f:
                lines = f.read().splitlines()
        except OSError:
            return None
        if not lines:
            return None
        with open(path, 'w') as f:
            f.write('\n'.join(lines[1:]) + ('\n' if len(lines) > 1 else ''))
        return lines[0].strip() or None

    def _realtime(self):
        key = self.headers.get('Sec-WebSocket-Key', '')
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, 'Switching Protocols')
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        self.wfile.flush()
        log_path = self.log_path

        def log(entry):
            if log_path:
                with open(log_path, 'a') as out:
                    out.write(json.dumps(entry) + '\n')

        log({'realtime': 'connect', 'path': self.path})
        try:
            RealtimeSession(WebSocket(self.rfile, self.wfile), log).run()
        except (OSError, ConnectionError, ValueError):
            pass
        self.close_connection = True

    def _body(self):
        # Open WebUI streams an audio upload with chunked encoding and no
        # Content-Length. Left unread, the chunks would be parsed as the
        # next request on this kept-alive connection, and the error page
        # for that lands right after the answer.
        if self.headers.get('Transfer-Encoding', '').lower() != 'chunked':
            return self.rfile.read(int(self.headers.get('Content-Length') or 0))
        body = b''
        while True:
            size = int(self.rfile.readline().split(b';', 1)[0].strip() or b'0', 16)
            if size == 0:
                # Any trailers, then the empty line that ends the body.
                while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                    pass
                return body
            body += self.rfile.read(size)
            self.rfile.readline()

    def do_POST(self):
        raw = self._body()
        path = self.path.split('?')[0].rstrip('/')
        if fake_direct.handle_post(self, raw, direct_answer):
            return
        if path.endswith('/audio/transcriptions'):
            summary = upload_summary(raw, self.headers.get('Content-Type', ''))
            if self.log_path:
                # What reached the server, so a dictation test can check
                # the whole recording and its language went out.
                with open(self.log_path, 'a') as log:
                    log.write(json.dumps({'transcription': summary}) + '\n')
            # A long recording takes a moment, as a real engine's does (the
            # desktop's Transcribing state is seen, and shot).
            if (summary.get('seconds') or 0) >= 6:
                time.sleep(4)
            self._json(200, {'text': self._scripted_transcript() or TRANSCRIPT})
            return
        if path.endswith('/audio/speech'):
            data = silence_wav(speech_seconds(raw))
            self.send_response(200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if path.endswith('/mcp'):
            try:
                request = json.loads(raw or b'{}')
            except ValueError:
                self._error(400, 'The body is not JSON.')
                return
            if isinstance(request, list):
                answer = [a for a in (mcp_answer(r) for r in request) if a is not None] or None
            else:
                answer = mcp_answer(request)
            if answer is None:
                # Notifications only.
                self.send_response(202)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            self._json(200, answer)
            return
        if path.endswith('/personal/buoy'):
            # The personal tool server's one operation: the client runs it
            # (Open WebUI asks the session that sent the chat to).
            try:
                args = json.loads(raw or b'{}')
            except ValueError:
                args = {}
            if self.log_path:
                with open(self.log_path, 'a') as log:
                    log.write(json.dumps({'personal_tool': 'read_buoy', 'args': args}) + '\n')
            reading = dict(BUOY_READING)
            if isinstance(args, dict) and args.get('station'):
                reading['station'] = str(args['station'])
            self._json(200, reading)
            return
        if '/webhook' in path:
            # A webhook delivery from Open WebUI (a destination's Test, or a
            # real event): logged for the test to find.
            try:
                body = json.loads(raw or b'{}')
            except ValueError:
                body = {'raw': raw.decode('utf-8', 'replace')}
            if self.log_path:
                with open(self.log_path, 'a') as log:
                    log.write(json.dumps({'webhook': path, 'body': body}) + '\n')
            self._json(200, {'ok': True})
            return
        if path.endswith('/embeddings'):
            # Memories need an embedding to be saved: a small vector made
            # from the text's bytes, the same for the same text.
            try:
                texts = json.loads(raw or b'{}').get('input') or []
            except ValueError:
                texts = []
            if isinstance(texts, str):
                texts = [texts]
            self._json(200, {'object': 'list', 'model': 'fake-embedding', 'data': [
                {'object': 'embedding', 'index': i, 'embedding': fake_embedding(str(text))}
                for i, text in enumerate(texts)
            ]})
            return
        if not path.endswith('/chat/completions'):
            self._json(404, {'error': 'not found'})
            return
        try:
            body = json.loads(raw or b'{}')
        except ValueError:
            self._error(400, 'The body is not JSON.')
            return
        messages = body.get('messages') or []
        tools = body.get('tools') or []
        tool_names = [((t.get('function') or {}).get('name')) for t in tools]
        stream = bool(body.get('stream'))
        if self.log_path:
            # The system text and the generation params too, so a test can
            # check what a chat's or a folder's settings sent.
            system = [text_of(m) for m in messages if m.get('role') == 'system']
            users = [text_of(m) for m in messages if m.get('role') == 'user']
            params = {k: body[k] for k in LOGGED_PARAMS if k in body}
            entry = {'model': body.get('model'), 'roles': [m.get('role') for m in messages],
                     'tools': tool_names, 'stream': stream, 'system': system,
                     'user': users[-1] if users else '', 'params': params}
            # How it was sent: custom headers, the key's header, api-version.
            entry.update(fake_direct.request_facts(self))
            with open(self.log_path, 'a') as log:
                log.write(json.dumps(entry) + '\n')

        model = str(body.get('model') or MODEL)
        if model.endswith(REFUSED_MODEL):
            self._error(400, REFUSAL)
            return

        users = [m for m in messages if m.get('role') == 'user']
        last_user = users[-1] if users else {}
        user_text = text_of(last_user)
        lower = user_text.lower()
        after_user = messages[messages.index(last_user) + 1:] if last_user else []
        clock_answered = called(after_user, 'get_current_timestamp')
        fetch_answered = called(after_user, 'web_fetch')
        asked = tool_result(after_user, 'ask_user')
        planned = called(after_user, 'create_tasks')
        ferry = fake_direct.ferry_tool(tool_names)
        ferried = tool_result(after_user, ferry) if ferry else None
        displayed = called(after_user, 'display_file')
        buoy = tool_result(after_user, 'read_buoy')

        reasoning = None
        call = None
        task = None if stream else task_answer(user_text)
        notes = NOTES.search(user_text)
        word = WORD.search(user_text)
        if task is not None:
            text = task
        elif MERGE_PROMPT.search(user_text):
            text = MERGED
        elif 'effort' in lower and body.get('reasoning_effort') is not None:
            self._error(400, EFFORT_REFUSAL)
            return
        elif notes:
            items = [i.strip() for i in re.split(r'[;\n]', notes.group(1)) if i.strip()]
            text = '# Notes\n\n' + '\n'.join(f'- [ ] {i}' for i in items)
        elif asked is not None:
            try:
                answers = json.loads(asked).get('answers') or {}
            except (ValueError, AttributeError):
                answers = {}
            chosen = [
                (answers.get(q['id']) or {}).get('label') or (answers.get(q['id']) or {}).get('text')
                for q in ASK_USER['questions']
            ]
            chosen = [c for c in chosen if c]
            text = f"You chose {' and '.join(chosen)}." if chosen else 'You did not answer.'
        elif ferried is not None:
            text = f'The ferry tool says: {ferried}'
        elif buoy is not None:
            try:
                reading = json.loads(buoy)
                if isinstance(reading, list):
                    reading = reading[0]
                text = (f"The {reading['station']} buoy reads {reading['wave_height_m']} m waves "
                        f"and {reading['water_temp_c']} degrees water.")
            except (ValueError, KeyError, TypeError, IndexError):
                text = f'The buoy tool says: {buoy}'
        elif planned:
            text = 'The plan is ready: one task done, one under way.'
        elif displayed:
            text = 'The notes are open beside the chat.'
        elif fetch_answered:
            text = 'The page was not fetched, as expected: it was not in your message.'
        elif clock_answered:
            text = 'It is time for a test. The clock said so.'
        elif word:
            text = word.group(1)
        elif COLOUR_QUESTION.search(user_text):
            facts = [COLOUR_FACT.search(text_of(m)) for m in users[:-1]]
            facts = [f.group(1) for f in facts if f]
            text = facts[-1] if facts else 'You have not told me.'
        elif 'buoy' in lower and 'read_buoy' in tool_names:
            call = tool_call('read_buoy', server_fields(tools, 'read_buoy', {'station': 'North Mole'}))
            text = ''
        elif 'ferry' in lower and ferry:
            call = tool_call(ferry, {'harbour': 'North'})
            text = ''
        elif 'ask me' in lower and 'ask_user' in tool_names:
            call = tool_call('ask_user', ASK_USER)
            text = ''
        elif 'plan the tasks' in lower and 'create_tasks' in tool_names:
            call = tool_call('create_tasks', server_fields(tools, 'create_tasks', {'tasks': TASKS}))
            text = ''
        elif 'tide table' in lower and 'display_file' in tool_names:
            call = tool_call('display_file', server_fields(
                tools, 'display_file', {'path': '/home/demo/tides.pdf', 'page': 2}))
            text = ''
        elif 'display' in lower and 'display_file' in tool_names:
            call = tool_call('display_file', server_fields(
                tools, 'display_file', {'path': '/home/demo/notes.txt'}))
            text = ''
        elif 'alerts' in lower:
            text = ALERTS
        elif 'fail' in lower:
            self._error(500, 'The fake model failed on purpose.')
            return
        elif 'refuse' in lower:
            self._error(400, 'The fake model refused on purpose.')
            return
        elif 'time' in lower and 'get_current_timestamp' in tool_names:
            args = server_fields(
                tools, 'get_current_timestamp', {},
                labels={'running': 'Checking the clock', 'completed': 'Checked the clock'},
                approval='approve' in lower,
            )
            call = tool_call('get_current_timestamp', args)
            text = ''
        elif 'tool' in lower and 'web_fetch' in tool_names:
            # Direct mode's web_fetch refuses URLs that were not in the
            # user's message, so this makes no request.
            call = tool_call('web_fetch', {'url': 'https://example.org/not-in-the-message'})
            text = ''
        else:
            reasoning, text = answer_for(user_text)
        # The second model's answers say whose they are (not its background
        # task answers, which Open WebUI reads as JSON).
        if model.endswith(SECOND_MODEL) and text and task is None:
            text = 'B: ' + text

        if not stream:
            message = {'role': 'assistant', 'content': text or None}
            if call:
                message['tool_calls'] = [{k: v for k, v in call.items() if k != 'index'}]
            self._json(200, {
                'id': 'chatcmpl-fake', 'object': 'chat.completion', 'created': int(time.time()),
                'model': model,
                'choices': [{'index': 0, 'message': message,
                             'finish_reason': 'tool_calls' if call else 'stop'}],
                'usage': {'prompt_tokens': 10, 'completion_tokens': 5, 'total_tokens': 15},
            })
            return

        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()

        def send(obj):
            self.wfile.write(f'data: {json.dumps(obj)}\n\n'.encode())
            self.wfile.flush()

        try:
            send(chunk(model, {'role': 'assistant', 'content': ''}))
            if call:
                send(chunk(model, {'tool_calls': [call]}))
                send(chunk(model, {}, 'tool_calls'))
            else:
                if reasoning:
                    for piece in reasoning.split(' '):
                        send(chunk(model, {'reasoning_content': piece + ' '}))
                        time.sleep(0.03)
                if len(text) > 5000:
                    for i in range(0, len(text), 120):
                        send(chunk(model, {'content': text[i:i + 120]}))
                        time.sleep(0.016)
                else:
                    slow = 'slow' in lower
                    diagram = 'diagram' in lower
                    pieces = text.split(' ')
                    for i, piece in enumerate(pieces):
                        send(chunk(model, {'content': piece + (' ' if i < len(pieces) - 1 else '')}))
                        time.sleep(0.2 if slow else 0.4 if diagram else 0.03)
                send(chunk(model, {}, 'stop'))
            # As OpenAI's `include_usage` sends it: no choices, the counts,
            # and Groq-style timings for the rates.
            words = max(1, len(text.split()))
            send({
                'id': 'chatcmpl-fake', 'object': 'chat.completion.chunk', 'created': int(time.time()),
                'model': model, 'choices': [],
                'usage': {'prompt_tokens': 12, 'completion_tokens': words, 'total_tokens': 12 + words,
                          'prompt_time': 0.02, 'completion_time': round(words * 0.03, 3),
                          'total_time': round(0.02 + words * 0.03, 3)},
            })
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--log', help='append one JSON line per request here')
    args = parser.parse_args()
    Handler.log_path = args.log
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
