"""The capture harness's showcase chat, on top of tool/local_owui's seed.

Usage (hc-capture.sh runs it, with the Open WebUI venv's Python, which has
Pillow):
  python -I seed_showcase.py --env-file local-owui.env --data DATA_DIR --out capture.env

One stored chat whose answers hold every block the desktop app draws: a
file the question carries, a status timeline (a web search), reasoning,
two tool calls side by side, headings, a list, inline and display math,
code with highlighting, a code-interpreter section, a table, citations
with their sources, a code execution with its output, a generated image,
an answer that failed with an error, and suggested follow-ups. It is
stored the way Open WebUI stores such answers, so the daemon and the app
read it like any other chat.

Writes OWUI_SHOWCASE_CHAT (and the image's file id) to --out. Every text,
name, address and number is invented. Prints only ids.
"""

import argparse
import io
import json
import os
import sqlite3
import time
import urllib.request
import uuid

MODEL = 'fake-model'
MODEL_NAME = 'Kestrel 8B'


def read_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def call(base, method, path, body=None, token=None):
    req = urllib.request.Request(base + path, method=method)
    req.add_header('Content-Type', 'application/json')
    req.add_header('User-Agent', 'conduit-hc-seed')
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(req, data, timeout=60) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def upload(base, token, name, data, content_type):
    boundary = uuid.uuid4().hex
    payload = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
        f'Content-Type: {content_type}\r\n\r\n'
    ).encode() + data + f'\r\n--{boundary}--\r\n'.encode()
    req = urllib.request.Request(base + '/api/v1/files/', data=payload, method='POST')
    req.add_header('Content-Type', f'multipart/form-data; boundary={boundary}')
    req.add_header('Authorization', f'Bearer {token}')
    req.add_header('User-Agent', 'conduit-hc-seed')
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read())


def chart_png():
    """A plain synthetic chart: a week of high-water heights."""
    from PIL import Image, ImageDraw, ImageFont

    w, h = 960, 480
    img = Image.new('RGB', (w, h), (250, 250, 248))
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 22)
        small = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', 18)
    except OSError:
        font = small = ImageFont.load_default()
    d.text((48, 28), 'High water at Port Wren (synthetic)', fill=(30, 30, 32), font=font)
    left, top, right, bottom = 80, 90, w - 40, h - 70
    d.line((left, bottom, right, bottom), fill=(120, 120, 124), width=2)
    d.line((left, top, left, bottom), fill=(120, 120, 124), width=2)
    days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
    heights = [4.1, 4.0, 3.8, 3.7, 3.9, 4.2, 4.4]
    step = (right - left) / len(days)
    for i, (day, height) in enumerate(zip(days, heights)):
        x0 = left + i * step + step * 0.22
        x1 = left + (i + 1) * step - step * 0.22
        y0 = bottom - (height - 3.0) / 1.6 * (bottom - top)
        d.rounded_rectangle((x0, y0, x1, bottom - 1), radius=6, fill=(70, 70, 76))
        d.text((x0 + 4, bottom + 14), day, fill=(90, 90, 96), font=small)
        d.text((x0 - 2, y0 - 26), f'{height:.1f} m', fill=(60, 60, 66), font=small)
    out = io.BytesIO()
    img.save(out, format='PNG')
    return out.getvalue()


def message(mid, parent, children, role, content, at, **extra):
    m = {'id': mid, 'parentId': parent, 'childrenIds': children, 'role': role,
         'content': content, 'timestamp': at}
    if role == 'user':
        m['models'] = [MODEL]
    else:
        m.update({'model': MODEL, 'modelName': MODEL, 'done': True})
    m.update(extra)
    return m


REASONING = (
    '<details type="reasoning" done="true" duration="6">\n'
    '<summary>Thought for 6 seconds</summary>\n'
    '&gt; The notes cover two days at the creek station.\n'
    '&gt; Take the high-water times from the tide table, then chart the heights.\n'
    '&gt; The daily lag is the average of the differences.\n'
    '</details>\n'
)

TOOLS = (
    '<details type="tool_calls" done="true" id="call_t1" name="tide_table" '
    'arguments="{&quot;station&quot;:&quot;Port Wren&quot;,&quot;days&quot;:7}" '
    'result="&quot;High water 06:12, 06:58, 07:41, 08:22, 09:03, 09:44, 10:27&quot;">\n'
    '<summary>Tool Executed</summary>\n'
    '</details>\n'
    '<details type="tool_calls" done="true" id="call_t2" name="station_weather" '
    'arguments="{&quot;station&quot;:&quot;Port Wren&quot;}" '
    'result="{&quot;wind_knots&quot;:12,&quot;sky&quot;:&quot;clear&quot;}">\n'
    '<summary>Tool Executed</summary>\n'
    '</details>\n'
)

BODY = r'''
## Station summary

The creek ran high after rain on day one, and three herons held the far bank [1]. Day two was upkeep: a second row of beans and a fixed gate latch.

- **High water** comes about 42 minutes later each day [2].
- Winds stay light, around `12 kn`, under clear skies.
- The heights peak at the weekend, near the spring tide.

### The tide curve

The height at time $t$ follows a cosine around the mean level $\bar{h}$:

$$h(t) = \bar{h} + A\cos\left(\frac{2\pi t}{T}\right)$$

with $T \approx 12.42$ hours for the principal lunar tide [3].

```python
from datetime import datetime, timedelta


def next_high_water(last: datetime, lag_minutes: int = 42) -> datetime:
    """Tomorrow's high water, from today's."""
    return last + timedelta(days=1, minutes=lag_minutes)
```

<details type="code_interpreter" done="true" duration="1">
<summary>Analyzed</summary>
```python
lags = [46, 43, 41, 41, 41, 43]
print(round(sum(lags) / len(lags), 1))
```

42.5
</details>

| Day | High water | Height |
| --- | --- | --- |
| Mon | 06:12 | 4.1 m |
| Tue | 06:58 | 4.0 m |
| Wed | 07:41 | 3.8 m |

The chart below has the whole week.
'''

SOURCES = [
    {
        'source': {'id': 'https://tides.example.org/port-wren', 'name': 'Port Wren tide table',
                   'url': 'https://tides.example.org/port-wren'},
        'document': ['High water at Port Wren comes about 42 minutes later each day this week.'],
        'metadata': [{'source': 'https://tides.example.org/port-wren', 'title': 'Port Wren tide table'}],
    },
    {
        'source': {'id': 'https://coast.example.net/lunar-tides', 'name': 'Why tides lag the moon',
                   'url': 'https://coast.example.net/lunar-tides'},
        'document': ['The principal lunar tide repeats every 12.42 hours, so high water drifts later.'],
        'metadata': [{'source': 'https://coast.example.net/lunar-tides', 'title': 'Why tides lag the moon'}],
    },
    {
        'source': {'id': 'https://weather.example.com/port-wren', 'name': 'Port Wren station weather',
                   'url': 'https://weather.example.com/port-wren'},
        'document': ['Light winds near 12 knots and clear skies through the week.'],
        'metadata': [{'source': 'https://weather.example.com/port-wren', 'title': 'Port Wren station weather'}],
    },
]

STATUS = [
    {'action': 'web_search', 'description': 'Searching the web for "Port Wren tide table"',
     'query': 'Port Wren tide table', 'done': False},
    {'action': 'web_search', 'description': 'Searched 3 sites', 'done': True,
     'query': 'Port Wren tide table',
     'urls': ['https://tides.example.org/port-wren', 'https://coast.example.net/lunar-tides',
              'https://weather.example.com/port-wren']},
]

CODE_EXECUTIONS = [
    {'id': 'exec-lag', 'name': 'Average daily lag', 'language': 'python',
     'code': 'lags = [46, 43, 41, 41, 41, 43]\nprint(round(sum(lags) / len(lags), 1))',
     'result': {'output': '42.5\n'}},
]


def main():
    parser = argparse.ArgumentParser(description='Seed the capture showcase chat.')
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--data', required=True, help="the server's DATA_DIR")
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    env = read_env(args.env_file)
    base = env['OWUI_URL'].rstrip('/')
    token = call(base, 'POST', '/api/v1/auths/signin',
                 {'email': env['OWUI_EMAIL'], 'password': env['OWUI_PASSWORD']})['token']

    # The fake model under a product-like (invented) name, and the account's
    # default, so new chats show a model rather than "Choose a Model".
    try:
        call(base, 'POST', f'/api/v1/models/model/update?id={MODEL}', {
            'id': MODEL, 'name': MODEL_NAME, 'base_model_id': None,
            'meta': {'description': 'A synthetic local model for screenshots.'},
            'params': {},
            'access_grants': [{'principal_type': 'user', 'principal_id': '*', 'permission': 'read'}],
        }, token)
    except Exception as e:  # an older server: keep the id as the name
        print('model rename skipped:', type(e).__name__)
    try:
        settings = call(base, 'GET', '/api/v1/users/user/settings', token=token) or {}
        ui = dict(settings.get('ui') or {})
        ui['models'] = [MODEL]
        call(base, 'POST', '/api/v1/users/user/settings/update', {**settings, 'ui': ui}, token)
    except Exception as e:
        print('default model skipped:', type(e).__name__)

    image = upload(base, token, 'high-water.png', chart_png(), 'image/png')
    image_id = image['id']
    notes_id = env.get('OWUI_FILE')

    now = int(time.time())
    ids = [str(uuid.uuid4()) for _ in range(6)]
    u1, a1, u2, a2, u3, a3 = ids
    user_files = []
    if notes_id:
        user_files = [{
            'type': 'file', 'id': notes_id, 'url': f'/api/v1/files/{notes_id}',
            'name': 'field-notes.txt', 'size': 132, 'status': 'uploaded',
            'file': {'id': notes_id, 'filename': 'field-notes.txt',
                     'meta': {'name': 'field-notes.txt', 'content_type': 'text/plain', 'size': 132}},
        }]
    messages = {
        u1: message(u1, None, [a1], 'user',
                    'Here are this week\'s station notes. Summarise them, chart the high water '
                    'and cite the tide tables you use.', now - 600, files=user_files),
        a1: message(a1, u1, [u2], 'assistant', REASONING + TOOLS + BODY, now - 590,
                    statusHistory=STATUS, sources=SOURCES, code_executions=CODE_EXECUTIONS,
                    files=[{'type': 'image', 'url': f'/api/v1/files/{image_id}/content',
                            'name': 'high-water.png', 'content_type': 'image/png'}]),
        u2: message(u2, a1, [a2], 'user', 'Run the same check for Port Ardmore.', now - 400),
        a2: message(a2, u2, [u3], 'assistant', '', now - 395,
                    error={'content': 'The tide service did not answer in time (a synthetic error). '
                                      'Try again in a moment.'}),
        u3: message(u3, a2, [a3], 'user', 'Try again with last week\'s cached table.', now - 300),
        a3: message(a3, u3, [], 'assistant',
                    'From the cached table, Port Ardmore\'s high water runs **18 minutes behind** '
                    'Port Wren all week, with heights about 0.3 m lower.', now - 295,
                    followUps=['Chart both stations together', 'When is the next spring tide?',
                               'Explain the 12.42-hour period']),
    }
    chat = {'chat': {
        'title': 'Tide station weekly report',
        'models': [MODEL],
        'messages': list(messages.values()),
        'history': {'messages': messages, 'currentId': a3},
        'timestamp': now * 1000,
    }}
    created = call(base, 'POST', '/api/v1/chats/new', chat, token)
    chat_id = created['id']
    # Newest in the list: a minute ago.
    db = sqlite3.connect(os.path.join(args.data, 'webui.db'))
    db.execute('UPDATE chat SET updated_at = ?, created_at = ? WHERE id = ?', (now - 60, now - 600, chat_id))
    db.commit()
    db.close()

    with open(os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
        f.write('# The capture harness\'s showcase chat (synthetic).\n')
        f.write(f'OWUI_SHOWCASE_CHAT={chat_id}\n')
        f.write(f'OWUI_SHOWCASE_IMAGE={image_id}\n')
    print('showcase chat', chat_id, 'image', image_id)


if __name__ == '__main__':
    main()
