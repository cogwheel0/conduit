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
  - "ask me": a call to Open WebUI's `ask_user` with two questions, then,
    answered, "You chose X and Y.";
  - "plan the tasks": a call to `create_tasks` with three tasks, then a
    short answer;
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
`/audio/transcriptions` answers with a fixed sentence and `/audio/speech`
with a tenth of a second of silence (WAV), for the server's speech
features. `/mcp` is a small MCP server (streamable HTTP, JSON answers)
with one MCP App, `show_tides`, whose page shows the tool's result, for
Open WebUI's MCP Apps. Every answer is invented. The log gets each request's roles, tool names,
whether it streamed, its system text, its last user text and its generation
params (temperature, seed, reasoning effort, ...): what a test needs to check
that a chat's or a folder's settings reached the model. The text is the seed's
or a test's own, all synthetic.
"""

import argparse
import io
import json
import re
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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


PAGE = (
    '<!doctype html><html><head><title>Raised Bed Basics</title></head><body>'
    '<article><h1>Raised Bed Basics</h1>'
    '<p>A raised bed drains faster than the ground around it, so it warms '
    'earlier in spring.</p>'
    '<p>Fill it with two parts compost to one part grit, and keep paths wide '
    'enough for a wheelbarrow.</p></article></body></html>'
)


def silence_wav():
    out = io.BytesIO()
    with wave.open(out, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b'\0\0' * 1600)
    return out.getvalue()


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
    else:
        body = 'Hello from the fake model. Ask for code, math, reasoning or a long answer.'
    return reasoning, body


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

    def do_GET(self):
        if self.path.split('?')[0].rstrip('/').endswith('/mcp'):
            # No server-to-client stream.
            self.send_response(405)
            self.send_header('Content-Length', '0')
            self.end_headers()
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
        if path.endswith('/audio/transcriptions'):
            self._json(200, {'text': TRANSCRIPT})
            return
        if path.endswith('/audio/speech'):
            data = silence_wav()
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
            with open(self.log_path, 'a') as log:
                log.write(json.dumps({'model': body.get('model'), 'roles': [m.get('role') for m in messages],
                                      'tools': tool_names, 'stream': stream, 'system': system,
                                      'user': users[-1] if users else '', 'params': params}) + '\n')

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
        elif planned:
            text = 'The plan is ready: one task done, one under way.'
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
        elif 'ask me' in lower and 'ask_user' in tool_names:
            call = tool_call('ask_user', ASK_USER)
            text = ''
        elif 'plan the tasks' in lower and 'create_tasks' in tool_names:
            call = tool_call('create_tasks', server_fields(tools, 'create_tasks', {'tasks': TASKS}))
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
                    pieces = text.split(' ')
                    for i, piece in enumerate(pieces):
                        send(chunk(model, {'content': piece + (' ' if i < len(pieces) - 1 else '')}))
                        time.sleep(0.2 if slow else 0.03)
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
