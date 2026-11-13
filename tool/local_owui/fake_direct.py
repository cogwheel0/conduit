"""The fake model server's direct-connection extras, for the desktop
app's advanced Direct pass. `fake_model.py` routes to these:

- `/ollama/api/...`: a local Ollama server (base URL
  `http://127.0.0.1:<port>/ollama`) with two models, `llama3.2:1b` and
  `qwen3:4b`. `api/chat` with no messages loads a model (or unloads it with
  `keep_alive: 0`); with messages it answers as the fake model does, as
  NDJSON. `api/ps` lists what is loaded.
- `/v1/responses`: OpenAI's Responses API, streamed, answering as the fake
  model does.
- `/oauth-mcp`: an MCP server (stateless Streamable HTTP, JSON answers)
  that takes only a token from this server's own OAuth authorization
  server at `/auth` (discovery, dynamic client registration, PKCE). Its
  one tool, `ferry_times`, says when the next ferry leaves; it also offers
  a prompt (`ferry_notice`) and a text resource (`timetable://north`). The
  authorization endpoint approves at once and redirects to the app's
  loopback address, as a browser would after the user agreed.

Every request a test checks is logged with the custom `x-` headers it
carried, how the key was sent and any `api-version`, so a pass can tell
that a connection's settings reached the provider. All synthetic.
"""

import base64
import hashlib
import json
import re
import secrets
import threading
import time
import urllib.parse

OLLAMA_PREFIX = '/ollama'
OLLAMA_MODELS = ['llama3.2:1b', 'qwen3:4b']
FERRY_TOOL = 'ferry_times'
FERRY_ANSWER = 'The next ferry leaves the north harbour at 14:20 (a synthetic timetable).'
SCOPE = 'tides.read'
PROMPT_TEXT = 'Post the ferry timetable on the harbour board.'
RESOURCE_URI = 'timetable://north'
RESOURCE_TEXT = 'Ferries leave the north harbour at 09:10, 14:20 and 18:45.'
MCP_VERSION = '2026-07-28'

_lock = threading.Lock()
_running = set()
_clients = {}
_codes = {}
_tokens = set()
_refresh = set()


def request_facts(handler):
    """What a test checks about how a request was sent: its custom `x-`
    headers (names lower-cased, with values; all synthetic), how the key
    came (`bearer`, `api-key` or None) and the `api-version` query."""
    custom = {k.lower(): v for k, v in handler.headers.items() if k.lower().startswith('x-')}
    if handler.headers.get('api-key'):
        auth = 'api-key'
    elif (handler.headers.get('Authorization') or '').lower().startswith('bearer '):
        auth = 'bearer'
    else:
        auth = None
    query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(handler.path).query))
    return {'path': urllib.parse.urlsplit(handler.path).path, 'headers': custom,
            'auth': auth, 'api_version': query.get('api-version')}


def _log(handler, entry):
    if handler.log_path:
        with open(handler.log_path, 'a') as log:
            log.write(json.dumps(entry) + '\n')


def _origin(handler):
    return f'http://127.0.0.1:{handler.server.server_address[1]}'


def _issuer(handler):
    return _origin(handler) + '/auth'


def _resource(handler):
    return _origin(handler) + '/oauth-mcp'


def _send_json(handler, status, body, headers=None):
    data = json.dumps(body).encode()
    handler.send_response(status)
    handler.send_header('Content-Type', 'application/json')
    handler.send_header('Content-Length', str(len(data)))
    for k, v in (headers or {}).items():
        handler.send_header(k, v)
    handler.end_headers()
    handler.wfile.write(data)


def _send_empty(handler, status, headers=None):
    handler.send_response(status)
    handler.send_header('Content-Length', '0')
    for k, v in (headers or {}).items():
        handler.send_header(k, v)
    handler.end_headers()


# ---------------------------------------------------------------- GET

def handle_get(handler):
    """True when the request was one of these."""
    path = urllib.parse.urlsplit(handler.path).path.rstrip('/')
    if path == OLLAMA_PREFIX + '/api/tags':
        _send_json(handler, 200, {'models': [
            {'name': m, 'model': m, 'size': 1300000000, 'modified_at': '2026-11-01T09:00:00Z',
             'details': {'family': m.split(':')[0], 'families': [m.split(':')[0]]}}
            for m in OLLAMA_MODELS
        ]})
        return True
    if path == OLLAMA_PREFIX + '/api/ps':
        with _lock:
            running = sorted(_running)
        _send_json(handler, 200, {'models': [
            {'name': m, 'model': m, 'size': 1300000000, 'size_vram': 1300000000,
             'context_length': 4096, 'expires_at': '2026-11-11T12:00:00Z'}
            for m in running
        ]})
        return True
    if path == OLLAMA_PREFIX + '/api/version':
        _send_json(handler, 200, {'version': '0.12.0'})
        return True
    if path == '/.well-known/oauth-protected-resource/oauth-mcp':
        _send_json(handler, 200, {
            'resource': _resource(handler),
            'authorization_servers': [_issuer(handler)],
            'scopes_supported': [SCOPE],
            'bearer_methods_supported': ['header'],
        })
        return True
    if path == '/.well-known/oauth-authorization-server/auth':
        issuer = _issuer(handler)
        _send_json(handler, 200, {
            'issuer': issuer,
            'authorization_endpoint': issuer + '/authorize',
            'token_endpoint': issuer + '/token',
            'registration_endpoint': issuer + '/register',
            'response_types_supported': ['code'],
            'grant_types_supported': ['authorization_code', 'refresh_token'],
            'code_challenge_methods_supported': ['S256'],
            'token_endpoint_auth_methods_supported': ['none'],
            'scopes_supported': [SCOPE],
        })
        return True
    if path == '/auth/authorize':
        _authorize(handler)
        return True
    if path in ('/oauth-mcp',):
        _send_empty(handler, 405)
        return True
    return False


def _authorize(handler):
    """Approves at once: the user said yes in the browser."""
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(handler.path).query))
    client = _clients.get(q.get('client_id'))
    redirect = q.get('redirect_uri') or ''
    ok = (client is not None and redirect in client['redirect_uris']
          and q.get('response_type') == 'code' and q.get('code_challenge_method') == 'S256'
          and q.get('code_challenge') and q.get('state') and q.get('resource') == _resource(handler))
    _log(handler, {'oauth': 'authorize', 'ok': bool(ok), 'scope': q.get('scope')})
    if not ok:
        _send_json(handler, 400, {'error': 'invalid_request'})
        return
    code = secrets.token_urlsafe(16)
    with _lock:
        _codes[code] = {'client_id': q['client_id'], 'challenge': q['code_challenge'],
                        'redirect_uri': redirect, 'resource': q['resource']}
    location = redirect + '?' + urllib.parse.urlencode({'code': code, 'state': q['state']})
    _send_empty(handler, 302, {'Location': location})


# ---------------------------------------------------------------- POST

def handle_post(handler, raw, answer):
    """True when the request was one of these. [answer] gives the fake
    model's (reasoning, text) for a user's text."""
    path = urllib.parse.urlsplit(handler.path).path.rstrip('/')
    if path.startswith(OLLAMA_PREFIX + '/api/'):
        _ollama(handler, path[len(OLLAMA_PREFIX):], raw, answer)
        return True
    if path.endswith('/responses'):
        _responses(handler, raw, answer)
        return True
    if path == '/auth/register':
        _register(handler, raw)
        return True
    if path == '/auth/token':
        _token(handler, raw)
        return True
    if path == '/oauth-mcp':
        _oauth_mcp(handler, raw)
        return True
    return False


def _body(raw):
    try:
        return json.loads(raw or b'{}')
    except ValueError:
        return {}


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return ' '.join(p.get('text', '') for p in content if isinstance(p, dict))
    return ''


def _ollama(handler, path, raw, answer):
    body = _body(raw)
    model = str(body.get('model') or '')
    if path == '/api/show':
        _send_json(handler, 200, {'capabilities': ['completion', 'tools'],
                                  'details': {'family': model.split(':')[0]}})
        return
    if path != '/api/chat':
        _send_json(handler, 404, {'error': 'not found'})
        return
    messages = body.get('messages') or []
    options = body.get('options') or {}
    keep_alive = body.get('keep_alive')
    if not messages:
        unload = keep_alive == 0 or keep_alive == '0'
        with _lock:
            (_running.discard if unload else _running.add)(model)
        _log(handler, {'ollama': 'unload' if unload else 'load', 'model': model,
                       'keep_alive': keep_alive, 'num_ctx': options.get('num_ctx')})
        _send_json(handler, 200, {'model': model, 'created_at': '2026-11-11T09:00:00Z',
                                  'message': {'role': 'assistant', 'content': ''},
                                  'done_reason': 'unload' if unload else 'load', 'done': True})
        return
    users = [m for m in messages if m.get('role') == 'user']
    user_text = _text(users[-1].get('content')) if users else ''
    tools = [((t.get('function') or {}).get('name')) for t in body.get('tools') or []]
    entry = request_facts(handler)
    entry.update({'model': model, 'roles': [m.get('role') for m in messages], 'tools': tools,
                  'stream': bool(body.get('stream', True)), 'user': user_text,
                  'keep_alive': keep_alive, 'num_ctx': options.get('num_ctx'),
                  'think': body.get('think')})
    _log(handler, entry)
    with _lock:
        _running.add(model)
    _, text = answer(user_text)
    handler.send_response(200)
    handler.send_header('Content-Type', 'application/x-ndjson')
    handler.send_header('Connection', 'close')
    handler.end_headers()
    try:
        words = text.split(' ')
        for i, word in enumerate(words):
            line = {'model': model, 'created_at': '2026-11-11T09:00:00Z',
                    'message': {'role': 'assistant',
                                'content': word + (' ' if i < len(words) - 1 else '')},
                    'done': False}
            handler.wfile.write((json.dumps(line) + '\n').encode())
            handler.wfile.flush()
            time.sleep(0.02)
        handler.wfile.write((json.dumps({
            'model': model, 'created_at': '2026-11-11T09:00:01Z',
            'message': {'role': 'assistant', 'content': ''}, 'done': True, 'done_reason': 'stop',
            'total_duration': 400000000, 'load_duration': 1000000,
            'prompt_eval_count': 12, 'eval_count': max(1, len(words)),
        }) + '\n').encode())
        handler.wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        pass
    handler.close_connection = True


def _responses(handler, raw, answer):
    body = _body(raw)
    items = [i for i in body.get('input') or [] if isinstance(i, dict)]
    users = [i for i in items if i.get('role') == 'user']
    user_text = _text(users[-1].get('content')) if users else ''
    model = str(body.get('model') or 'fake-model')
    entry = request_facts(handler)
    entry.update({'model': model, 'roles': [i.get('role') for i in items],
                  'tools': [t.get('name') for t in body.get('tools') or []],
                  'stream': bool(body.get('stream')), 'user': user_text, 'api': 'responses'})
    _log(handler, entry)
    _, text = answer(user_text)
    created = int(time.time())
    usage = {'input_tokens': 12, 'output_tokens': max(1, len(text.split())),
             'total_tokens': 12 + max(1, len(text.split()))}
    if not body.get('stream'):
        _send_json(handler, 200, {
            'id': 'resp_fake', 'object': 'response', 'created_at': created, 'status': 'completed',
            'model': model,
            'output': [{'type': 'message', 'id': 'msg_fake', 'role': 'assistant', 'status': 'completed',
                        'content': [{'type': 'output_text', 'text': text, 'annotations': []}]}],
            'usage': usage,
        })
        return
    handler.send_response(200)
    handler.send_header('Content-Type', 'text/event-stream')
    handler.send_header('Cache-Control', 'no-cache')
    handler.send_header('Connection', 'close')
    handler.end_headers()

    def send(obj):
        handler.wfile.write(f"event: {obj['type']}\ndata: {json.dumps(obj)}\n\n".encode())
        handler.wfile.flush()

    try:
        words = text.split(' ')
        for i, word in enumerate(words):
            send({'type': 'response.output_text.delta', 'item_id': 'msg_fake', 'output_index': 0,
                  'content_index': 0, 'delta': word + (' ' if i < len(words) - 1 else '')})
            time.sleep(0.02)
        send({'type': 'response.completed', 'response': {
            'id': 'resp_fake', 'object': 'response', 'created_at': created, 'status': 'completed',
            'model': model, 'output': [], 'usage': usage}})
    except (BrokenPipeError, ConnectionResetError):
        pass
    handler.close_connection = True


def _register(handler, raw):
    body = _body(raw)
    redirects = [u for u in body.get('redirect_uris') or [] if isinstance(u, str)]
    if not redirects or body.get('token_endpoint_auth_method') != 'none':
        _send_json(handler, 400, {'error': 'invalid_client_metadata'})
        return
    client_id = 'fake-client-' + secrets.token_hex(4)
    with _lock:
        _clients[client_id] = {'redirect_uris': redirects}
    _log(handler, {'oauth': 'register', 'client_name': body.get('client_name')})
    _send_json(handler, 201, {
        'client_id': client_id, 'client_name': body.get('client_name'),
        'redirect_uris': redirects, 'token_endpoint_auth_method': 'none',
        'grant_types': ['authorization_code', 'refresh_token'], 'response_types': ['code'],
    })


def _token(handler, raw):
    form = dict(urllib.parse.parse_qsl(raw.decode('utf-8', 'replace')))
    grant = form.get('grant_type')
    ok = False
    if grant == 'authorization_code':
        with _lock:
            issued = _codes.pop(form.get('code') or '', None)
        if issued is not None:
            digest = hashlib.sha256((form.get('code_verifier') or '').encode()).digest()
            challenge = base64.urlsafe_b64encode(digest).rstrip(b'=').decode()
            ok = (challenge == issued['challenge'] and form.get('client_id') == issued['client_id']
                  and form.get('redirect_uri') == issued['redirect_uri']
                  and form.get('resource') == issued['resource'])
    elif grant == 'refresh_token':
        with _lock:
            ok = form.get('refresh_token') in _refresh
    _log(handler, {'oauth': 'token', 'grant_type': grant, 'ok': ok})
    if not ok:
        _send_json(handler, 400, {'error': 'invalid_grant'})
        return
    access = 'fake-mcp-' + secrets.token_urlsafe(16)
    refresh = 'fake-refresh-' + secrets.token_urlsafe(16)
    with _lock:
        _tokens.add(access)
        _refresh.add(refresh)
    _send_json(handler, 200, {'access_token': access, 'token_type': 'Bearer', 'expires_in': 3600,
                              'refresh_token': refresh, 'scope': SCOPE})


def _mcp_result(method, params):
    if method == 'server/discover':
        return {'resultType': 'complete', 'supportedVersions': [MCP_VERSION],
                'capabilities': {'tools': {'listChanged': False},
                                 'prompts': {'listChanged': False},
                                 'resources': {'listChanged': False, 'subscribe': False}},
                'ttlMs': 0, 'cacheScope': 'private',
                '_meta': {'io.modelcontextprotocol/serverInfo': {'name': 'ferry', 'version': '1.0.0'}}}
    if method == 'tools/list':
        return {'tools': [{
            'name': FERRY_TOOL,
            'description': 'The next ferry departures from a harbour (synthetic).',
            'inputSchema': {'type': 'object', 'properties': {'harbour': {'type': 'string'}}},
        }], 'resultType': 'complete', 'ttlMs': 0, 'cacheScope': 'private'}
    if method == 'tools/call':
        return {'content': [{'type': 'text', 'text': FERRY_ANSWER}], 'isError': False,
                'resultType': 'complete'}
    cached = {'resultType': 'complete', 'ttlMs': 0, 'cacheScope': 'private'}
    if method == 'prompts/list':
        return {'prompts': [{'name': 'ferry_notice', 'title': 'Ferry notice',
                             'description': 'A notice for the harbour board.', 'arguments': []}],
                **cached}
    if method == 'prompts/get':
        return {'description': 'A notice for the harbour board.', 'resultType': 'complete',
                'messages': [{'role': 'user', 'content': {'type': 'text', 'text': PROMPT_TEXT}}]}
    if method == 'resources/list':
        return {'resources': [{'uri': RESOURCE_URI, 'name': 'North harbour timetable',
                               'mimeType': 'text/plain'}], **cached}
    if method == 'resources/templates/list':
        return {'resourceTemplates': [], **cached}
    if method == 'resources/read':
        return {'contents': [{'uri': RESOURCE_URI, 'mimeType': 'text/plain',
                              'text': RESOURCE_TEXT}], **cached}
    return None


def _oauth_mcp(handler, raw):
    token = (handler.headers.get('Authorization') or '')[len('Bearer '):]
    with _lock:
        authorized = token in _tokens
    if not authorized:
        # An empty body: a JSON-RPC body would read as an error, not a 401.
        meta = _origin(handler) + '/.well-known/oauth-protected-resource/oauth-mcp'
        _send_empty(handler, 401, {
            'WWW-Authenticate': f'Bearer resource_metadata="{meta}", scope="{SCOPE}"'})
        return
    request = _body(raw)
    rid = request.get('id') if isinstance(request, dict) else None
    method = request.get('method') if isinstance(request, dict) else None
    if rid is None:
        _send_empty(handler, 202)
        return
    params = request.get('params') or {}
    if method == 'tools/call':
        _log(handler, {'mcp_call': params.get('name'), 'arguments': params.get('arguments'),
                       'authorized': True})
    result = _mcp_result(method, params)
    if result is None:
        _send_json(handler, 200, {'jsonrpc': '2.0', 'id': rid,
                                  'error': {'code': -32601, 'message': 'Method not found'}})
        return
    _send_json(handler, 200, {'jsonrpc': '2.0', 'id': rid, 'result': result})


# ------------------------------------------------- the chat model's turn

FERRY_CALL = re.compile(r'^mcp_[0-9a-f]{8}_' + FERRY_TOOL + r'$')


def ferry_tool(tool_names):
    """The model-facing name of the ferry tool, when the request offers it."""
    return next((n for n in tool_names if n and FERRY_CALL.match(n)), None)
